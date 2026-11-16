import Foundation
import cmark_gfm

public enum MarkdownRenderer {
    /// Pure, thread-safe Markdown → HTML body fragment.
    public static func render(_ markdown: String) -> RenderedDocument {
        var source = markdown
        if source.utf8.contains(13) {
            source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }

        let front = FrontMatterParser.extract(source)
        let protected = MathProtector.protect(front?.body ?? source)

        var r = HTMLRenderer(items: protected.items, lineMap: protected.lineMap, capacity: protected.text.utf8.count + protected.text.utf8.count / 2 + 4096)
        if let front { r.putFrontMatter(yaml: front.yaml) }
        // Second (and last) cmark parse: the masked source, with the GFM extensions attached.
        let options = CMARK_OPT_SOURCEPOS | CMARK_OPT_TABLE_SPANS
        if let document = CMark.parse(protected.text, options: options, extensions: ["table", "strikethrough", "tasklist", "autolink"]) {
            r.render(document)
            cmark_node_free(document)
        }

        let words = r.words.count
        let minutes = words > 0 ? max(1, (words + 229) / 230) : 0
        return RenderedDocument(
            html: String(decoding: r.out, as: UTF8.self),
            headings: r.headings,
            stats: DocumentStats(words: words, readingMinutes: minutes),
            hasMath: r.hasMath,
            hasMermaid: r.hasMermaid
        )
    }
}
