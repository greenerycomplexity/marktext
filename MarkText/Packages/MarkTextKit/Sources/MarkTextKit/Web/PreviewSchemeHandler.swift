import Foundation
import WebKit

/// Serves `mtres://app/<path>` (bundled web assets) and `mtdoc://local/<absolute path>` (document-relative files).
@MainActor
public final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let resourceScheme = "mtres"
    public static let documentScheme = "mtdoc"

    private let webRoot: URL
    private let realWebRoot: String
    /// Tasks WebKit told us to stop; we must never message them afterwards.
    private var stopped = Set<ObjectIdentifier>()

    public init(webRoot: URL = PreviewAssets.webRoot) {
        self.webRoot = webRoot
        self.realWebRoot = Self.realPath(webRoot.path)
        super.init()
    }

    // MARK: WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        stopped.remove(id)
        guard let url = urlSchemeTask.request.url else {
            finish(urlSchemeTask, id: id, status: 400, url: nil)
            return
        }
        guard let fileURL = resolve(url) else {
            finish(urlSchemeTask, id: id, status: url.host == nil ? 400 : 404, url: url)
            return
        }
        let mime = Self.mimeType(forExtension: fileURL.pathExtension)
        let cache = url.scheme == Self.documentScheme ? "no-cache" : "max-age=3600"
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: fileURL, options: .mappedIfSafe) }.value
            guard let self else { return }
            guard !self.stopped.contains(id) else { self.stopped.remove(id); return }
            guard let data else {
                self.finish(urlSchemeTask, id: id, status: 404, url: url)
                return
            }
            let headers = [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Cache-Control": cache,
                "Access-Control-Allow-Origin": "*",
            ]
            if let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
                urlSchemeTask.didReceive(resp)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } else {
                urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask))
    }

    private func finish(_ task: any WKURLSchemeTask, id: ObjectIdentifier, status: Int, url: URL?) {
        guard !stopped.contains(id) else { stopped.remove(id); return }
        let u = url ?? URL(string: "about:blank")!
        if let resp = HTTPURLResponse(url: u, statusCode: status, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Length": "0", "Content-Type": "text/plain"]) {
            task.didReceive(resp)
            task.didReceive(Data())
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.badURL))
        }
    }

    // MARK: Resolution (nonisolated pure helpers, unit-tested)

    /// Maps a request URL to an existing regular file, or nil when unknown, missing or outside the allowed root.
    func resolve(_ url: URL) -> URL? {
        switch url.scheme {
        case Self.resourceScheme:
            guard url.host == "app" else { return nil }
            var rel = url.path
            if rel.isEmpty || rel == "/" { rel = "/template.html" }
            return Self.resolveResource(path: rel, root: webRoot, realRoot: realWebRoot)
        case Self.documentScheme:
            guard url.host == "local" else { return nil }
            return Self.resolveDocument(path: url.path)
        default:
            return nil
        }
    }

    nonisolated static func resolveResource(path: String, root: URL, realRoot: String) -> URL? {
        guard !path.contains("\0") else { return nil }
        let candidate = root.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
        let real = realPath(candidate.path)
        guard real.hasPrefix(realRoot.hasSuffix("/") ? realRoot : realRoot + "/") else { return nil }
        return isRegularFile(real) ? URL(fileURLWithPath: real) : nil
    }

    nonisolated static func resolveDocument(path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let real = realPath(path)
        return isRegularFile(real) ? URL(fileURLWithPath: real) : nil
    }

    nonisolated static func realPath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        if realpath(path, &buf) != nil { return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return URL(fileURLWithPath: path).standardized.path
    }

    nonisolated static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    nonisolated static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        case "ico": "image/x-icon"
        case "bmp": "image/bmp"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "pdf": "application/pdf"
        case "mp4", "m4v": "video/mp4"
        case "webm": "video/webm"
        case "mp3": "audio/mpeg"
        case "txt", "md", "markdown": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }
}
