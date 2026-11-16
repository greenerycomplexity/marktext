import AppKit
import MarkTextKit
import SwiftUI
import WebKit

/// Owns the WKWebView and the bridge to marktext.js. Calls are queued until `ready`.
final class PreviewController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var documentDirectory: URL?
    var onRendered: (([String]) -> Void)?
    var onActiveHeading: ((String) -> Void)?
    var onLink: ((URL) -> Void)?
    var onScroll: ((Double) -> Void)?

    private var isReady = false
    private var pending: [@MainActor () async -> Void] = []
    private var latest: RenderedDocument?
    private var style: [String: Any] = PrefKey.webStyle
    private var bridgeIsStub = false
    /// Completed renders and the errors of the last one (polled by the harness).
    private(set) var renderedCount = 0
    /// Number of evaluateJavaScript round trips (diagnostics: the preview must not be chatty).
    private(set) var jsCallCount = 0
    private var lastPushed: (html: String, base: String)?
    private var lastAppliedStyle: String?
    private var pendingLine: Int?
    private var lastLine = -1
    private var lineTask: Task<Void, Never>?
    private(set) var lastErrors: [String] = []

    // MARK: Spare

    /// One web view kept ready (process launched, template loaded) for the next document. Launching a WebContent
    /// process costs 60-130 ms on the main thread (WebKit queries every installed font for each new process),
    /// which was part of every window open.
    private static var spare: PreviewController?
    private static var spareScheduled = false

    /// The preview for a new document: the spare when there is one. A replacement is prepared once things settle.
    static func make() -> PreviewController {
        let controller = spare ?? PreviewController()
        spare = nil
        prepareSpare(after: 2.5)
        return controller
    }

    /// When a render was last requested by any document: the replacement spare waits for a quiet moment.
    private static var lastRenderRequest = Date.distantPast

    /// Creation and the template load run in separate run-loop turns so neither blocks the main thread for long,
    /// and both wait until nobody has been typing for a few seconds.
    static func prepareSpare(after delay: TimeInterval) {
        guard spare == nil, !spareScheduled else { return }
        spareScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                if delay > 0, Date().timeIntervalSince(lastRenderRequest) < 3 {
                    spareScheduled = false
                    prepareSpare(after: 3)
                    return
                }
                let start = CFAbsoluteTimeGetCurrent()
                let controller = PreviewController(loadTemplate: false)
                let created = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let loadStart = CFAbsoluteTimeGetCurrent()
                        controller.loadTemplate()
                        Harness.log("spare web view: create \(Int((created - start) * 1000)) ms, load \(Int((CFAbsoluteTimeGetCurrent() - loadStart) * 1000)) ms")
                        spareScheduled = false
                        if spare == nil { spare = controller }
                    }
                }
            }
        }
    }

    private func loadTemplate() { webView.load(URLRequest(url: URL(string: "mtres://app/template.html")!)) }

    override convenience init() { self.init(loadTemplate: true) }

    private init(loadTemplate: Bool) {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        let errorHook = """
        window.__mtErrors = [];
        window.addEventListener('error', e => window.__mtErrors.push(String(e.message)));
        window.addEventListener('unhandledrejection', e => window.__mtErrors.push(String(e.reason)));
        """
        ucc.addUserScript(WKUserScript(source: errorHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = ucc
        // Handlers must be registered before the WKWebView copies the configuration.
        let handler = PreviewSchemeHandler()
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.resourceScheme)
        config.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.documentScheme)
        webView = PreviewWebView(frame: .zero, configuration: config)
        super.init()
        ucc.add(WeakScriptMessageHandler(self), name: "marktext")

        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        // No public API in the macOS 26/27 SDK; only use the private setter when it exists.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) { webView.setValue(false, forKey: "drawsBackground") }
        webView.isInspectable = true
        webView.allowsMagnification = false
        if loadTemplate { self.loadTemplate() }
    }

    func setDocumentDirectory(_ url: URL?) {
        guard url != documentDirectory else { return }
        documentDirectory = url
        if let latest { render(latest) }   // re-push so <base> follows the new location
    }

    // MARK: Bridge calls

    func render(_ doc: RenderedDocument) {
        Self.lastRenderRequest = Date()
        latest = doc
        enqueue { [weak self] in await self?.pushLatest() }
    }

    func applyPrefs() { setStyle(PrefKey.webStyle) }

    func setStyle(_ newStyle: [String: Any]) {
        style.merge(newStyle) { $1 }
        enqueue { [weak self] in
            guard let self else { return }
            let show = UserDefaults.standard.bool(forKey: PrefKey.showFrontMatter)
            let key = "\(self.style.sorted { $0.key < $1.key })\(show)"
            guard key != self.lastAppliedStyle else { return }   // unchanged: no JS round trip
            self.lastAppliedStyle = key
            _ = await self.evaluate(
                "document.documentElement.classList.toggle('show-front-matter', show); if (window.MarkText) { MarkText.setStyle(style); } return true",
                ["style": self.style, "show": show])
        }
    }

    func scrollToHeading(_ id: String) {
        enqueue { [weak self] in _ = await self?.evaluate("if (window.MarkText) MarkText.scrollToHeading(id); return true", ["id": id]) }
    }

    /// Editor scroll sync fires on every scroll tick: coalesce to the latest line, at most every 60 ms.
    func scrollToLine(_ line: Int) {
        guard line != lastLine else { return }
        pendingLine = line
        guard lineTask == nil else { return }
        lineTask = Task { @MainActor [weak self] in
            while let self, let l = self.pendingLine {
                self.pendingLine = nil
                self.lastLine = l
                self.enqueue { [weak self] in _ = await self?.evaluate("if (window.MarkText) MarkText.scrollToLine(n); return true", ["n": l]) }
                try? await Task.sleep(for: .milliseconds(60))
            }
            self?.lineTask = nil
        }
    }

    func evaluate(_ js: String, _ args: [String: Any] = [:]) async -> Any? {
        jsCallCount += 1
        return try? await webView.callAsyncJavaScript(js, arguments: args, contentWorld: .page)
    }

    func find(_ text: String, backwards: Bool) async -> Bool {
        let config = WKFindConfiguration()
        config.caseSensitive = false
        config.wraps = true
        config.backwards = backwards
        return (try? await webView.find(text, configuration: config).matchFound) ?? false
    }

    func clearFind() { Task { _ = await evaluate("getSelection().removeAllRanges(); return true") } }

    // MARK: Queue

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        if isReady { Task { @MainActor in await work() } } else { pending.append(work) }
    }

    private func becomeReady() {
        guard !isReady else { return }
        isReady = true
        let work = pending
        pending = []
        Task { @MainActor in for item in work { await item() } }
    }

    private func pushLatest() async {
        guard let doc = latest else { return }
        let baseHref = documentDirectory.map { "mtdoc://local" + $0.path(percentEncoded: true) + "/" } ?? ""
        let js = """
        if (window.MarkText) {
          await MarkText.render(html, {preserveScroll: true, baseHref: baseHref, hasMath: hasMath, hasMermaid: hasMermaid});
          return true;
        } else {
          document.getElementById('mt-root').innerHTML = html;
          return false;
        }
        """
        // Identical output (e.g. an edit that only changed trailing whitespace) needs no JS at all.
        if let last = lastPushed, last.html == doc.html, last.base == baseHref { return }
        lastPushed = (doc.html, baseHref)
        let result = await evaluate(js, ["html": doc.html, "baseHref": baseHref, "hasMath": doc.hasMath, "hasMermaid": doc.hasMermaid])
        if (result as? Bool) != true {
            bridgeIsStub = true
            didRender([])
        }
    }

    private func didRender(_ errors: [String]) {
        renderedCount += 1
        lastErrors = errors
        onRendered?(errors)
    }

    // MARK: WKScriptMessageHandler / WKNavigationDelegate

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready": becomeReady()
        case "rendered": didRender((body["errors"] as? [Any])?.map { String(describing: $0) } ?? [])
        case "scroll": onScroll?((body["fraction"] as? Double) ?? 0)
        case "activeHeading": onActiveHeading?((body["id"] as? String) ?? "")
        case "link": if let href = body["href"] as? String, let url = URL(string: href) { onLink?(url) }
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let hasBridge = (await self.evaluate("return typeof window.MarkText !== 'undefined'") as? Bool) ?? false
            if !hasBridge { self.bridgeIsStub = true; self.becomeReady() }
        }
    }

    /// The WebContent process can be killed (memory pressure, crash): reload the template and restore state.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        bridgeIsStub = false
        lastPushed = nil
        lastAppliedStyle = nil
        pending = []
        loadTemplate()
        setStyle([:])
        if let latest { render(latest) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only the initial template load may navigate; links are routed through the bridge.
        action.navigationType == .other && action.request.url?.scheme == "mtres" ? .allow : .cancel
    }
}

/// WKWebView that tells WebKit how much of its top edge is covered by the (glass) toolbar,
/// so content starts below it but scrolls underneath. SwiftUI's safe-area proxy reports 0 once
/// the safe area is ignored, so the inset comes from `NSWindow.contentLayoutRect`.
final class PreviewWebView: WKWebView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateObscuredInsets() }
    override func layout() { super.layout(); updateObscuredInsets() }

    private func updateObscuredInsets() {
        guard let window else { return }
        let layoutRect = convert(window.contentLayoutRect, from: nil).intersection(bounds)
        let top = isFlipped ? layoutRect.minY - bounds.minY : bounds.maxY - layoutRect.maxY
        if abs(obscuredContentInsets.top - top) > 0.5 {
            obscuredContentInsets = NSEdgeInsets(top: max(top, 0), left: 0, bottom: 0, right: 0)
        }
    }
}

struct PreviewView: NSViewRepresentable {
    let controller: PreviewController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
