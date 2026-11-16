import Foundation

/// Pure logic for "Return continues the list / quote / task" in the source editor.
public enum ListContinuation {
    public enum Action: Equatable, Sendable {
        /// Let the text view insert a plain newline.
        case none
        /// Replace the selection with this text (starts with "\n").
        case insert(String)
        /// Remove this range (relative to the line start): Return on an empty marker line.
        case clear(NSRange)
    }

    /// - Parameters:
    ///   - line: the current line without its terminator.
    ///   - caret: UTF-16 offset of the caret within `line`.
    public static func action(line: String, caret: Int) -> Action {
        let p = Array(line.utf16)
        let n = p.count
        var i = 0
        while i < n, p[i] == 32 || p[i] == 9 { i += 1 }
        var sawQuote = false
        while i < n, p[i] == 62 {
            sawQuote = true
            i += 1
            if i < n, p[i] == 32 { i += 1 }
        }
        while i < n, p[i] == 32 || p[i] == 9 { i += 1 }
        let markerStart = i
        var next: String?
        var prefixEnd = markerStart

        if i + 1 < n, p[i] == 45 || p[i] == 43 || p[i] == 42, p[i + 1] == 32 {
            next = String(utf16CodeUnits: [p[i]], count: 1) + " "
            prefixEnd = i + 2
        } else if i < n, p[i] >= 48, p[i] <= 57 {
            var k = i
            var value = 0
            while k < n, p[k] >= 48, p[k] <= 57, k - i < 9 { value = value * 10 + Int(p[k] - 48); k += 1 }
            if k + 1 < n, p[k] == 46 || p[k] == 41, p[k + 1] == 32 {
                next = "\(value + 1)" + String(utf16CodeUnits: [p[k]], count: 1) + " "
                prefixEnd = k + 2
            }
        }
        var task = false
        if next != nil, prefixEnd + 3 <= n, p[prefixEnd] == 91, p[prefixEnd + 2] == 93,
           p[prefixEnd + 1] == 32 || p[prefixEnd + 1] == 120 || p[prefixEnd + 1] == 88,
           prefixEnd + 3 == n || p[prefixEnd + 3] == 32 {
            task = true
            prefixEnd = min(n, prefixEnd + 4)
        }
        if next == nil {
            guard sawQuote else { return .none }
            prefixEnd = markerStart
        }
        guard caret >= prefixEnd || (next == nil && caret >= markerStart) else { return .none }
        let rest = p[prefixEnd...]
        let empty = rest.allSatisfy { $0 == 32 || $0 == 9 }
        if empty { return .clear(NSRange(location: 0, length: n)) }
        let lead = String(utf16CodeUnits: Array(p[0..<markerStart]), count: markerStart)
        return .insert("\n" + lead + (next ?? "") + (task ? "[ ] " : ""))
    }
}
