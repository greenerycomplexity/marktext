// webshot: render an HTML body fragment through the real template/CSS/JS bridge in an
// offscreen WKWebView and write a full-page PNG. Never activates, never shows a window.
import AppKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Options

struct Options {
    var body: String?
    var out = "webshot.png"
    var web: String?
    var docDir: String?
    var theme = "auto"
    var font = "system"
    var size = 16
    var width = "narrow"
    var appearance: String?
    var viewport = 900
    var transparent = false
    var timeout: Double = 30
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        func v() -> String { it.next() ?? "" }
        switch a {
        case "--body": o.body = v()
        case "--out": o.out = v()
        case "--web": o.web = v()
        case "--doc-dir": o.docDir = v()
        case "--theme": o.theme = v()
        case "--font": o.font = v()
        case "--size": o.size = Int(v()) ?? 16
        case "--width": o.width = v()
        case "--appearance": o.appearance = v()
        case "--viewport": o.viewport = Int(v()) ?? 900
        case "--transparent": o.transparent = true
        case "--timeout": o.timeout = Double(v()) ?? 30
        default:
            FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
            exit(64)
        }
    }
    return o
}

func defaultWebDir() -> String {
    // .../MarkText/Tools/webshot/Sources/webshot/main.swift -> .../MarkText
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent("Packages/MarkTextKit/Sources/MarkTextKit/Resources/web").path
}

// MARK: - Scheme handler (minimal copy of the contract)

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let webDir: URL
    init(webDir: URL) { self.webDir = webDir }

    static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "woff2": return "font/woff2"
        case "svg": return "image/svg+xml"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let path = url.path(percentEncoded: false)
        let file: URL
        if url.scheme == "mtres" {
            file = webDir.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
            guard file.path.hasPrefix(webDir.standardizedFileURL.path) else { task.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        } else {
            file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
              let data = try? Data(contentsOf: file) else {
            FileHandle.standardError.write(Data("404 \(url.absoluteString)\n".utf8))
            let r = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            task.didReceive(r); task.didFinish(); return
        }
        let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.mime(for: file), "Content-Length": "\(data.count)"])!
        task.didReceive(r); task.didReceive(data); task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// MARK: - Message collection

@MainActor final class Messages: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var ready = false
    var rendered = false
    var renderErrors: [Any] = []
    var consoleLines: [String] = []
    var readyWaiter: CheckedContinuation<Void, Never>?
    var navigations = 0

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let body = m.body
        if m.name == "console" { consoleLines.append("\(body)"); return }
        guard let d = body as? [String: Any], let t = d["type"] as? String else { return }
        switch t {
        case "ready": ready = true; readyWaiter?.resume(); readyWaiter = nil
        case "rendered": rendered = true; renderErrors = d["errors"] as? [Any] ?? []
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigations += 1
        // Mirror the app: only the template load may navigate.
        return navigations <= 1 ? .allow : .cancel
    }

    func waitReady() async {
        if ready { return }
        await withCheckedContinuation { readyWaiter = $0 }
    }
}

let consoleHook = """
(function(){
  var h = window.webkit.messageHandlers.console;
  function s(a){ try { return Array.prototype.map.call(a, function(x){ return typeof x==='string'?x:(x&&x.message)||JSON.stringify(x); }).join(' '); } catch(e){ return String(a); } }
  ['error','warn'].forEach(function(k){ var o = console[k]; console[k] = function(){ h.postMessage(k+': '+s(arguments)); o.apply(console, arguments); }; });
  window.addEventListener('error', function(e){ h.postMessage('error: uncaught '+e.message+' @'+(e.filename||'')+':'+e.lineno); });
  window.addEventListener('unhandledrejection', function(e){ h.postMessage('error: unhandled rejection '+((e.reason&&e.reason.message)||e.reason)); });
  document.addEventListener('securitypolicyviolation', function(e){ h.postMessage('error: CSP '+e.violatedDirective+' blocked '+e.blockedURI); });
})();
"""

// MARK: - Run

@MainActor func run(_ o: Options) async -> Int32 {
    guard let bodyPath = o.body, let raw = try? String(contentsOfFile: bodyPath, encoding: .utf8) else {
        FileHandle.standardError.write(Data("usage: webshot --body file.html --out out.png [--theme auto|light|dark|sepia] [--font system|serif|mono] [--size 16] [--width narrow|wide] [--appearance light|dark] [--viewport 900] [--web dir] [--doc-dir dir] [--transparent]\n".utf8))
        return 64
    }
    let webDir = URL(fileURLWithPath: o.web ?? defaultWebDir())
    let docDir = URL(fileURLWithPath: o.docDir ?? URL(fileURLWithPath: bodyPath).deletingLastPathComponent().path).standardizedFileURL.path
    let html = raw.replacingOccurrences(of: "{{DOCDIR}}", with: docDir.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/"))

    let msgs = Messages()
    let cfg = WKWebViewConfiguration()
    let handler = SchemeHandler(webDir: webDir)
    cfg.setURLSchemeHandler(handler, forURLScheme: "mtres")
    cfg.setURLSchemeHandler(handler, forURLScheme: "mtdoc")
    cfg.userContentController.add(msgs, name: "marktext")
    cfg.userContentController.add(msgs, name: "console")
    cfg.userContentController.addUserScript(WKUserScript(source: consoleHook, injectionTime: .atDocumentStart, forMainFrameOnly: true))

    let size = NSSize(width: o.viewport, height: 800)
    let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
    web.navigationDelegate = msgs
    web.setValue(false, forKey: "drawsBackground")
    let appearance: NSAppearance? = switch o.appearance {
    case "dark": NSAppearance(named: .darkAqua)
    case "light": NSAppearance(named: .aqua)
    default: nil
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = web
    window.orderOut(nil)

    web.load(URLRequest(url: URL(string: "mtres://app/template.html")!))
    await msgs.waitReady()

    func js(_ source: String, _ args: [String: Any] = [:]) async -> Any? {
        do { return try await web.callAsyncJavaScript(source, arguments: args, in: nil, contentWorld: .page) }
        catch { FileHandle.standardError.write(Data("js error: \(error)\n".utf8)); return nil }
    }

    _ = await js("MarkText.setStyle(s)", ["s": ["theme": o.theme, "font": o.font, "size": o.size, "width": o.width] as [String: Any]])
    let base = "mtdoc://local" + docDir + "/"
    _ = await js("return await MarkText.render(h, opts)", ["h": html, "opts": ["preserveScroll": false, "baseHref": base, "hasMath": true, "hasMermaid": true] as [String: Any]])
    try? await Task.sleep(for: .milliseconds(250))

    let height = min(30000, max(200, Int((await js("return document.documentElement.scrollHeight") as? NSNumber)?.doubleValue ?? 800)))
    window.setContentSize(NSSize(width: o.viewport, height: height))
    web.frame = NSRect(x: 0, y: 0, width: o.viewport, height: height)
    try? await Task.sleep(for: .milliseconds(400))

    let height2 = min(30000, max(200, Int((await js("return document.documentElement.scrollHeight") as? NSNumber)?.doubleValue ?? Double(height))))
    if height2 != height {
        window.setContentSize(NSSize(width: o.viewport, height: height2))
        web.frame = NSRect(x: 0, y: 0, width: o.viewport, height: height2)
        try? await Task.sleep(for: .milliseconds(300))
    }

    let probe = await js("""
        return {
          katex: document.querySelectorAll('#content .katex').length,
          mathErr: document.querySelectorAll('#content .math-error').length,
          mermaidSvg: document.querySelectorAll('#content .mermaid svg').length,
          mermaidTotal: document.querySelectorAll('#content .mermaid').length,
          scripts: document.querySelectorAll('#content script').length,
          iframes: document.querySelectorAll('#content iframe, #content object, #content embed').length,
          onattr: document.querySelectorAll('#content [onerror],#content [onclick],#content [onload]').length,
          overflowing: document.querySelectorAll('#content .code-block.overflowing').length,
          hljs: document.querySelectorAll('#content code.hljs').length,
          wrapped: document.querySelectorAll('#content .table-wrap table').length,
          images: Array.prototype.map.call(document.querySelectorAll('#content img'), function(i){ return i.naturalWidth>0; }),
          headingIds: document.querySelectorAll('#content h1[id],#content h2[id],#content h3[id]').length,
          theme: document.documentElement.getAttribute('data-theme'),
          dark: matchMedia('(prefers-color-scheme: dark)').matches,
          height: document.documentElement.scrollHeight
        }
        """) as? [String: Any] ?? [:]

    let snap = WKSnapshotConfiguration()
    snap.rect = NSRect(x: 0, y: 0, width: o.viewport, height: height2)
    snap.afterScreenUpdates = true
    var status: Int32 = 0
    do {
        let image = try await web.takeSnapshot(configuration: snap)
        var final = image
        if !o.transparent && o.theme != "sepia" {
            let isDark = (probe["dark"] as? Bool) ?? false
            let ap = appearance ?? NSAppearance(named: isDark ? .darkAqua : .aqua)!
            var bg = NSColor.windowBackgroundColor
            ap.performAsCurrentDrawingAppearance { bg = NSColor(cgColor: NSColor.windowBackgroundColor.cgColor) ?? bg }
            let comp = NSImage(size: image.size)
            comp.lockFocus()
            bg.setFill(); NSRect(origin: .zero, size: image.size).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size))
            comp.unlockFocus()
            final = comp
        }
        guard let tiff = final.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw URLError(.cannotDecodeContentData) }
        try png.write(to: URL(fileURLWithPath: o.out))
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8)); status = 1
    }

    var report: [String: Any] = ["out": o.out, "rendered": msgs.rendered, "renderErrors": msgs.renderErrors,
                                 "console": msgs.consoleLines, "probe": probe]
    report["viewport"] = "\(o.viewport)x\(height2)"
    if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: d, encoding: .utf8) { print(s) }
    return status
}

let opts = parseArgs()
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(opts.timeout))
        FileHandle.standardError.write(Data("webshot: timeout\n".utf8))
        exit(2)
    }
    let code = await run(opts)
    watchdog.cancel()
    exit(code)
}
app.run()
