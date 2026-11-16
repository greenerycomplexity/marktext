import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Incremental word counter fed with the same text stream the old `wordText` string held.
/// Whitespace-separated tokens containing a letter or digit; each CJK ideograph / kana / hangul syllable counts as a word.
struct WordCounter {
    var count = 0
    var inWord = false

    @inline(__always) mutating func space() { inWord = false }

    mutating func feed(_ p: UnsafeBufferPointer<UInt8>) {
        let n = p.count
        var i = 0
        while i < n {
            let b = p[i]
            if b < 128 {
                if (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) {
                    if !inWord { count += 1; inWord = true }
                } else if b == 32 || (b >= 9 && b <= 13) {
                    inWord = false
                }
                i += 1
                continue
            }
            var v: UInt32
            var len: Int
            if b >= 0xF0 { v = UInt32(b & 0x07); len = 4 } else if b >= 0xE0 { v = UInt32(b & 0x0F); len = 3 } else { v = UInt32(b & 0x1F); len = 2 }
            if i + len > n { len = n - i }
            for k in 1..<max(len, 1) { v = (v << 6) | UInt32(p[i + k] & 0x3F) }
            i += max(len, 1)
            if (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) {
                count += 1
                inWord = false
            } else if let s = Unicode.Scalar(v) {
                if s.properties.isWhitespace {
                    inWord = false
                } else if !inWord, s.properties.isAlphabetic || s.properties.numericType != nil {
                    count += 1
                    inWord = true
                }
            }
        }
    }
}

/// Splits `p` into plain runs and `MTKMATH[ID]<n>Z` placeholders.
@inline(__always)
func scanMathPlaceholders(_ p: UnsafeBufferPointer<UInt8>, itemCount: Int, onText: (UnsafeBufferPointer<UInt8>) -> Void, onMath: (Int) -> Void) {
    // "MTKMATH"
    let m0: UInt8 = 77
    let n = p.count
    var last = 0
    var i = 0
    while i + 7 < n {
        if p[i] == m0, p[i + 1] == 84, p[i + 2] == 75, p[i + 3] == 77, p[i + 4] == 65, p[i + 5] == 84, p[i + 6] == 72 {
            var j = i + 7
            if p[j] == 73 || p[j] == 68 {
                j += 1
                let ds = j
                var idx = 0
                while j < n, p[j] >= 48, p[j] <= 57 { idx = idx &* 10 &+ Int(p[j] - 48); j += 1 }
                if j > ds, j < n, p[j] == 90, idx < itemCount {
                    if last < i { onText(UnsafeBufferPointer(rebasing: p[last..<i])) }
                    onMath(idx)
                    i = j + 1
                    last = i
                    continue
                }
            }
        }
        i += 1
    }
    if last < n { onText(UnsafeBufferPointer(rebasing: p[last...])) }
}

@inline(__always)
func containsMathMarker(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
    let n = p.count
    guard n >= 8 else { return false }
    var i = 0
    while i + 7 < n {
        if p[i] == 77, p[i + 1] == 84, p[i + 2] == 75, p[i + 3] == 77, p[i + 4] == 65, p[i + 5] == 84, p[i + 6] == 72 { return true }
        i += 1
    }
    return false
}

/// cmark-gfm AST → HTML body fragment, emitted straight into a UTF-8 byte buffer.
/// One instance per render call (no shared state).
struct HTMLRenderer {
    var out: [UInt8] = []
    private(set) var headings: [Heading] = []
    private(set) var words = WordCounter()
    private(set) var hasMath = false
    private(set) var hasMermaid = false

    private let items: [MathItem]
    private let lineMap: [Int]
    private var slugger = Slugger()

    // Walk state.
    private var looseStack: [Bool] = []
    private enum ParaMode { case normal, tightInline, standalone }
    private var paraMode = ParaMode.normal
    private var linkSaved = WordCounter()
    private var linkIsURL = false
    private var tableAligns: UnsafeMutablePointer<UInt8>?
    private var tableColumns = 0
    private var cellIndex = 0
    private var cellInHeader = false
    private var cellSkipped = false

    private enum Kind {
        case document, blockQuote, list, item, codeBlock, htmlBlock, paragraph, heading, thematicBreak
        case text, softBreak, lineBreak, code, htmlInline, emph, strong, link, image
        case strike, table, tableHead, tableRow, tableCell, other
    }

    init(items: [MathItem], lineMap: [Int], capacity: Int) {
        self.items = items
        self.lineMap = lineMap
        out.reserveCapacity(capacity)
    }

    // MARK: Output primitives

    @inline(__always) private mutating func put(_ s: StaticString) {
        s.withUTF8Buffer { out.append(contentsOf: $0) }
    }

    private mutating func putInt(_ v: Int) {
        if v < 0 { out.append(45); putInt(-v); return }
        if v >= 10 { putInt(v / 10) }
        out.append(UInt8(48 + v % 10))
    }

    /// HTML-escapes `p` (`&`, `<`, `>`, and `"` when `attribute`) into the output.
    mutating func putEscaped(_ p: UnsafeBufferPointer<UInt8>, attribute: Bool = false) {
        let n = p.count
        var start = 0
        var i = 0
        while i < n {
            let b = p[i]
            if b == 38 || b == 60 || b == 62 || (attribute && b == 34) {
                if start < i { out.append(contentsOf: UnsafeBufferPointer(rebasing: p[start..<i])) }
                switch b {
                case 38: put("&amp;")
                case 60: put("&lt;")
                case 62: put("&gt;")
                default: put("&quot;")
                }
                start = i + 1
            }
            i += 1
        }
        if start < n { out.append(contentsOf: UnsafeBufferPointer(rebasing: p[start...])) }
    }

    mutating func putEscaped(_ s: String, attribute: Bool = false) {
        var s = s
        s.withUTF8 { putEscaped($0, attribute: attribute) }
    }

    mutating func putFrontMatter(yaml: String) {
        put("<details class=\"front-matter\" data-line=\"1\"><summary>Front matter</summary><pre>")
        putEscaped(yaml)
        put("</pre></details>\n")
    }

    // MARK: Node helpers

    @inline(__always) private func literal(_ n: CMarkNode) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(cString: cmark_node_get_literal(n))
    }

    private func kind(_ n: CMarkNode) -> Kind {
        switch cmark_node_get_type(n) {
        case CMARK_NODE_PARAGRAPH: return .paragraph
        case CMARK_NODE_TEXT: return .text
        case CMARK_NODE_ITEM: return .item
        case CMARK_NODE_LIST: return .list
        case CMARK_NODE_EMPH: return .emph
        case CMARK_NODE_STRONG: return .strong
        case CMARK_NODE_LINK: return .link
        case CMARK_NODE_CODE: return .code
        case CMARK_NODE_SOFTBREAK: return .softBreak
        case CMARK_NODE_LINEBREAK: return .lineBreak
        case CMARK_NODE_HEADING: return .heading
        case CMARK_NODE_CODE_BLOCK: return .codeBlock
        case CMARK_NODE_HTML_BLOCK: return .htmlBlock
        case CMARK_NODE_HTML_INLINE: return .htmlInline
        case CMARK_NODE_BLOCK_QUOTE: return .blockQuote
        case CMARK_NODE_THEMATIC_BREAK: return .thematicBreak
        case CMARK_NODE_IMAGE: return .image
        case CMARK_NODE_DOCUMENT: return .document
        default:
            // Extension nodes: type strings are "strikethrough", "table", "table_header", "table_row", "table_cell".
            guard let s = cmark_node_get_type_string(n) else { return .other }
            let c0 = s[0]
            if c0 == 115 { return .strike }
            if c0 == 116, s[1] == 97 {  // "ta…"
                if s[5] == 0 { return .table }
                switch s[6] {
                case 104: return .tableHead
                case 114: return .tableRow
                case 99: return .tableCell
                default: return .other
                }
            }
            return .other
        }
    }

    /// Mirrors swift-markdown's source range validation; returns (startLine, startColumn, endLine, endColumn exclusive).
    private func range(_ n: CMarkNode) -> (sl: Int, sc: Int, el: Int, ec: Int)? {
        let sl = Int(cmark_node_get_start_line(n)), sc = Int(cmark_node_get_start_column(n))
        guard sl > 0, sc > 0 else { return nil }
        let el = Int(cmark_node_get_end_line(n)), ec = Int(cmark_node_get_end_column(n)) + 1
        guard el > 0, ec > 0, sl < el || (sl == el && sc <= ec) else { return nil }
        return (sl, sc, el, ec)
    }

    private mutating func putDataLine(_ n: CMarkNode) {
        guard let r = range(n) else { return }
        let l = lineMap.isEmpty ? r.sl : lineMap[min(max(r.sl, 1), lineMap.count) - 1]
        put(" data-line=\"")
        putInt(l)
        out.append(34)
    }

    /// cmark reports a block that swallowed a trailing blank line as ending at column 1 of that blank line.
    private func lastContentLine(_ r: (sl: Int, sc: Int, el: Int, ec: Int)) -> Int {
        r.ec == 1 && r.el > r.sl ? r.el - 1 : r.el
    }

    private func isLoose(_ list: CMarkNode) -> Bool {
        var prevEnd: Int?
        var item = cmark_node_first_child(list)
        while let it = item {
            defer { item = cmark_node_next(it) }
            guard let r = range(it) else { continue }
            if let p = prevEnd, r.sl - p > 1 { return true }
            prevEnd = lastContentLine(r)
            var childEnd: Int?
            var child = cmark_node_first_child(it)
            while let c = child {
                defer { child = cmark_node_next(c) }
                guard let cr = range(c) else { continue }
                if let e = childEnd, cr.sl - e > 1 { return true }
                childEnd = lastContentLine(cr)
            }
        }
        return false
    }

    @inline(__always) private func isTask(_ item: CMarkNode) -> Bool {
        // Item type string is "item" or "tasklist".
        cmark_node_get_type_string(item)?[0] == 116
    }

    // MARK: Plain text (heading titles, alt text, URL-text detection)

    private func appendPlain(_ node: CMarkNode, _ buf: inout [UInt8]) {
        var c = cmark_node_first_child(node)
        while let n = c {
            switch cmark_node_get_type(n) {
            case CMARK_NODE_TEXT, CMARK_NODE_CODE: buf.append(contentsOf: literal(n))
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK: buf.append(32)
            case CMARK_NODE_HTML_INLINE: break
            default: appendPlain(n, &buf)
            }
            c = cmark_node_next(n)
        }
    }

    /// Plain text of `node` with math placeholders replaced by their raw TeX.
    private func plainText(_ node: CMarkNode) -> [UInt8] {
        var buf: [UInt8] = []
        appendPlain(node, &buf)
        guard !items.isEmpty else { return buf }
        return buf.withUnsafeBufferPointer { p -> [UInt8] in
            guard containsMathMarker(p) else { return buf }
            var r: [UInt8] = []
            r.reserveCapacity(p.count)
            scanMathPlaceholders(p, itemCount: items.count, onText: { r.append(contentsOf: $0) }, onMath: { r.append(contentsOf: items[$0].tex.utf8) })
            return r
        }
    }

    // MARK: Text and math

    private mutating func emitMath(_ item: MathItem, line: CMarkNode?, block: Bool) {
        hasMath = true
        words.space()
        if block {
            put("<div class=\"math-display\"")
            if let line { putDataLine(line) }
            out.append(62)
            putEscaped(item.tex)
            put("</div>\n")
        } else {
            if item.display { put("<span class=\"math-display\">") } else { put("<span class=\"math-inline\">") }
            putEscaped(item.tex)
            put("</span>")
        }
    }

    private mutating func emitText(_ p: UnsafeBufferPointer<UInt8>) {
        guard !p.isEmpty else { return }
        if !items.isEmpty, containsMathMarker(p) {
            scanMathPlaceholders(p, itemCount: items.count, onText: { t in
                self.putEscaped(t)
                self.words.feed(t)
            }, onMath: { self.emitMath(self.items[$0], line: nil, block: false) })
        } else {
            putEscaped(p)
            words.feed(p)
        }
    }

    /// Index of the math item when the paragraph consists solely of one display placeholder.
    private func standaloneDisplay(_ p: CMarkNode) -> Int? {
        guard !items.isEmpty, let first = cmark_node_first_child(p), cmark_node_get_type(first) == CMARK_NODE_TEXT,
              containsMathMarker(literal(first)) else { return nil }
        var s: [UInt8] = []
        var count = 0
        var c: CMarkNode? = first
        while let n = c {
            count += 1
            if count > 3 { return nil }
            switch cmark_node_get_type(n) {
            case CMARK_NODE_TEXT: s.append(contentsOf: literal(n))
            case CMARK_NODE_SOFTBREAK: s.append(32)
            default: return nil
            }
            c = cmark_node_next(n)
        }
        if s.contains(where: { $0 >= 0x80 }) {
            s = Array(String(decoding: s, as: UTF8.self).trimmingCharacters(in: .whitespaces).utf8)
        } else {
            var a = 0, b = s.count
            while a < b, s[a] == 32 || s[a] == 9 { a += 1 }
            while b > a, s[b - 1] == 32 || s[b - 1] == 9 { b -= 1 }
            s = Array(s[a..<b])
        }
        var result: Int?
        var pieces = 0
        s.withUnsafeBufferPointer { p in
            scanMathPlaceholders(p, itemCount: items.count, onText: { _ in pieces += 2 }, onMath: { result = $0; pieces += 1 })
        }
        guard pieces == 1, let i = result, items[i].display else { return nil }
        return i
    }

    // MARK: Walk

    /// Renders the whole document tree.
    mutating func render(_ root: CMarkNode) {
        guard let iter = cmark_iter_new(root) else { return }
        defer { cmark_iter_free(iter) }
        while true {
            let ev = cmark_iter_next(iter)
            if ev == CMARK_EVENT_DONE { break }
            guard let node = cmark_iter_get_node(iter) else { break }
            if ev == CMARK_EVENT_ENTER { enter(node, iter) } else { exit(node) }
        }
    }

    /// In a tight list item, consecutive blocks are separated by a newline when the previous output did not end with one.
    @inline(__always) private mutating func preBlock(_ n: CMarkNode) {
        guard let parent = cmark_node_parent(n), cmark_node_get_type(parent) == CMARK_NODE_ITEM,
              looseStack.last == false, cmark_node_previous(n) != nil, out.last != 10 else { return }
        out.append(10)
    }

    private mutating func enter(_ node: CMarkNode, _ iter: CMarkIter) {
        switch kind(node) {
        case .text:
            if let next = cmark_node_next(node), cmark_node_get_type(next) == CMARK_NODE_TEXT {
                // Adjacent text nodes form one run (placeholders may span them).
                var run: [UInt8] = Array(literal(node))
                var last = node
                var c: CMarkNode? = next
                while let n = c, cmark_node_get_type(n) == CMARK_NODE_TEXT {
                    run.append(contentsOf: literal(n))
                    last = n
                    c = cmark_node_next(n)
                }
                cmark_iter_reset(iter, last, CMARK_EVENT_EXIT)
                run.withUnsafeBufferPointer { emitText($0) }
            } else {
                emitText(literal(node))
            }
        case .softBreak:
            out.append(10); words.space()
        case .lineBreak:
            put("<br>\n"); words.space()
        case .code:
            put("<code>")
            let l = literal(node)
            putEscaped(l)
            put("</code>")
            words.feed(l)
        case .htmlInline:
            out.append(contentsOf: literal(node))
        case .emph: put("<em>")
        case .strong: put("<strong>")
        case .strike: put("<del>")
        case .link: enterLink(node)
        case .image:
            put("<img src=\"")
            putEscaped(UnsafeBufferPointer(cString: cmark_node_get_url(node)), attribute: true)
            put("\" alt=\"")
            let alt = plainText(node)
            alt.withUnsafeBufferPointer { putEscaped($0, attribute: true) }
            out.append(34)
            let title = UnsafeBufferPointer(cString: cmark_node_get_title(node))
            if !title.isEmpty { put(" title=\""); putEscaped(title, attribute: true); out.append(34) }
            out.append(62)
            cmark_iter_reset(iter, node, CMARK_EVENT_EXIT)  // alt text only; children are not rendered
        case .heading: enterHeading(node)
        case .paragraph: enterParagraph(node, iter)
        case .blockQuote:
            preBlock(node)
            put("<blockquote"); putDataLine(node); put(">\n")
        case .thematicBreak:
            preBlock(node)
            put("<hr"); putDataLine(node); put(">\n")
        case .htmlBlock:
            preBlock(node)
            let l = literal(node)
            out.append(contentsOf: l)
            if l.last != 10 { out.append(10) }
        case .codeBlock:
            preBlock(node)
            emitCodeBlock(node)
        case .list: enterList(node)
        case .item: enterItem(node)
        case .table:
            preBlock(node)
            tableAligns = cmark_gfm_extensions_get_table_alignments(node)
            tableColumns = Int(cmark_gfm_extensions_get_table_columns(node))
            put("<table"); putDataLine(node); put(">\n<thead>\n")
        case .tableHead:
            cellIndex = 0; cellInHeader = true
            put("<tr>")
        case .tableRow:
            cellIndex = 0; cellInHeader = false
            put("<tr>")
        case .tableCell: enterCell(node, iter)
        case .document, .other: break
        }
    }

    private mutating func exit(_ node: CMarkNode) {
        switch kind(node) {
        case .emph: put("</em>")
        case .strong: put("</strong>")
        case .strike: put("</del>")
        case .link:
            if cmark_node_get_start_line(node) == 0 { return }  // email linkified by the extension: rendered as text
            if linkIsURL { words = linkSaved; words.space() }
            put("</a>")
        case .heading:
            put("</h")
            putInt(min(max(Int(cmark_node_get_heading_level(node)), 1), 6))
            put(">\n")
            words.space()
        case .paragraph:
            switch paraMode {
            case .normal: put("</p>\n"); words.space()
            case .tightInline: words.space()
            case .standalone: break
            }
        case .blockQuote: put("</blockquote>\n")
        case .list:
            if cmark_node_get_list_type(node) == CMARK_ORDERED_LIST { put("</ol>\n") } else { put("</ul>\n") }
            looseStack.removeLast()
        case .item: put("</li>\n")
        case .table: put("</table>\n")
        case .tableHead:
            put("</tr>\n</thead>\n")
            if cmark_node_next(node) != nil { put("<tbody>\n") }
        case .tableRow:
            put("</tr>\n")
            if cmark_node_next(node) == nil { put("</tbody>\n") }
        case .tableCell:
            if !cellSkipped {
                if cellInHeader { put("</th>") } else { put("</td>") }
                words.space()
            }
        default: break
        }
    }

    // MARK: Block emitters

    private mutating func enterLink(_ node: CMarkNode) {
        // Emails linkified by the autolink extension carry no source position; they stay plain text.
        if cmark_node_get_start_line(node) == 0 { linkIsURL = false; return }
        let url = UnsafeBufferPointer(cString: cmark_node_get_url(node))
        let title = UnsafeBufferPointer(cString: cmark_node_get_title(node))
        let text = plainText(node)
        put("<a")
        if !url.isEmpty {
            put(" href=\"")
            // Bare `www.` links get an https scheme (the autolink extension would use http).
            if hasPrefix(url, "http://www."), text.count == url.count - 7, text.starts(with: url.dropFirst(7)) {
                put("https://")
                putEscaped(UnsafeBufferPointer(rebasing: url[7...]), attribute: true)
            } else {
                putEscaped(url, attribute: true)
            }
            out.append(34)
        }
        if !title.isEmpty { put(" title=\""); putEscaped(title, attribute: true); out.append(34) }
        out.append(62)
        // Bare/autolinked URLs are not words.
        linkIsURL = text.withUnsafeBufferPointer { t in
            if t.count == url.count, url.count > 0, memcmp(t.baseAddress!, url.baseAddress!, t.count) == 0 { return true }
            return hasPrefix(t, "http://") || hasPrefix(t, "https://") || hasPrefix(t, "www.")
        }
        linkSaved = words
    }

    @inline(__always) private func hasPrefix(_ t: UnsafeBufferPointer<UInt8>, _ p: StaticString) -> Bool {
        let n = p.utf8CodeUnitCount
        guard t.count >= n else { return false }
        return memcmp(t.baseAddress!, p.utf8Start, n) == 0
    }

    private mutating func enterHeading(_ node: CMarkNode) {
        preBlock(node)
        let title = String(decoding: plainText(node), as: UTF8.self)
        let id = slugger.slug(for: title)
        let level = min(max(Int(cmark_node_get_heading_level(node)), 1), 6)
        headings.append(Heading(id: id, level: level, title: title))
        words.space()
        put("<h"); putInt(level); put(" id=\""); putEscaped(id, attribute: true); out.append(34)
        putDataLine(node)
        out.append(62)
    }

    private mutating func enterParagraph(_ node: CMarkNode, _ iter: CMarkIter) {
        let standalone = standaloneDisplay(node)
        let inTightItem: Bool = {
            guard let parent = cmark_node_parent(node) else { return false }
            return cmark_node_get_type(parent) == CMARK_NODE_ITEM && looseStack.last == false
        }()
        if inTightItem, standalone == nil {
            paraMode = .tightInline
            if cmark_node_previous(node) != nil { out.append(10) }
            words.space()
            return
        }
        preBlock(node)
        if let i = standalone {
            paraMode = .standalone
            emitMath(items[i], line: node, block: true)
            cmark_iter_reset(iter, node, CMARK_EVENT_EXIT)
        } else {
            paraMode = .normal
            words.space()
            put("<p"); putDataLine(node); out.append(62)
        }
    }

    private mutating func emitCodeBlock(_ node: CMarkNode) {
        let info = UnsafeBufferPointer(cString: cmark_node_get_fence_info(node))
        let code = literal(node)
        // First info-string word, split on space, tab, `{` or `,`.
        @inline(__always) func isDelim(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 123 || b == 44 }
        var a = 0
        while a < info.count, isDelim(info[a]) { a += 1 }
        var e = a
        while e < info.count, !isDelim(info[e]) { e += 1 }
        let lang = UnsafeBufferPointer(rebasing: info[a..<e])

        var safe: [UInt8] = []
        var isMermaid = false, isMath = false
        if lang.allSatisfy({ $0 < 128 }) {
            safe.reserveCapacity(lang.count)
            for b in lang {
                let l = (b >= 65 && b <= 90) ? b + 32 : b
                if (l >= 97 && l <= 122) || (l >= 48 && l <= 57) || l == 45 || l == 95 || l == 43 || l == 35 || l == 46 { safe.append(l) }
            }
            // Anything but letters/digits/"-_+#." makes the full name differ from the filtered one.
            isMermaid = lang.count == 7 && safe.count == 7 && String(decoding: safe, as: UTF8.self) == "mermaid"
            isMath = lang.count == 4 && safe.count == 4 && String(decoding: safe, as: UTF8.self) == "math"
        } else {
            let lower = String(decoding: lang, as: UTF8.self).lowercased()
            isMermaid = lower == "mermaid"
            isMath = lower == "math"
            for u in lower.unicodeScalars where u.value < 128 && (u.properties.isAlphabetic || (48...57).contains(u.value) || u == "-" || u == "_" || u == "+" || u == "#" || u == ".") {
                safe.append(UInt8(u.value))
            }
        }

        if isMermaid {
            hasMermaid = true
            put("<div class=\"mermaid\""); putDataLine(node); put(" data-source=\"")
            putEscaped(code, attribute: true)
            put("\"></div>\n")
        } else if isMath {
            hasMath = true
            put("<div class=\"math-display\""); putDataLine(node); out.append(62)
            putEscaped(String(decoding: code, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            put("</div>\n")
        } else {
            put("<pre"); putDataLine(node)
            if safe.isEmpty { put("><code>") } else {
                put("><code class=\"language-")
                out.append(contentsOf: safe)
                put("\">")
            }
            putEscaped(code)
            put("</code></pre>\n")
        }
    }

    private mutating func enterList(_ node: CMarkNode) {
        preBlock(node)
        let loose = isLoose(node)
        looseStack.append(loose)
        var hasTask = false
        var c = cmark_node_first_child(node)
        while let it = c {
            if isTask(it) { hasTask = true; break }
            c = cmark_node_next(it)
        }
        if cmark_node_get_list_type(node) == CMARK_ORDERED_LIST {
            put("<ol")
            let start = Int(cmark_node_get_list_start(node))
            if start != 1 { put(" start=\""); putInt(start); out.append(34) }
        } else {
            put("<ul")
        }
        if hasTask { put(" class=\"contains-task-list\"") }
        putDataLine(node)
        put(">\n")
    }

    private mutating func enterItem(_ node: CMarkNode) {
        put("<li")
        let task = isTask(node)
        if task { put(" class=\"task\"") }
        putDataLine(node)
        out.append(62)
        if task {
            put("<input type=\"checkbox\" disabled")
            if cmark_gfm_extensions_get_tasklist_item_checked(node) { put(" checked") }
            put("> ")
        }
        if looseStack.last == true { out.append(10) }
    }

    private mutating func enterCell(_ node: CMarkNode, _ iter: CMarkIter) {
        let i = cellIndex
        cellIndex += 1
        let colspan = Int(cmark_gfm_extensions_get_table_cell_colspan(node))
        let rowspan = Int(cmark_gfm_extensions_get_table_cell_rowspan(node))
        if colspan == 0 || rowspan == 0 {
            cellSkipped = true
            cmark_iter_reset(iter, node, CMARK_EVENT_EXIT)
            return
        }
        cellSkipped = false
        if cellInHeader { put("<th") } else { put("<td") }
        if i < tableColumns, let aligns = tableAligns, aligns[i] != 0 {
            switch aligns[i] {
            case 108: put(" align=\"left\" style=\"text-align:left\"")
            case 114: put(" align=\"right\" style=\"text-align:right\"")
            default: put(" align=\"center\" style=\"text-align:center\"")
            }
        }
        if colspan > 1 { put(" colspan=\""); putInt(colspan); out.append(34) }
        if rowspan > 1 { put(" rowspan=\""); putInt(rowspan); out.append(34) }
        out.append(62)
        words.space()
    }
}
