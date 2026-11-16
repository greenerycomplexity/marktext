import AppKit
import MarkTextKit
import UniformTypeIdentifiers
import WebKit

/// Print, PDF and standalone-HTML export, all driven from the live preview web view.
extension PreviewController {
    func printOperation(saveTo url: URL? = nil) -> NSPrintOperation {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        let op = webView.printOperation(with: info)
        op.view?.frame = NSRect(x: 0, y: 0, width: info.paperSize.width - 108, height: info.paperSize.height - 108)
        if url != nil { op.showsPrintPanel = false; op.showsProgressPanel = false }
        return op
    }

    /// Saves a paginated PDF through the print pipeline (no panels, `.save` disposition).
    /// WKWebView's print operation must be run asynchronously; the completion callback is not
    /// reliable for panel-less save jobs, so completion is detected from the output file settling.
    @MainActor
    func exportPDF(to url: URL, window: NSWindow?) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        let op = printOperation(saveTo: url)
        guard let host = window ?? webView.window else { return false }
        op.runModal(for: host, delegate: nil, didRun: nil, contextInfo: nil)
        var lastSize = -1
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(100))
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            if size > 0 && size == lastSize { return true }
            lastSize = size
        }
        return false
    }

    /// Standalone HTML: CSS inlined, fonts and local images as data URIs, no scripts.
    /// The page CSP blocks fetch(), so assets are read from disk here rather than from JS.
    func exportHTML() async -> String? {
        let js = """
        const hasMath = document.querySelectorAll('.katex').length > 0;
        const links = [...document.querySelectorAll('link[rel=stylesheet]')].map(l => l.getAttribute('href')).filter(h => hasMath || !h.includes('katex'));
        const resolved = [...document.querySelectorAll('img')].map(el => el.src);   // absolute, against <base>
        const clone = document.documentElement.cloneNode(true);
        clone.querySelectorAll('img').forEach((el, i) => { if (resolved[i]) el.setAttribute('src', resolved[i]); });
        clone.querySelectorAll('script, link, meta[http-equiv], base, .code-chip').forEach(e => e.remove());
        return { html: '<!doctype html>\\n' + clone.outerHTML, links: links };
        """
        guard let result = await evaluate(js) as? [String: Any], var html = result["html"] as? String,
              let links = result["links"] as? [String] else { return nil }
        let root = PreviewAssets.webRoot
        var css = ""
        for href in links {
            let file = root.appending(path: href)
            guard var text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            text = text.replacing(/,\s*url\([^)]*\.(?:woff|ttf)[^)]*\)\s*format\([^)]*\)/, with: "")
            let matches = text.matches(of: /url\(\s*["']?([^"')]+\.woff2)["']?\s*\)/)
            for m in matches {
                let rel = String(m.output.1)
                if let data = try? Data(contentsOf: file.deletingLastPathComponent().appending(path: rel)) {
                    text = text.replacingOccurrences(of: rel, with: "data:font/woff2;base64," + data.base64EncodedString())
                }
            }
            css += text + "\n"
        }
        // Local images (mtdoc://local/<abs path>) become data URIs.
        for m in html.matches(of: /src="(mtdoc:\/\/local\/[^"]+)"/).map({ String($0.output.1) }) {
            let path = URL(string: m)?.path(percentEncoded: false) ?? ""
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                let mime = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.preferredMIMEType ?? "image/png"
                html = html.replacingOccurrences(of: m, with: "data:\(mime);base64," + data.base64EncodedString())
            }
        }
        if let head = html.range(of: "</head>") { html.replaceSubrange(head, with: "<style>\(css)</style></head>") }
        return html
    }
}
