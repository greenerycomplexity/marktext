import AppKit
import SwiftUI

/// Own settings window. SwiftUI refuses `showSettingsWindow:` sent from AppKit menus
/// ("Please use SettingsLink"), so the menu item opens this window instead.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("MarkTextSettings")
        window.setFrameAutosaveName("MarkTextSettings")
        super.init(window: window)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        if !window.isVisible, !window.setFrameUsingName("MarkTextSettings") { window.center() }
        if UIScript.isActive {   // test harness: key within the app, but never activate it or cover other apps
            window.orderBack(nil)
            window.makeKey()
        } else {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
