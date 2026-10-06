//
//  PreviewViewController.swift
//  QLExtension
//
//  View-based Quick Look preview.
//
//  This fork uses the view-based preview path (QLIsDataBasedPreview=false)
//  instead of the data-based one: the system renders data-based HTML in its
//  own web view, which never gives the extension keyboard focus, so Cmd+C
//  does not work (upstream issue #177). Hosting our own WKWebView that can
//  become first responder restores Cmd+C / keyboard copy.
//
//  No attribution or donation nag is injected into the preview: renderMD
//  returns just the rendered Markdown. Copyright/attribution remain in the
//  About window, the menu, the sources and LICENSE.txt (GPL-3.0).
//

import Cocoa
import Quartz
@preconcurrency import WebKit
import OSLog


class MyWKWebView: WKWebView {
    override var canBecomeKeyView: Bool {
        // Must be true so the web view can take keyboard focus (Cmd+C).
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }
}

class PreviewViewController: NSViewController, QLPreviewingController {
    var webView: MyWKWebView?

    var handler: ((Error?) -> Void)?

    /// Size suggested to Quick Look. Reduced to fit the screen.
    static var previewContentSize: CGSize {
        let size = Settings.shared.qlWindowSize
        guard let screen = NSScreen.main else {
            return size
        }
        let available = screen.visibleFrame.size
        return CGSize(
            width: min(size.width, available.width * 0.9),
            height: min(size.height, available.height * 0.9)
        )
    }

    override func loadView() {
        // No nib: build the view hierarchy programmatically.
        self.view = NSView()

        Settings.shared.startMonitorChange()
        let settings = Settings.shared

        self.preferredContentSize = Self.previewContentSize

        // Create a configuration for the preferences.
        let configuration = WKWebViewConfiguration()
        // Enable JavaScript for unsafe HTML with inline images, or when Mermaid/Math extensions are active.
        configuration.preferences.javaScriptEnabled = (settings.unsafeHTMLOption && settings.inlineImageExtension) || settings.mermaidExtension != .disabled || settings.mathExtension != .disabled
        configuration.allowsAirPlayForMediaPlayback = false

        let webView = MyWKWebView(frame: self.view.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        self.view.addSubview(webView)
        self.webView = webView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // View-based entry point, used when QLIsDataBasedPreview is false.
        do {
            self.handler = handler

            let html = try Self.renderMD(url: url)
            self.webView?.isHidden = true // hide the webview until complete rendering
            self.webView?.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        } catch {
            handler(error)
        }
    }

    /// Data-based entry point, used when QLIsDataBasedPreview is true.
    /// Kept so the preview keeps working whichever path the Info.plist selects.
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        Settings.shared.startMonitorChange()

        let html = try Self.renderMD(url: request.fileURL)

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: Self.previewContentSize) { (replyToUpdate: QLPreviewReply) in
            replyToUpdate.stringEncoding = .utf8
            return html.data(using: .utf8)!
        }

        return reply
    }

    static func renderMD(url: URL) throws -> String {
        os_log(
            "Generating preview for file %{public}s",
            log: OSLog.quickLookExtension,
            type: .info,
            url.path
        )

        let settings = Settings.shared

        let markdown_url = Settings.getMarkdownFile(from: url)
        let text = try settings.render(file: markdown_url, baseDir: markdown_url.deletingLastPathComponent().path)

        let html = settings.getCompleteHTML(title: url.lastPathComponent, body: text)

        return html
    }
}

extension PreviewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let handler = self.handler {
            handler(nil)
            self.handler = nil
        }
        // Show the Quick Look preview only after the complete rendering (preventing a flickering glitch).
        // Wait to show the webview to prevent a resize glitch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.webView?.isHidden = false
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let handler = self.handler {
            handler(error)
            self.handler = nil
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let handler = self.handler {
            handler(error)
            self.handler = nil
        }
    }
}
