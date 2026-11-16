import SwiftUI

enum Theme: String, CaseIterable, Identifiable, Sendable {
    case auto, light, dark, sepia
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Appearance forced on the window; Auto follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light, .sepia: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum Typeface: String, CaseIterable, Identifiable, Sendable {
    case system, serif, mono
    var id: String { rawValue }
    var label: String { switch self { case .system: "SF"; case .serif: "New York"; case .mono: "SF Mono" } }
    var font: Font {
        switch self {
        case .system: .system(size: 20)
        case .serif: .system(size: 20, design: .serif)
        case .mono: .system(size: 20, design: .monospaced)
        }
    }
}

enum LineWidth: String, CaseIterable, Identifiable, Sendable {
    case narrow, wide
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ViewMode: String, CaseIterable, Identifiable, Sendable {
    case read, split, edit
    var id: String { rawValue }
}

enum OutlineVisibility: String, CaseIterable, Identifiable, Sendable {
    case automatic, always, never
    var id: String { rawValue }
    var label: String { switch self { case .automatic: "Automatically"; case .always: "Always"; case .never: "Never" } }
}

enum PrefKey {
    static let theme = "theme"
    static let typeface = "typeface"
    static let fontSize = "fontSize"
    static let width = "lineWidth"
    static let defaultMode = "defaultMode"
    static let outline = "outlineVisibility"
    static let sidebarChoice = "sidebarChoice"   // "", "shown" or "hidden": the user's own toggle
    static let reloadOnChange = "reloadOnChange"
    static let showFrontMatter = "showFrontMatter"
    static let spellcheck = "editorSpellcheck"

    static let sizeRange: ClosedRange<Double> = 13...24

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            theme: Theme.auto.rawValue, typeface: Typeface.system.rawValue, fontSize: 16.0, width: LineWidth.narrow.rawValue,
            defaultMode: ViewMode.read.rawValue, outline: OutlineVisibility.automatic.rawValue,
            sidebarChoice: "", reloadOnChange: true, showFrontMatter: false, spellcheck: false,
        ])
    }

    static var currentTheme: Theme { Theme(rawValue: UserDefaults.standard.string(forKey: theme) ?? "") ?? .auto }
    static var defaultViewMode: ViewMode { ViewMode(rawValue: UserDefaults.standard.string(forKey: defaultMode) ?? "") ?? .read }

    /// Style dictionary for `MarkText.setStyle`.
    static var webStyle: [String: Any] {
        let d = UserDefaults.standard
        return [
            "theme": currentTheme.rawValue,
            "font": d.string(forKey: typeface) ?? "system",
            "size": min(max(d.double(forKey: fontSize), sizeRange.lowerBound), sizeRange.upperBound),
            "width": d.string(forKey: width) ?? "narrow",
        ]
    }

    static func adjustSize(by delta: Double?) {
        let d = UserDefaults.standard
        let new = delta.map { d.double(forKey: fontSize) + $0 } ?? 16
        d.set(min(max(new, sizeRange.lowerBound), sizeRange.upperBound), forKey: fontSize)
    }
}

extension Color {
    static let sepiaPaper = Color(red: 0xF6 / 255, green: 0xF0 / 255, blue: 0xE4 / 255)
}
extension NSColor {
    static let sepiaPaper = NSColor(srgbRed: 0xF6 / 255, green: 0xF0 / 255, blue: 0xE4 / 255, alpha: 1)
}
