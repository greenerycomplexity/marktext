import Testing
import Foundation
@testable import MarkTextKit

@MainActor
@Suite("PreviewSchemeHandler")
struct SchemeHandlerTests {
    /// Temp tree: root/web/{a.js,sub/b.css,dir/}, root/outside.txt, root/web/escape -> ../outside.txt
    func makeTree() throws -> (root: URL, web: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mtk-\(UUID().uuidString)")
        let web = root.appendingPathComponent("web")
        try fm.createDirectory(at: web.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: web.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try "console.log(1)".write(to: web.appendingPathComponent("a.js"), atomically: true, encoding: .utf8)
        try "body{}".write(to: web.appendingPathComponent("sub/b.css"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: web.appendingPathComponent("template.html"), atomically: true, encoding: .utf8)
        try "secret".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: web.appendingPathComponent("escape"), withDestinationURL: root.appendingPathComponent("outside.txt"))
        return (root, web)
    }

    @Test func servesBundledResources() throws {
        let (root, web) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = PreviewSchemeHandler(webRoot: web)
        #expect(h.resolve(URL(string: "mtres://app/a.js")!)?.lastPathComponent == "a.js")
        #expect(h.resolve(URL(string: "mtres://app/sub/b.css")!)?.lastPathComponent == "b.css")
        #expect(h.resolve(URL(string: "mtres://app/")!)?.lastPathComponent == "template.html")
        #expect(h.resolve(URL(string: "mtres://app/a.js?v=1#x")!)?.lastPathComponent == "a.js")
    }

    @Test func rejectsEscapesMissingAndDirectories() throws {
        let (root, web) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let h = PreviewSchemeHandler(webRoot: web)
        #expect(h.resolve(URL(string: "mtres://app/../outside.txt")!) == nil)
        #expect(h.resolve(URL(string: "mtres://app/sub/../../outside.txt")!) == nil)
        #expect(h.resolve(URL(string: "mtres://app/%2e%2e/outside.txt")!) == nil)
        #expect(h.resolve(URL(string: "mtres://app/escape")!) == nil)       // symlink leaving the root
        #expect(h.resolve(URL(string: "mtres://app/dir")!) == nil)          // directory
        #expect(h.resolve(URL(string: "mtres://app/missing.js")!) == nil)
        #expect(h.resolve(URL(string: "mtres://other/a.js")!) == nil)       // wrong host
        #expect(h.resolve(URL(string: "https://app/a.js")!) == nil)         // wrong scheme
    }

    @Test func servesDocumentFilesPercentDecoded() throws {
        let (root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("my docs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = dir.appendingPathComponent("pic é.png")
        try Data([1, 2, 3]).write(to: img)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: img)

        var comps = URLComponents()
        comps.scheme = "mtdoc"; comps.host = "local"; comps.percentEncodedPath = img.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let h = PreviewSchemeHandler(webRoot: root)
        let resolved = try #require(h.resolve(comps.url!))
        #expect(resolved.lastPathComponent == "pic é.png")
        // Symlinks are resolved (realpath) but still regular files.
        var c2 = comps
        c2.percentEncodedPath = link.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        #expect(h.resolve(c2.url!)?.lastPathComponent == "pic é.png")
        // Directories and missing files are not served.
        var c3 = comps
        c3.percentEncodedPath = dir.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        #expect(h.resolve(c3.url!) == nil)
        #expect(h.resolve(URL(string: "mtdoc://local/nonexistent/file.png")!) == nil)
        #expect(h.resolve(URL(string: "mtdoc://elsewhere/etc/hosts")!) == nil)
    }

    @Test func mimeTypes() {
        let cases: [(String, String)] = [
            ("html", "text/html; charset=utf-8"), ("css", "text/css; charset=utf-8"), ("js", "text/javascript; charset=utf-8"),
            ("json", "application/json; charset=utf-8"), ("svg", "image/svg+xml"), ("png", "image/png"),
            ("jpg", "image/jpeg"), ("JPEG", "image/jpeg"), ("gif", "image/gif"), ("webp", "image/webp"),
            ("avif", "image/avif"), ("woff2", "font/woff2"), ("woff", "font/woff"), ("ttf", "font/ttf"),
            ("pdf", "application/pdf"), ("xyz", "application/octet-stream"), ("", "application/octet-stream"),
        ]
        for (ext, mime) in cases { #expect(PreviewSchemeHandler.mimeType(forExtension: ext) == mime, "\(ext)") }
    }

    @Test func defaultInitUsesBundledWebRoot() {
        let h = PreviewSchemeHandler()
        #expect(h.resolve(URL(string: "mtres://app/template.html")!) != nil)
    }
}
