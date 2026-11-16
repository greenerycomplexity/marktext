#if DEBUG
import AppKit

/// Debug-only offscreen rendering of the editor, for visual verification without a UI test.
@MainActor
enum EditorHarness {
    private final class BackgroundView: NSView {
        var fill: NSColor = .windowBackgroundColor
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                fill.setFill()
                bounds.fill()
            }
            super.draw(dirtyRect)
        }
    }

    /// Builds the editor in an offscreen window (never ordered front or key) and returns a bitmap.
    static func renderSnapshot(text: String, style: EditorStyle, size: CGSize) -> NSImage? {
        _ = NSApplication.shared
        let controller = EditorController(text: text, style: style)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = switch style.theme {
        case .auto: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light, .sepia: NSAppearance(named: .aqua)
        }
        let bg = BackgroundView(frame: NSRect(origin: .zero, size: size))
        bg.fill = style.theme == .sepia ? NSColor(srgbRed: 0xF6 / 255, green: 0xF0 / 255, blue: 0xE4 / 255, alpha: 1) : .windowBackgroundColor
        window.contentView = bg
        controller.scrollView.frame = bg.bounds
        controller.scrollView.autoresizingMask = [.width, .height]
        bg.addSubview(controller.scrollView)
        bg.layoutSubtreeIfNeeded()
        controller.scrollView.layoutSubtreeIfNeeded()
        if let tlm = controller.textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: -style.topInset))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        bg.layoutSubtreeIfNeeded()
        bg.displayIfNeeded()
        guard let rep = bg.bitmapImageRepForCachingDisplay(in: bg.bounds) else { return nil }
        bg.cacheDisplay(in: bg.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        withExtendedLifetime(controller) {}
        return image
    }

    static func writePNG(_ image: NSImage, to path: String) -> Bool {
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// `--editor-snapshot <md> --out <png> [--theme auto|light|dark|sepia] [--size WxH] [--font N] [--top N]`.
    /// Writes the PNG and exits the process. Returns false when the flag is absent.
    @discardableResult
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--editor-snapshot"), i + 1 < args.count else { return false }
        func value(_ flag: String) -> String? {
            guard let k = args.firstIndex(of: flag), k + 1 < args.count else { return nil }
            return args[k + 1]
        }
        guard let out = value("--out") else { fputs("--out required\n", stderr); exit(2) }
        guard let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else { fputs("cannot read \(args[i + 1])\n", stderr); exit(2) }
        var style = EditorStyle()
        if let t = value("--theme"), let theme = EditorTheme(rawValue: t) { style.theme = theme }
        if let f = value("--font"), let v = Double(f) { style.fontSize = v }
        if let t = value("--top"), let v = Double(t) { style.topInset = v }
        var size = CGSize(width: 960, height: 1100)
        if let s = value("--size") {
            let p = s.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { size = CGSize(width: p[0], height: p[1]) }
        }
        guard let image = renderSnapshot(text: text, style: style, size: size), writePNG(image, to: out) else {
            fputs("snapshot failed\n", stderr); exit(1)
        }
        exit(0)
    }
}
#endif
