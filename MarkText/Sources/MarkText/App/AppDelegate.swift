import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Harness.isActive || UIScript.isActive { NSApp.setActivationPolicy(.accessory) }
        #if DEBUG
        EditorHarness.runIfRequested()
        #endif
        _ = NSDocumentController.shared   // make sure the document machinery exists before open events
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        PreviewController.prepareSpare(after: 0)
        if let script = UIScript.config {
            Task { await UIScript.run(script) }
            return
        }
        if let config = Harness.config {
            Task { await Harness.run(config) }
            return
        }
        // No document opened by Finder / `open`: show the Open panel instead of an untitled document.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if NSDocumentController.shared.documents.isEmpty { NSDocumentController.shared.openDocument(nil) }
        }
    }

    // The harness must never resurrect windows from a previous run (that would activate the app).
    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool { !Harness.isActive }
    func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool { !Harness.isActive }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Dock click with no windows: show the Open panel (there is no untitled document).
    func applicationDidBecomeActive(_ notification: Notification) { MainMenu.installIfNeeded() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    /// ⌘Q: AppKit shows a bare Save panel for each edited untitled document. Ask the standard question
    /// (Save… / Cancel / Don't Save) for those first; file-backed documents autosave and AppKit handles them.
    /// (SwiftUI's delegate adaptor does not forward `applicationShouldTerminate`, so the Quit menu item calls this.)
    @objc func quit(_ sender: Any?) {
        let dirty = NSDocumentController.shared.documents.compactMap { $0 as? MarkdownDocument }.filter(\.needsSavePrompt)
        guard !dirty.isEmpty else { NSApp.terminate(sender); return }
        Task { @MainActor in
            for doc in dirty {
                guard let wc = doc.windowControllers.first as? DocumentWindowController else { continue }
                if !UIScript.isActive && !Harness.isActive { wc.window?.makeKeyAndOrderFront(nil) }
                let decision = await withCheckedContinuation { c in wc.askToSaveUntitled(doc) { c.resume(returning: $0) } }
                if decision == .cancelled { return }
                if decision == .discarded { doc.close() }   // also removes its autosaved draft
            }
            NSApp.terminate(sender)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    @objc func increaseTextSize(_ sender: Any?) { PrefKey.adjustSize(by: 1) }
    @objc func decreaseTextSize(_ sender: Any?) { PrefKey.adjustSize(by: -1) }
    @objc func resetTextSize(_ sender: Any?) { PrefKey.adjustSize(by: nil) }
}
