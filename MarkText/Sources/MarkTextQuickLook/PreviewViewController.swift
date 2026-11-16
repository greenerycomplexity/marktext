import Cocoa
import MarkTextKit
import Quartz
import WebKit

/// View-based Quick Look preview. Replies only after the page reports `rendered` (or a stub-template fallback).
final class PreviewViewController: NSViewController, QLPreviewingController, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView!
    private var handler: ((Error?) -> Void)?
    private var html = ""
    private var rendered: RenderedDocument?
    private var isReady = false

    override func loadView() {
        let config = WKWebViewConfiguration()
        let handler = PreviewSchemeHandler()
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.resourceScheme)
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.documentScheme)
        config.userContentController.add(WeakScriptMessageHandler(self), name: "marktext")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) { webView.setValue(false, forKey: "drawsBackground") }
        webView.load(URLRequest(url: URL(string: "mtres://app/template.html")!))
        view = webView
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let text = (try? TextCodec.decode(data).text) ?? String(decoding: data, as: UTF8.self)   // same UTF-16/Latin-1 handling as the app
        rendered = MarkdownRenderer.render(text)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.handler = { _ in c.resume(returning: ()) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))   // never hang Quick Look
                self.finish()
            }
            self.pushIfPossible()
        }
    }

    private func finish() { let h = handler; handler = nil; h?(nil) }

    private func pushIfPossible() {
        guard isReady, let doc = rendered else { return }
        Task { @MainActor in
            let js = """
            if (window.MarkText) { await MarkText.render(html, {preserveScroll: false, baseHref: '', hasMath: hasMath, hasMermaid: hasMermaid}); return true; }
            document.getElementById('mt-root').innerHTML = html; return false;
            """
            let r = try? await webView.callAsyncJavaScript(js, arguments: ["html": doc.html, "hasMath": doc.hasMath, "hasMermaid": doc.hasMermaid], contentWorld: .page)
            if (r as? Bool) != true { finish() }   // stub bridge: no `rendered` message will come
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { isReady = true; pushIfPossible() }
        if type == "rendered" { finish() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let has = (try? await webView.callAsyncJavaScript("return typeof window.MarkText !== 'undefined'", arguments: [:], contentWorld: .page) as? Bool) ?? false
            if !has { isReady = true; pushIfPossible() }
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        webView.load(URLRequest(url: URL(string: "mtres://app/template.html")!))   // `ready` re-triggers pushIfPossible
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.navigationType == .other && action.request.url?.scheme == "mtres" ? .allow : .cancel
    }
}
