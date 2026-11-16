import Foundation

/// GitHub-style heading slugs with `-1`, `-2` de-duplication.
struct Slugger {
    private var used: Set<String> = []
    private var counts: [String: Int] = [:]

    static func baseSlug(_ title: String) -> String {
        var out = String.UnicodeScalarView()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for s in trimmed.unicodeScalars {
            if s == "-" || s == "_" { out.append(s); continue }
            if s.properties.isWhitespace { out.append("-"); continue }
            if s.value == 0xFE0F || s.value == 0x200D { continue }
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .nonspacingMark, .spacingMark, .connectorPunctuation:
                out.append(s)
            default:
                break
            }
        }
        return String(out)
    }

    mutating func slug(for title: String) -> String {
        var base = Self.baseSlug(title)
        if base.isEmpty { base = "section" }
        var candidate = base
        if used.contains(candidate) {
            var n = counts[base, default: 0] + 1
            while used.contains("\(base)-\(n)") { n += 1 }
            counts[base] = n
            candidate = "\(base)-\(n)"
        }
        used.insert(candidate)
        return candidate
    }
}
