import AppKit

enum EditorTheme: String, CaseIterable, Sendable {
    case auto, light, dark, sepia
}

struct EditorStyle: Equatable, Sendable {
    /// Reading font size (default 16). The editor font is `13.5 * fontSize / 16`.
    var fontSize: CGFloat = 16
    var theme: EditorTheme = .auto
    /// Extra space under the toolbar; the editor applies it as scroll-view content inset.
    var topInset: CGFloat = 0

    var editorFontSize: CGFloat { (13.5 * fontSize / 16 * 2).rounded() / 2 }
}

struct EditorScrollRequest: Equatable, Sendable {
    /// 1-based source line that should end up at the top of the editor.
    var line: Int
    var id: UUID = UUID()
}

/// Colors used by the syntax highlighter. Auto, light and dark use semantic system colors
/// (the window appearance decides); sepia uses the warm palette from the reading CSS.
struct EditorPalette {
    var text: NSColor
    var secondary: NSColor
    var tertiary: NSColor
    var code: NSColor
    var link: NSColor
    var math: NSColor
    var caret: NSColor
    var selection: NSColor

    static func make(_ theme: EditorTheme) -> EditorPalette {
        switch theme {
        case .auto, .light, .dark:
            return EditorPalette(
                text: .labelColor,
                secondary: .secondaryLabelColor,
                tertiary: .tertiaryLabelColor,
                code: NSColor.systemPink.withAlphaComponent(0.9),
                link: .controlAccentColor,
                math: .systemPurple,
                caret: .controlAccentColor,
                selection: .selectedTextBackgroundColor)
        case .sepia:
            func ink(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0x3a / 255, green: 0x30 / 255, blue: 0x26 / 255, alpha: a) }
            let accent = NSColor(srgbRed: 0x9a / 255, green: 0x5b / 255, blue: 0x13 / 255, alpha: 1)
            return EditorPalette(
                text: ink(1),
                secondary: ink(0.62),
                tertiary: ink(0.42),
                code: NSColor(srgbRed: 0xa9 / 255, green: 0x4a / 255, blue: 0x2a / 255, alpha: 0.95),
                link: accent,
                math: NSColor(srgbRed: 0x8a / 255, green: 0x4a / 255, blue: 0x9a / 255, alpha: 1),
                caret: accent,
                selection: accent.withAlphaComponent(0.22))
        }
    }

    /// Color slots used by the painter (index = slot).
    var slots: [NSColor] { [text, secondary, tertiary, code, link, math] }
}
