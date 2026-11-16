import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Window that never becomes key/main when running under the snapshot harness.
final class DocumentWindow: NSWindow {
    /// Returns true when it handled the close itself (e.g. by presenting a save sheet).
    var closeInterceptor: (() -> Bool)?
    override func performClose(_ sender: Any?) {
        if closeInterceptor?() == true { return }
        super.performClose(sender)
    }

    override var canBecomeKey: Bool { (UIScript.isActive || !Harness.isActive) && super.canBecomeKey }
    override var canBecomeMain: Bool { (UIScript.isActive || !Harness.isActive) && super.canBecomeMain }
}

final class DocumentWindowController: NSWindowController, NSMenuItemValidation {
    let model: DocumentModel
    // Toolbar state (see DocumentToolbar.swift).
    var modeButtons: [Int: NSButton] = [:]
    var findButton: NSButton?
    var appearanceItem: NSToolbarItem?
    var appearancePopover: NSPopover?
    var appearanceClosedAt: Date?
    private static let frameName = "MarkTextDocument"
    private static var cascadePoint = NSPoint.zero
    private var defaultsObserver: NSObjectProtocol?
    private var frameObservers: [NSObjectProtocol] = []
    private var undoObservers: [NSObjectProtocol] = []

    init(document: MarkdownDocument) {
        var t = CFAbsoluteTimeGetCurrent()
        func lap(_ label: String) { let n = CFAbsoluteTimeGetCurrent(); Harness.log("window init: \(label) \(Int((n - t) * 1000)) ms"); t = n }
        model = document.model
        let host = NSHostingController(rootView: DocumentView(model: document.model))
        lap("NSHostingController")
        // No scene bridging: the toolbar is a native NSToolbar and the subtitle is set from AppKit. Bridged
        // toolbars and titles were the largest part of the time to open a window.
        host.sceneBridgingOptions = []
        // The window owns its size (frame autosave, contentMinSize below). Left on, the hosting controller measures
        // the whole SwiftUI tree for min/ideal sizes on every open and resizes the window to fit it.
        host.sizingOptions = []
        #if DEBUG
        if CommandLine.arguments.contains("--legacy-sizing") { host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize] }   // A/B measurements
        #endif
        lap("sceneBridgingOptions")
        let size = Harness.config?.size ?? CGSize(width: 1100, height: 800)
        let window = DocumentWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        lap("NSWindow")
        // Configure the (still empty) window first: changing these after the SwiftUI content is attached forced
        // a second synchronous layout/toolbar rebuild of the whole hierarchy (150-350 ms).
        window.contentMinSize = NSSize(width: 560, height: 420)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        lap("window config")
        window.isReleasedWhenClosed = false
        window.isRestorable = !Harness.isActive
        super.init(window: window)
        installToolbar(on: window)
        lap("toolbar")
        host.view.frame = NSRect(origin: .zero, size: size)
        window.contentViewController = host
        lap("contentViewController")
        shouldCascadeWindows = true
        window.closeInterceptor = { [weak self] in self?.interceptClose() ?? false }
        if Harness.isActive { window.center() } else { restoreAndCascade(window) }
        lap("frame restore")
        applyPrefs()
        trackSubtitle()
        trackToolbarState()
        lap("applyPrefs")
        observeUndo(document.undoManager)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        }
    }

    /// Restores the saved frame (centering only when there is none, i.e. the first ever launch), cascades
    /// later windows, and saves the frame whenever the window moves or resizes.
    private func restoreAndCascade(_ window: NSWindow) {
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { window.saveFrame(usingName: Self.frameName) }
            })
        }
    }

    /// The editor's text view does not post `didChange` for undo/redo, so the model is re-synced from the
    /// text view after every undo or redo on the document's undo manager (otherwise saves would write stale text).
    private func observeUndo(_ manager: UndoManager?) {
        guard let manager else { return }
        for name in [Foundation.NSNotification.Name.NSUndoManagerDidUndoChange, Foundation.NSNotification.Name.NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncModelFromEditor() }
            })
        }
    }

    private func syncModelFromEditor() {
        guard let tv: NSTextView = window?.contentView?.firstDescendant(), tv.string != model.text else { return }
        model.text = tv.string
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        undoObservers.forEach { NotificationCenter.default.removeObserver($0) }
        frameObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Theme drives the window appearance and background; the web view stays transparent on top.
    /// Word count / reading time under the title (`NSWindow.subtitle`), kept in sync with the model.
    private func trackSubtitle() {
        window?.subtitle = model.subtitle
        withObservationTracking { _ = model.subtitle } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackSubtitle() } }
        }
    }

    private var lastPrefsKey: String?

    private func applyPrefs() {
        // UserDefaults posts a notification for *any* write (AppKit frame saves, spelling...): only react to ours.
        let d = UserDefaults.standard
        let key = "\(d.string(forKey: PrefKey.theme) ?? "")|\(d.string(forKey: PrefKey.typeface) ?? "")|\(d.double(forKey: PrefKey.fontSize))|\(d.string(forKey: PrefKey.width) ?? "")|\(d.bool(forKey: PrefKey.showFrontMatter))"
        guard key != lastPrefsKey else { return }
        lastPrefsKey = key
        let theme = PrefKey.currentTheme
        window?.appearance = theme.appearance
        window?.backgroundColor = theme == .sepia ? .sepiaPaper : .windowBackgroundColor
        model.preview.applyPrefs()
    }

    // MARK: Closing

    enum SaveDecision { case saved, discarded, cancelled }
    private var pendingSave: ((SaveDecision) -> Void)?

    /// ⌘W and the close button both end in `performClose`. For an edited untitled document AppKit goes straight
    /// to a Save panel (with no "Don't Save"), so ask the standard question first. Everything else takes AppKit's path.
    private func interceptClose() -> Bool {
        guard let doc = document as? MarkdownDocument, doc.needsSavePrompt else { return false }
        askToSaveUntitled(doc) { [weak doc] decision in if decision != .cancelled { doc?.close() } }
        return true
    }

    /// Standard "Do you want to save the changes…?" sheet for an edited untitled document. Also used by ⌘Q.
    func askToSaveUntitled(_ doc: MarkdownDocument, completion: @escaping (SaveDecision) -> Void) {
        guard let window else { completion(.cancelled); return }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to the document “\(doc.displayName ?? "Untitled")”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { [weak self, weak doc] response in
            MainActor.assumeIsolated {
                guard let self, let doc else { completion(.cancelled); return }
                switch response {
                case .alertFirstButtonReturn:
                    self.pendingSave = completion
                    doc.save(withDelegate: self, didSave: #selector(self.document(_:didSave:contextInfo:)), contextInfo: nil)
                case .alertThirdButtonReturn: completion(.discarded)
                default: completion(.cancelled)
                }
            }
        }
    }

    @objc func document(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let done = pendingSave; pendingSave = nil
        done?(didSave ? .saved : .cancelled)
    }

    // MARK: Menu actions

    @objc func selectMode(_ sender: NSMenuItem) { model.mode = ViewMode.allCases[sender.tag] }
    @objc func toggleReadSplit(_ sender: Any?) { model.mode = model.mode == .read ? .split : .read }
    @objc func editOnly(_ sender: Any?) { model.mode = .edit }

    @objc func mtShowFind(_ sender: Any?) {
        if model.mode == .edit { forwardToTextFinder(.showFindInterface) } else { model.openFind() }
    }
    @objc func mtFindNext(_ sender: Any?) {
        if model.mode == .edit { forwardToTextFinder(.nextMatch) } else { Task { await model.find(backwards: false) } }
    }
    @objc func mtFindPrevious(_ sender: Any?) {
        if model.mode == .edit { forwardToTextFinder(.previousMatch) } else { Task { await model.find(backwards: true) } }
    }

    private func forwardToTextFinder(_ action: NSTextFinder.Action) {
        let item = NSMenuItem(); item.tag = action.rawValue
        (window?.firstResponder as? NSTextView)?.performTextFinderAction(item)
    }

    @objc func exportPDF(_ sender: Any?) { exportViaPanel(type: .pdf, ext: "pdf") { [self] url in await model.document?.exportPDF(to: url, window: window) ?? false } }
    @objc func exportHTML(_ sender: Any?) { exportViaPanel(type: .html, ext: "html") { [self] url in await model.document?.exportHTML(to: url) ?? false } }

    private func exportViaPanel(type: UTType, ext: String, _ work: @escaping @MainActor (URL) async -> Bool) {
        guard let window, let doc = model.document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = doc.fileURL?.deletingPathExtension().lastPathComponent.appending(".\(ext)") ?? "Untitled.\(ext)"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in _ = await work(url) }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectMode(_:)): item.state = model.mode == ViewMode.allCases[item.tag] ? .on : .off
        case #selector(editOnly(_:)): item.state = model.mode == .edit ? .on : .off
        default: break
        }
        return true
    }
}
