import Foundation

struct FrontMatter {
    /// Raw YAML between the fences (no trailing newline).
    let yaml: String
    /// Source with the front matter lines replaced by empty lines (keeps line numbers stable).
    let body: String
}

enum FrontMatterParser {
    /// The line after the opening fence must look like YAML (`key:` or a `#` comment); otherwise
    /// `---` is a thematic break and the document has no front matter.
    static func isYAMLStart(count n: Int, lineStart: Int, byteAt at: (Int) -> UInt16) -> Bool {
        guard lineStart < n else { return false }
        if at(lineStart) == 35 { return true }   // '#'
        var i = lineStart
        func isKeyByte(_ b: UInt16) -> Bool { (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 45 }
        while i < n, isKeyByte(at(i)) { i += 1 }
        guard i > lineStart else { return false }
        while i < n, at(i) == 32 || at(i) == 9 { i += 1 }
        return i < n && at(i) == 58
    }

    static func extract(_ text: String) -> FrontMatter? {
        guard text.hasPrefix("---") else { return nil }
        let u = Array(text.utf8)
        let n = u.count
        func lineEnd(_ from: Int) -> Int { var j = from; while j < n && u[j] != 10 { j += 1 }; return j }
        func isFence(_ a: Int, _ b: Int, _ ch: UInt8) -> Bool {
            guard b - a >= 3 else { return false }
            for k in a..<(a + 3) where u[k] != ch { return false }
            for k in (a + 3)..<b where u[k] != 32 && u[k] != 9 { return false }
            return true
        }
        let firstEnd = lineEnd(0)
        guard isFence(0, firstEnd, 45) else { return nil }
        guard isYAMLStart(count: n, lineStart: firstEnd + 1, byteAt: { UInt16(u[$0]) }) else { return nil }
        var pos = firstEnd + 1
        var lines = 1
        while pos <= n {
            let e = lineEnd(pos)
            lines += 1
            if pos < n || e > pos, isFence(pos, e, 45) || isFence(pos, e, 46) {
                let yamlStart = min(firstEnd + 1, n)
                let yaml = String(decoding: u[yamlStart..<max(yamlStart, pos - 1)], as: UTF8.self)
                let rest = e < n ? String(decoding: u[(e + 1)...], as: UTF8.self) : ""
                let body = String(repeating: "\n", count: lines) + rest
                return FrontMatter(yaml: yaml, body: body)
            }
            if e >= n { break }
            pos = e + 1
        }
        return nil
    }
}
