import Foundation

/// Kinds of syntax spans produced by `MarkdownSyntax`. Overlapping tokens are allowed
/// (for example `strong` inside `linkText`); consumers apply them in order.
public enum SyntaxKind: Sendable, Equatable, Hashable {
    case headingMarker
    case headingText(level: Int)
    case strongMarker
    case strong
    case emphasisMarker
    case emphasis
    case codeSpan
    case fenceLine
    case codeBlock
    case linkText
    case linkURL
    case blockquote
    case listMarker
    case taskBox
    case math
    case hr
    case html
    case frontMatter
}

public struct SyntaxToken: Sendable, Equatable {
    /// UTF-16 range in the source string.
    public var range: NSRange
    public var kind: SyntaxKind
    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// Pure, line-oriented Markdown tokenizer used for source highlighting.
/// It is not a full CommonMark parser: it tracks multi-line state (front matter,
/// fences, `$$` blocks, HTML comments) and tokenizes everything else per line.
public enum MarkdownSyntax {
    /// Tokens for every line intersecting `range` (whole document when nil).
    /// Block state is always computed from the start of the text, so ranges inside
    /// a fence are classified correctly.
    public static func tokens(in text: String, range: NSRange? = nil) -> [SyntaxToken] {
        let units = Array(text.utf16)
        return tokens(utf16: units, range: range)
    }

    public static func tokens(utf16 units: [UInt16], range: NSRange? = nil) -> [SyntaxToken] {
        units.withUnsafeBufferPointer { buf in
            var engine = Engine(p: buf, range: range, inline: true)
            engine.run()
            return engine.out
        }
    }

    /// Ranges (UTF-16) of every multi-line block: front matter, fences, `$$` blocks, HTML comments.
    public static func blockRanges(in text: String) -> [NSRange] {
        blockRanges(utf16: Array(text.utf16))
    }

    public static func blockRanges(utf16 units: [UInt16]) -> [NSRange] {
        units.withUnsafeBufferPointer { buf in
            var engine = Engine(p: buf, range: nil, inline: false)
            engine.run()
            return engine.blocks
        }
    }

    /// Expands `around` to whole lines, and further to any multi-line block it touches.
    public static func paragraphRangeForHighlight(in text: String, around: NSRange) -> NSRange {
        paragraphRange(utf16: Array(text.utf16), around: around)
    }

    public static func paragraphRange(utf16 units: [UInt16], around: NSRange) -> NSRange {
        paragraphRange(utf16: units, around: around, blocks: blockRanges(utf16: units))
    }
}

// MARK: - Engine

private struct Engine {
    enum State { case none, fence(UInt16, Int, Int), math(Int), comment(Int) }

    let p: UnsafeBufferPointer<UInt16>
    let n: Int
    let lo: Int
    let hi: Int
    let wantAll: Bool
    let inline: Bool
    var out: [SyntaxToken] = []
    var blocks: [NSRange] = []

    init(p: UnsafeBufferPointer<UInt16>, range: NSRange?, inline: Bool) {
        self.p = p
        self.n = p.count
        self.inline = inline
        if let r = range {
            lo = max(0, r.location)
            hi = min(p.count, r.location + r.length)
            wantAll = false
        } else {
            lo = 0; hi = p.count; wantAll = true
        }
        if inline { out.reserveCapacity(wantAll ? max(16, p.count / 12) : 64) }
    }

    @inline(__always) func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 }
    @inline(__always) func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) func isAlnum(_ c: UInt16) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 127
    }

    @inline(__always) mutating func emit(_ s: Int, _ e: Int, _ k: SyntaxKind) {
        if e > s { out.append(SyntaxToken(range: NSRange(location: s, length: e - s), kind: k)) }
    }

    func lineEnd(from i: Int) -> Int {
        var j = i
        while j < n, p[j] != 10, p[j] != 13 { j += 1 }
        return j
    }

    func nextLine(after e: Int) -> Int {
        if e >= n { return n }
        if p[e] == 13, e + 1 < n, p[e + 1] == 10 { return e + 2 }
        return e + 1
    }

    func trimmedEnd(_ s: Int, _ e: Int) -> Int {
        var j = e
        while j > s, p[j - 1] == 32 || p[j - 1] == 9 { j -= 1 }
        return j
    }

    func skipSpaces(_ i: Int, _ e: Int) -> Int {
        var j = i
        while j < e, p[j] == 32 || p[j] == 9 { j += 1 }
        return j
    }

    /// True when `[s, e)` (already indent-skipped) is exactly `$$` plus optional whitespace.
    func isMathFence(_ s: Int, _ e: Int) -> Bool {
        let t = trimmedEnd(s, e)
        return t - s == 2 && p[s] == 36 && p[s + 1] == 36
    }

    mutating func run() {
        var pos = 0
        var state = State.none
        // Front matter.
        if n >= 3, p[0] == 45, p[1] == 45, p[2] == 45 {
            let e0 = lineEnd(from: 0)
            if trimmedEnd(0, e0) == 3, FrontMatterParser.isYAMLStart(count: n, lineStart: nextLine(after: e0), byteAt: { p[$0] }) {
                var q = nextLine(after: e0)
                while q < n {
                    let e = lineEnd(from: q)
                    let t = trimmedEnd(q, e)
                    if t - q == 3, (p[q] == 45 && p[q + 1] == 45 && p[q + 2] == 45) || (p[q] == 46 && p[q + 1] == 46 && p[q + 2] == 46) {
                        let end = nextLine(after: e)
                        blocks.append(NSRange(location: 0, length: end))
                        if inline, wantAll || (0 < hi && end > lo) || (lo == 0 && hi == 0) {
                            out.append(SyntaxToken(range: NSRange(location: 0, length: trimmedEndOfBlock(end)), kind: .frontMatter))
                        }
                        pos = end
                        break
                    }
                    q = nextLine(after: e)
                }
            }
        }

        while pos < n {
            let ls = pos
            let le = lineEnd(from: ls)
            let nl = nextLine(after: le)
            if !wantAll && ls > hi { break }
            let wanted = inline && (wantAll || (nl > lo && ls <= hi) || (ls == hi && hi == lo))
            let s = skipSpaces(ls, le)

            switch state {
            case .fence(let ch, let len, let bs):
                var k = s
                while k < le, p[k] == ch { k += 1 }
                let isClose = k - s >= len && trimmedEnd(k, le) == k
                if isClose {
                    if wanted { emit(ls, le, .fenceLine) }
                    blocks.append(NSRange(location: bs, length: nl - bs))
                    state = .none
                } else if wanted {
                    emit(ls, le, .codeBlock)
                }
            case .math(let bs):
                let t = trimmedEnd(ls, le)
                let closes = t - ls >= 2 && p[t - 1] == 36 && p[t - 2] == 36
                if wanted { emit(ls, le, .math) }
                if closes {
                    blocks.append(NSRange(location: bs, length: nl - bs))
                    state = .none
                }
            case .comment(let bs):
                if wanted { emit(ls, le, .html) }
                if containsCommentEnd(ls, le) {
                    blocks.append(NSRange(location: bs, length: nl - bs))
                    state = .none
                }
            case .none:
                if s >= le { break }
                let c = p[s]
                // Fence open.
                if c == 96 || c == 126 {
                    var k = s
                    while k < le, p[k] == c { k += 1 }
                    if k - s >= 3 {
                        var ok = true
                        if c == 96 { var j = k; while j < le { if p[j] == 96 { ok = false; break }; j += 1 } }
                        if ok {
                            if wanted { emit(ls, le, .fenceLine) }
                            state = .fence(c, k - s, ls)
                            break
                        }
                    }
                }
                // Display math fence.
                if c == 36, s + 1 < le, p[s + 1] == 36 {
                    let t = trimmedEnd(s, le)
                    var closesSameLine = false
                    if t - s > 2 {
                        var j = s + 2
                        while j + 1 < t { if p[j] == 36, p[j + 1] == 36 { closesSameLine = true; break }; j += 1 }
                    }
                    if !closesSameLine {
                        if wanted { emit(ls, le, .math) }
                        state = .math(ls)
                        break
                    }
                }
                // HTML comment block.
                if c == 60, s + 3 < le, p[s + 1] == 33, p[s + 2] == 45, p[s + 3] == 45 {
                    if wanted { emit(ls, le, .html) }
                    if !containsCommentEnd(s + 4, le) { state = .comment(ls) }
                    break
                }
                if wanted { lineBlock(ls: ls, s: s, le: le) }
            }
            pos = nl
        }
        // Unterminated blocks run to the end.
        switch state {
        case .fence(_, _, let bs), .math(let bs), .comment(let bs):
            blocks.append(NSRange(location: bs, length: n - bs))
        case .none: break
        }
    }

    func trimmedEndOfBlock(_ end: Int) -> Int {
        var e = end
        while e > 0, p[e - 1] == 10 || p[e - 1] == 13 { e -= 1 }
        return e
    }

    func containsCommentEnd(_ s: Int, _ e: Int) -> Bool {
        var j = s
        while j + 3 <= e {
            if p[j] == 45, p[j + 1] == 45, p[j + 2] == 62 { return true }
            j += 1
        }
        return false
    }

    // MARK: Block-level line

    mutating func lineBlock(ls: Int, s sIn: Int, le: Int) {
        var s = sIn
        // Blockquote prefixes.
        if p[s] == 62 {
            let q = s
            while s < le, p[s] == 62 {
                s += 1
                s = skipSpaces(s, le)
            }
            emit(q, trimmedEnd(q, le), .blockquote)
            if s >= le { return }
        }
        let c = p[s]
        let te = trimmedEnd(s, le)
        // Heading.
        if c == 35 {
            var k = s
            while k < le, p[k] == 35 { k += 1 }
            let level = k - s
            if level <= 6, k == le || p[k] == 32 || p[k] == 9 {
                emit(s, k, .headingMarker)
                let ts = skipSpaces(k, le)
                var tend = te
                // Strip closing #s.
                var j = tend
                while j > ts, p[j - 1] == 35 { j -= 1 }
                if j < tend, j == ts || p[j - 1] == 32 || p[j - 1] == 9 { tend = trimmedEnd(ts, j) }
                if tend > ts {
                    emit(ts, tend, .headingText(level: level))
                    inlineRun(ts, tend, 0)
                }
                return
            }
        }
        // Horizontal rule.
        if c == 45 || c == 42 || c == 95 {
            var count = 0
            var j = s
            var only = true
            while j < le {
                if p[j] == c { count += 1 } else if p[j] != 32 && p[j] != 9 { only = false; break }
                j += 1
            }
            if only, count >= 3 { emit(s, te, .hr); return }
        }
        var contentStart = s
        // Bullet list.
        if (c == 45 || c == 43 || c == 42), s + 1 >= le || p[s + 1] == 32 || p[s + 1] == 9 {
            emit(s, s + 1, .listMarker)
            contentStart = skipSpaces(s + 1, le)
            contentStart = taskBox(contentStart, le)
            if contentStart < te { inlineRun(contentStart, te, 0) }
            return
        }
        // Ordered list.
        if isDigit(c) {
            var k = s
            while k < le, isDigit(p[k]), k - s < 9 { k += 1 }
            if k < le, p[k] == 46 || p[k] == 41, k + 1 >= le || p[k + 1] == 32 || p[k + 1] == 9 {
                emit(s, k + 1, .listMarker)
                contentStart = skipSpaces(k + 1, le)
                contentStart = taskBox(contentStart, le)
                if contentStart < te { inlineRun(contentStart, te, 0) }
                return
            }
        }
        // HTML block line.
        if c == 60, s + 1 < le {
            var k = s + 1
            if p[k] == 47 { k += 1 }
            let nameStart = k
            while k < le, isAlnum(p[k]) || p[k] == 45 { k += 1 }
            if k > nameStart, k >= le || p[k] == 62 || p[k] == 32 || p[k] == 47 || p[k] == 9 {
                emit(s, te, .html)
                return
            }
        }
        // Reference / footnote definition.
        if c == 91 {
            var k = s + 1
            while k < le, p[k] != 93 { if p[k] == 92 { k += 1 }; k += 1 }
            if k + 1 < le, p[k] == 93, p[k + 1] == 58 {
                emit(s, k + 1, .linkText)
                let us = skipSpaces(k + 2, le)
                if te > us { emit(us, te, .linkURL) }
                return
            }
        }
        inlineRun(s, te, 0)
    }

    /// Emits a task box when `[ ]`, `[x]` or `[X]` sits at `i`. Returns the content start.
    mutating func taskBox(_ i: Int, _ le: Int) -> Int {
        if i + 2 < le, p[i] == 91, p[i + 2] == 93, p[i + 1] == 32 || p[i + 1] == 120 || p[i + 1] == 88,
           i + 3 >= le || p[i + 3] == 32 || p[i + 3] == 9 {
            emit(i, i + 3, .taskBox)
            return skipSpaces(i + 3, le)
        }
        return i
    }

    // MARK: Inline

    /// Finds the end of a code span starting at the backtick run `[i, j)`; returns the end index or nil.
    func codeSpanEnd(_ j: Int, runLength: Int, _ e: Int) -> Int? {
        var k = j
        while k < e {
            if p[k] == 96 {
                var m = k
                while m < e, p[m] == 96 { m += 1 }
                if m - k == runLength { return m }
                k = m
            } else { k += 1 }
        }
        return nil
    }

    mutating func inlineRun(_ s: Int, _ e: Int, _ depth: Int) {
        guard inline, e > s, e - s < 8000, depth < 4 else { return }
        var i = s
        while i < e {
            let c = p[i]
            switch c {
            case 92:
                i += 2
            case 96:
                var j = i
                while j < e, p[j] == 96 { j += 1 }
                if let end = codeSpanEnd(j, runLength: j - i, e) {
                    emit(i, end, .codeSpan)
                    i = end
                } else { i = j }
            case 36:
                i = mathSpan(i, e)
            case 33, 91:
                i = linkSpan(i, e, depth)
            case 42, 95:
                i = emphasisSpan(i, e, depth)
            case 60:
                if i + 5 < e, p[i + 1] == 104 || p[i + 1] == 109 {
                    var k = i + 1
                    var ok = false
                    while k < e {
                        if p[k] == 62 { ok = true; break }
                        if p[k] == 32 { break }
                        k += 1
                    }
                    if ok, hasURLScheme(i + 1, k) { emit(i, k + 1, .linkURL); i = k + 1; break }
                }
                i += 1
            case 104:
                if i + 7 < e, p[i + 1] == 116, p[i + 2] == 116, p[i + 3] == 112, i == s || !isAlnum(p[i - 1]), hasURLScheme(i, e) {
                    var k = i
                    while k < e, p[k] != 32, p[k] != 9, p[k] != 60, p[k] != 62 { k += 1 }
                    while k > i {
                        let t = p[k - 1]
                        if t == 46 || t == 44 || t == 59 || t == 58 || t == 33 || t == 63 || t == 41 || t == 93 || t == 39 || t == 34 || t == 42 || t == 95 { k -= 1 } else { break }
                    }
                    emit(i, k, .linkURL)
                    i = max(k, i + 1)
                } else { i += 1 }
            default:
                i += 1
            }
        }
    }

    func hasURLScheme(_ i: Int, _ e: Int) -> Bool {
        func m(_ str: StaticString) -> Bool {
            let len = str.utf8CodeUnitCount
            if i + len > e { return false }
            let b = str.utf8Start
            for k in 0..<len where UInt16(b[k]) != p[i + k] { return false }
            return true
        }
        return m("http://") || m("https://") || m("mailto:")
    }

    mutating func mathSpan(_ i: Int, _ e: Int) -> Int {
        if i + 1 < e, p[i + 1] == 36 {
            var k = i + 2
            while k + 1 < e {
                if p[k] == 92 { k += 2; continue }
                if p[k] == 36, p[k + 1] == 36, k > i + 2 { emit(i, k + 2, .math); return k + 2 }
                k += 1
            }
            return i + 2
        }
        guard i + 1 < e, !isSpace(p[i + 1]) else { return i + 1 }
        if i > 0, isAlnum(p[i - 1]) { return i + 1 }
        var k = i + 1
        while k < e {
            if p[k] == 92 { k += 2; continue }
            if p[k] == 36 {
                if !isSpace(p[k - 1]), !(k + 1 < e && isDigit(p[k + 1])) {
                    emit(i, k + 1, .math)
                    return k + 1
                }
                return i + 1
            }
            k += 1
        }
        return i + 1
    }

    mutating func linkSpan(_ i: Int, _ e: Int, _ depth: Int) -> Int {
        var open = i
        if p[i] == 33 {
            guard i + 1 < e, p[i + 1] == 91 else { return i + 1 }
            open = i + 1
        }
        var depthB = 1
        var k = open + 1
        var close = -1
        while k < e {
            let ch = p[k]
            if ch == 92 { k += 2; continue }
            if ch == 96 {
                var m = k
                while m < e, p[m] == 96 { m += 1 }
                if let end = codeSpanEnd(m, runLength: m - k, e) { k = end } else { k = m }
                continue
            }
            if ch == 91 { depthB += 1 } else if ch == 93 {
                depthB -= 1
                if depthB == 0 { close = k; break }
            }
            k += 1
        }
        guard close > 0 else { return i + 1 }
        if close + 1 < e, p[close + 1] == 40 {
            var d = 1
            var q = close + 2
            while q < e {
                let ch = p[q]
                if ch == 92 { q += 2; continue }
                if ch == 40 { d += 1 } else if ch == 41 { d -= 1; if d == 0 { break } }
                q += 1
            }
            if q < e, d == 0 {
                emit(i, close + 1, .linkText)
                emit(close + 1, q + 1, .linkURL)
                inlineRun(open + 1, close, depth + 1)
                return q + 1
            }
        } else if close + 1 < e, p[close + 1] == 91 {
            var q = close + 2
            while q < e, p[q] != 93 { q += 1 }
            if q < e {
                emit(i, close + 1, .linkText)
                emit(close + 1, q + 1, .linkURL)
                inlineRun(open + 1, close, depth + 1)
                return q + 1
            }
        }
        // Footnote reference or plain brackets: skip the opener only.
        return i + 1
    }

    mutating func emphasisSpan(_ i: Int, _ e: Int, _ depth: Int) -> Int {
        let c = p[i]
        var j = i
        while j < e, p[j] == c { j += 1 }
        let run = j - i
        guard run <= 3, j < e, !isSpace(p[j]) else { return j }
        if c == 95, i > 0, isAlnum(p[i - 1]) { return j }
        // Find closer.
        var k = j
        var closeStart = -1
        while k < e {
            let ch = p[k]
            if ch == 92 { k += 2; continue }
            if ch == 96 {
                var m = k
                while m < e, p[m] == 96 { m += 1 }
                if let end = codeSpanEnd(m, runLength: m - k, e) { k = end } else { k = m }
                continue
            }
            if ch == c {
                var m = k
                while m < e, p[m] == c { m += 1 }
                let mlen = m - k
                if mlen >= run, k > j, !isSpace(p[k - 1]), c == 42 || !(m < e && isAlnum(p[m])) {
                    closeStart = m - run
                    break
                }
                k = m
                continue
            }
            k += 1
        }
        guard closeStart >= 0 else { return j }
        switch run {
        case 1:
            emit(i, i + 1, .emphasisMarker)
            emit(j, closeStart, .emphasis)
            emit(closeStart, closeStart + 1, .emphasisMarker)
        case 2:
            emit(i, i + 2, .strongMarker)
            emit(j, closeStart, .strong)
            emit(closeStart, closeStart + 2, .strongMarker)
        default:
            emit(i, i + 1, .emphasisMarker)
            emit(i + 1, i + 3, .strongMarker)
            emit(j, closeStart, .strong)
            emit(j, closeStart, .emphasis)
            emit(closeStart, closeStart + 2, .strongMarker)
            emit(closeStart + 2, closeStart + 3, .emphasisMarker)
        }
        inlineRun(j, closeStart, depth + 1)
        return closeStart + run
    }
}

public extension MarkdownSyntax {
    /// Same as `paragraphRange(utf16:around:)` but reuses already computed `blockRanges`.
    static func paragraphRange(utf16 units: [UInt16], around: NSRange, blocks: [NSRange]) -> NSRange {
        let n = units.count
        let loc = max(0, min(around.location, n))
        let end = max(loc, min(around.location + around.length, n))
        var lo = loc
        while lo > 0, units[lo - 1] != 10, units[lo - 1] != 13 { lo -= 1 }
        var hi = end
        while hi < n, units[hi] != 10, units[hi] != 13 { hi += 1 }
        if hi < n { hi += (units[hi] == 13 && hi + 1 < n && units[hi + 1] == 10) ? 2 : 1 }
        for b in blocks {
            if b.location >= hi { break }
            let bEnd = b.location + b.length
            if bEnd > lo && b.location < hi {
                lo = min(lo, b.location)
                hi = max(hi, bEnd)
            }
        }
        return NSRange(location: lo, length: hi - lo)
    }
}
