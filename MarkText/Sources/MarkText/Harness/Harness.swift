import AppKit
import Foundation
import WebKit

#if DEBUG

struct HarnessConfig {
    var file: URL
    var out: URL
    var theme: String?
    var mode: ViewMode?
    var size: CGSize?
    var hold: Double = 0
    var scroll: Double = 0
    var quicklook = false
    var find: String?
    var popover = false
    var undoTest = false
    var exportPDF: URL?
    var exportHTML: URL?
    var prefs: [String: String] = [:]
}

/// Tier A/B snapshot harness (DEBUG only). Never activates the app, never makes a window key.
enum Harness {
    static let config: HarnessConfig? = parse(Array(CommandLine.arguments.dropFirst()))
    static var isActive: Bool { config != nil }

    static func parse(_ args: [String]) -> HarnessConfig? {
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func url(_ s: String) -> URL { URL(fileURLWithPath: s, relativeTo: cwd).standardizedFileURL }
        var c = HarnessConfig(file: url(args[i + 1]), out: url(value("--out") ?? "snapshot-out"))
        c.theme = value("--theme")
        c.mode = value("--mode").flatMap(ViewMode.init(rawValue:))
        if let h = value("--hold"), let d = Double(h) { c.hold = d }
        if let h = value("--scroll"), let d = Double(h) { c.scroll = d }
        c.quicklook = args.contains("--quicklook")
        c.find = value("--find")
        c.popover = args.contains("--popover")
        c.undoTest = args.contains("--undo-test")
        c.exportPDF = value("--export-pdf").map(url)
        c.exportHTML = value("--export-html").map(url)
        for (n, a) in args.enumerated() where a == "--pref" && n + 1 < args.count {
            let kv = args[n + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { c.prefs[kv[0]] = kv[1] }
        }
        if let s = value("--size") {
            let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { c.size = CGSize(width: p[0], height: p[1]) }
        }
        return c
    }

    /// Harness overrides go through the volatile argument domain so they never touch the persisted settings.
    static func prepareDefaults() {
        guard let c = config else { return }
        let d = UserDefaults.standard
        var domain = d.volatileDomain(forName: UserDefaults.argumentDomain)
        applyLaunchOverrides(&domain)
        if let t = c.theme { domain[PrefKey.theme] = t }
        if let m = c.mode { domain[PrefKey.defaultMode] = m.rawValue }
        for (k, v) in c.prefs { domain[k] = Double(v) ?? v }
        d.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// Launch behaviour for harness runs only. These go in the volatile argument domain: writing them to the
    /// persistent domain changed the installed app too (same bundle id), and AppKit compares
    /// `NSTreatUnknownArgumentsAsOpen` as a string, so a stored boolean made `finishLaunching` throw.
    static func applyLaunchOverrides(_ domain: inout [String: Any]) {
        domain["NSTreatUnknownArgumentsAsOpen"] = "NO"
        domain["ApplePersistenceIgnoreState"] = "YES"
        for key in ["NSTreatUnknownArgumentsAsOpen", "ApplePersistenceIgnoreState"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    static func log(_ s: String) { FileHandle.standardError.write(Data("[harness] \(s)\n".utf8)) }

    static func run(_ c: HarnessConfig) async {
        if c.quicklook { await QuickLookHarness.run(c) }
        do {
            try FileManager.default.createDirectory(at: c.out, withIntermediateDirectories: true)
            let (doc, _) = try await NSDocumentController.shared.openDocument(withContentsOf: c.file, display: false)
            guard let document = doc as? MarkdownDocument else { log("not a MarkdownDocument"); exit(2) }
            if document.windowControllers.isEmpty { document.makeWindowControllers() }
            guard let window = document.windowControllers.first?.window else { log("no window"); exit(2) }

            // Keep WebKit painting even when the window is covered (private SPI, DEBUG harness only).
            let occlusion = Selector(("_setWindowOcclusionDetectionEnabled:"))
            log("occlusion SPI available: \(document.model.preview.webView.responds(to: occlusion))")
            if document.model.preview.webView.responds(to: occlusion) { _ = document.model.preview.webView.perform(occlusion, with: false as NSNumber) }
            window.orderBack(nil)   // on screen (so WebKit lays out) but behind everything, not key
            try "\(window.windowNumber)".write(to: c.out.appending(path: "window-id.txt"), atomically: true, encoding: .utf8)
            log("window \(window.windowNumber) ordered back; key=\(window.isKeyWindow) active=\(NSApp.isActive); menus=\(NSApp.mainMenu?.items.map(\.title) ?? [])")

            let model = document.model
            let preview = model.preview
            let start = ContinuousClock.now
            while preview.renderedCount == 0 && ContinuousClock.now - start < .seconds(8) { try await Task.sleep(for: .milliseconds(50)) }
            if preview.renderedCount == 0 { log("no `rendered` within 8 s") }
            try await Task.sleep(for: .milliseconds(500))
            if c.scroll > 0, model.mode != .read {
                if let sv = (window.contentView?.firstDescendant() as NSTextView?)?.enclosingScrollView {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: c.scroll / 2)); sv.reflectScrolledClipView(sv.contentView)
                }
            }
            if c.scroll > 0 { _ = await preview.evaluate("window.scrollTo(0, \(c.scroll)); return true"); try await Task.sleep(for: .milliseconds(300)) }

            if let term = c.find {
                model.findText = term
                model.openFind()
                try await Task.sleep(for: .milliseconds(600))
                await model.find(backwards: false)
                log("find '\(term)' noMatch=\(model.findNoMatch)")
            }
            if c.popover {
                model.showAppearance = true
                try await Task.sleep(for: .milliseconds(900))
            }
            if c.undoTest { await undoTest(document, window) }
            if let pdf = c.exportPDF {
                let ok = await document.exportPDF(to: pdf, window: window)
                log("export pdf ok=\(ok) -> \(pdf.path)")
            }
            if let html = c.exportHTML {
                let ok = await document.exportHTML(to: html)
                log("export html ok=\(ok) -> \(html.path)")
            }
            // Other visible windows (popover) so the shell can capture them too.
            let extras = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.frame.width > 40 && $0.frame.height > 40 }
            try extras.map { "\($0.windowNumber)\t\(type(of: $0))\t\($0.frame)" }.joined(separator: "\n")
                .write(to: c.out.appending(path: "extra-windows.txt"), atomically: true, encoding: .utf8)

            var seen = preview.renderedCount
            try await writeArtifacts(preview, to: c.out)
            // Over ssh `screencapture` has no Screen Recording permission; a process may always capture its own windows.
            captureOwnWindow(window, to: c.out.appending(path: "window.png"))
            for (n, extra) in extras.enumerated() { captureOwnWindow(extra, to: c.out.appending(path: "extra-\(n + 1).png"), withWindowsBelow: true) }
            log("artifacts written to \(c.out.path)")

            // Hold mode: stay alive; re-write artifacts after every re-render (live reload test).
            let holdEnd = ContinuousClock.now + .seconds(c.hold)
            while ContinuousClock.now < holdEnd {
                try await Task.sleep(for: .milliseconds(100))
                if preview.renderedCount != seen {
                    seen = preview.renderedCount
                    try await Task.sleep(for: .milliseconds(300))
                    try await writeArtifacts(preview, to: c.out)
                    log("re-rendered (#\(seen)), artifacts rewritten")
                }
            }
            exit(0)
        } catch {
            log("failed: \(error)")
            exit(1)
        }
    }

    /// `CGWindowListCreateImage` is unavailable to Swift in this SDK but still exported; DEBUG harness only.
    static func captureOwnWindow(_ window: NSWindow, to url: URL, withWindowsBelow: Bool = false) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { log("no CGWindowListCreateImage"); return }
        let create = unsafeBitCast(sym, to: Fn.self)
        // .null rect, optionIncludingWindow (1 << 3), boundsIgnoreFraming (1 << 0) | bestResolution (1 << 3)
        // (a popover is glass: captured alone it has nothing to sample, so it is captured over the windows below it)
        guard let image = create(.null, withWindowsBelow ? (1 << 3) | (1 << 2) : 1 << 3, UInt32(window.windowNumber), 1 | (1 << 3))?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { log("self-capture failed"); return }
        try? png.write(to: url)
    }

    /// Types into the real editor, then checks the dirty flag and document-level undo/redo.
    @MainActor
    static func undoTest(_ document: MarkdownDocument, _ window: NSWindow) async {
        func findTextView(_ v: NSView) -> NSTextView? {
            if let t = v as? NSTextView { return t }
            for s in v.subviews { if let t = findTextView(s) { return t } }
            return nil
        }
        guard let tv = window.contentView.flatMap(findTextView) else { log("undo-test: no text view (use --mode split)"); return }
        let original = document.model.text
        log("undo-test: edited before=\(document.isDocumentEdited) undoManagerSame=\(tv.undoManager === document.undoManager)")
        window.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        for ch in "TYPED " {
            let s = String(ch)
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0) {
                window.sendEvent(ev)   // first responder gets it, like a keystroke
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(300))
        log("undo-test: after typing edited=\(document.isDocumentEdited) modelHasText=\(document.model.text.hasPrefix("TYPED ")) canUndo=\(document.undoManager?.canUndo ?? false)")
        document.undoManager?.endUndoGrouping()   // what the event loop does at the end of a real keystroke
        try? await Task.sleep(for: .milliseconds(200))
        log("undo-test: after group close edited=\(document.isDocumentEdited)")
        log("undo-test: level=\(document.undoManager?.groupingLevel ?? -1) tvHas=\(tv.string.hasPrefix("TYPED ")) changeCountEdited=\(document.isDocumentEdited)")
        var didChangeCount = 0
        let obs = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: tv, queue: .main) { _ in didChangeCount += 1 }
        document.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(300))
        NotificationCenter.default.removeObserver(obs)
        log("undo-test: didChange notifications during undo=\(didChangeCount)")
        log("undo-test: tvAfterUndo=\(tv.string.hasPrefix("TYPED ")) modelAfterUndo=\(document.model.text.hasPrefix("TYPED "))")
        log("undo-test: after undo edited=\(document.isDocumentEdited) restored=\(document.model.text == original)")
        document.undoManager?.redo()
        try? await Task.sleep(for: .milliseconds(200))
        log("undo-test: after redo hasText=\(document.model.text.hasPrefix("TYPED "))")
        document.undoManager?.undo()
        try? await Task.sleep(for: .milliseconds(200))
    }

    @MainActor
    static func writeArtifacts(_ preview: PreviewController, to out: URL) async throws {
        let js = """
        return {
          katex: document.querySelectorAll('.katex').length,
          mermaidSvg: document.querySelectorAll('.mermaid svg').length,
          hljs: document.querySelectorAll('pre code.hljs').length,
          title: document.title,
          errors: window.__mtErrors || [],
          text: (document.getElementById('mt-root') || document.body).innerText.slice(0, 4000),
          scrollHeight: document.documentElement.scrollHeight
        };
        """
        var dom = (await preview.evaluate(js) as? [String: Any]) ?? [:]
        dom["renderedCount"] = preview.renderedCount
        dom["bridgeErrors"] = preview.lastErrors
        try JSONSerialization.data(withJSONObject: dom, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "dom.json"))
        // Edit mode detaches the web view, in which case there is nothing to snapshot.
        if preview.webView.window != nil, let image = try? await preview.webView.takeSnapshot(configuration: WKSnapshotConfiguration()),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: out.appending(path: "webview.png"))
        }
        try "done".write(to: out.appending(path: "tier-a-done.txt"), atomically: true, encoding: .utf8)
    }
}

#else

struct HarnessConfig {
    var size: CGSize?
    var mode: ViewMode?
}

enum Harness {
    static var config: HarnessConfig? { nil }
    static var isActive: Bool { false }
    static func prepareDefaults() {}
    static func log(_ s: String) {}
    static func run(_ c: HarnessConfig) async {}
}

#endif
