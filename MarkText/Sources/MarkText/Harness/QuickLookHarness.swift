#if DEBUG
import AppKit
import Quartz

/// `MarkText --snapshot <file.md> --out <dir> --quicklook --hold N`: shows the file in a QLPreviewView
/// (the same extension-selection path Finder uses) inside an ordered-back window, so the shell can
/// screencapture it. Proves the Quick Look preview extension is picked and renders, headlessly.
enum QuickLookHarness {
    static func run(_ c: HarnessConfig) async {
        try? FileManager.default.createDirectory(at: c.out, withIntermediateDirectories: true)
        let size = c.size ?? CGSize(width: 900, height: 700)
        let window = DocumentWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let preview = QLPreviewView(frame: NSRect(origin: .zero, size: size), style: .normal)!
        preview.previewItem = c.file as NSURL
        window.contentView = preview
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        try? "\(window.windowNumber)".write(to: c.out.appending(path: "window-id.txt"), atomically: true, encoding: .utf8)
        Harness.log("quicklook window \(window.windowNumber)")
        try? await Task.sleep(for: .seconds(max(c.hold, 3)))
        exit(0)
    }
}

#endif
