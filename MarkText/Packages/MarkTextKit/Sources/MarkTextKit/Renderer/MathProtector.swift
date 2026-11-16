import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct MathItem: Sendable {
    let tex: String
    let display: Bool
}

struct ProtectedSource {
    var text: String
    /// `lineMap[processedLine - 1]` = original 1-based line. Empty means identity.
    var lineMap: [Int]
    var items: [MathItem]
}

/// Two-pass math masking: parse once to find code / HTML ranges, scan the rest for
/// pandoc-style `$…$` and `$$…$$`, substitute alphanumeric placeholders, parse again.
enum MathProtector {
    static let marker = "MTKMATH"

    static func placeholder(_ index: Int, display: Bool) -> String { "\(marker)\(display ? "D" : "I")\(index)Z" }

    private struct Span { let start: Int; let end: Int; let texStart: Int; let texEnd: Int; let display: Bool }

    static func protect(_ text: String) -> ProtectedSource {
        let bytes = Array(text.utf8)
        let identity = ProtectedSource(text: text, lineMap: [], items: [])
        guard bytes.contains(36) else { return identity }
        // Cheap pre-scan without exclusions: avoids a second parse for documents with a stray `$`.
        guard !scan(bytes, excluded: []).isEmpty else { return identity }

        let excluded = excludedRanges(bytes)
        let spans = scan(bytes, excluded: excluded)
        if spans.isEmpty { return identity }

        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var lineMap = [1]
        var orig = 1
        var items: [MathItem] = []
        var cursor = 0

        func copy(_ a: Int, _ b: Int) {
            guard a < b else { return }
            for k in a..<b {
                let c = bytes[k]
                out.append(c)
                if c == 10 { orig += 1; lineMap.append(orig) }
            }
        }
        for s in spans {
            copy(cursor, s.start)
            for k in s.start..<s.end where bytes[k] == 10 { orig += 1 }
            var tex = String(decoding: bytes[s.texStart..<s.texEnd], as: UTF8.self)
            if s.display { tex = tex.trimmingCharacters(in: .whitespacesAndNewlines) }
            out.append(contentsOf: placeholder(items.count, display: s.display).utf8)
            items.append(MathItem(tex: tex, display: s.display))
            cursor = s.end
        }
        copy(cursor, bytes.count)
        return ProtectedSource(text: String(decoding: out, as: UTF8.self), lineMap: lineMap, items: items)
    }

    // MARK: Scanning

    private static func scan(_ b: [UInt8], excluded: [Range<Int>]) -> [Span] {
        let n = b.count
        var spans: [Span] = []
        var i = 0
        var ex = 0
        @inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 }
        while i < n {
            while ex < excluded.count && excluded[ex].upperBound <= i { ex += 1 }
            if ex < excluded.count && excluded[ex].lowerBound <= i { i = excluded[ex].upperBound; continue }
            let limit = ex < excluded.count ? excluded[ex].lowerBound : n
            let c = b[i]
            if c == 92 { i += 2; continue }
            if c != 36 { i += 1; continue }

            if i + 1 < limit && b[i + 1] == 36 {
                // Display math: $$ … $$ (may span lines, but not blank lines).
                var j = i + 2
                var found = -1
                while j < limit {
                    let d = b[j]
                    if d == 92 { j += 2; continue }
                    if d == 36 && j + 1 < limit && b[j + 1] == 36 { found = j; break }
                    if d == 10 {
                        var k = j + 1
                        while k < limit && (b[k] == 32 || b[k] == 9) { k += 1 }
                        if k < n && b[k] == 10 { break }
                    }
                    j += 1
                }
                if found >= 0, b[(i + 2)..<found].contains(where: { !isSpace($0) }) {
                    spans.append(Span(start: i, end: found + 2, texStart: i + 2, texEnd: found, display: true))
                    i = found + 2
                } else {
                    i += 2
                }
                continue
            }

            // Inline math: opener followed by non-space, closer preceded by non-space and not followed by a digit.
            guard i + 1 < limit, !isSpace(b[i + 1]) else { i += 1; continue }
            var j = i + 1
            var found = -1
            while j < limit {
                let d = b[j]
                if d == 10 { break }
                if d == 92 { j += 2; continue }
                if d == 36 {
                    if isSpace(b[j - 1]) { break }
                    if j + 1 < n, b[j + 1] >= 48, b[j + 1] <= 57 { break }
                    found = j
                    break
                }
                j += 1
            }
            if found >= 0 {
                spans.append(Span(start: i, end: found + 1, texStart: i + 1, texEnd: found, display: false))
                i = found + 1
            } else {
                i += 1
            }
        }
        return spans
    }

    // MARK: Code / HTML ranges

    /// Source ranges (UTF-8 byte offsets) of code blocks, code spans and raw HTML, found with a raw cmark parse
    /// (far cheaper than building the swift-markdown tree).
    private static func excludedRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var starts = [0]
        for (k, c) in bytes.enumerated() where c == 10 { starts.append(k + 1) }
        let n = bytes.count
        func lineStart(_ l: Int) -> Int { starts[min(max(l, 1), starts.count) - 1] }
        func lineEnd(_ l: Int) -> Int { l < starts.count ? starts[max(l, 1)] - 1 : n }

        guard let doc = bytes.withUnsafeBufferPointer({ CMark.parse($0, options: CMARK_OPT_SOURCEPOS, extensions: ["table"]) }),
              let iter = cmark_iter_new(doc) else { return [] }
        defer { cmark_iter_free(iter); cmark_node_free(doc) }

        var ranges: [Range<Int>] = []
        while true {
            let ev = cmark_iter_next(iter)
            if ev == CMARK_EVENT_DONE { break }
            guard ev == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iter) else { continue }
            let type = cmark_node_get_type(node)
            guard type == CMARK_NODE_CODE_BLOCK || type == CMARK_NODE_HTML_BLOCK || type == CMARK_NODE_CODE || type == CMARK_NODE_HTML_INLINE else { continue }
            let sl = Int(cmark_node_get_start_line(node)), el = Int(cmark_node_get_end_line(node))
            switch type {
            case CMARK_NODE_CODE_BLOCK, CMARK_NODE_HTML_BLOCK:
                let a = lineStart(sl)
                ranges.append(a..<max(a, lineEnd(el)))
            case CMARK_NODE_CODE, CMARK_NODE_HTML_INLINE:
                let a = min(lineStart(sl) + max(Int(cmark_node_get_start_column(node)) - 1, 0), n)
                let e = min(lineStart(el) + max(Int(cmark_node_get_end_column(node)), 0), n)
                if e > a { ranges.append(a..<e) }
            default: break
            }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in sorted {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
