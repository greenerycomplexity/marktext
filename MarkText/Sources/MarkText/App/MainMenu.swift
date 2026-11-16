import AppKit

/// The whole menu bar, built in AppKit so per-document actions resolve through the responder chain
/// (key window -> window controller -> document).
@MainActor
enum MainMenu {
    private(set) static var installed: NSMenu?

    /// SwiftUI owns `NSApp.mainMenu` and can swap it for its own; re-assert ours whenever that happens.
    static func installIfNeeded() { if installed == nil || NSApp.mainMenu !== installed { install() } }

    static func install() {
        let main = NSMenu()
        main.addItem(submenu("MarkText", appMenu()))
        main.addItem(submenu("File", fileMenu()))
        main.addItem(submenu("Edit", editMenu()))
        main.addItem(submenu("View", viewMenu()))
        let window = windowMenu()
        main.addItem(submenu("Window", window))
        NSApp.mainMenu = main
        installed = main
        NSApp.windowsMenu = window
    }

    private static func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        item.tag = tag
        return item
    }

    private static func appMenu() -> NSMenu {
        let m = NSMenu()
        add(m, "About MarkText", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        m.addItem(.separator())
        add(m, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        m.addItem(.separator())
        let services = NSMenu(title: "Services")
        m.addItem(submenu("Services", services)); NSApp.servicesMenu = services
        m.addItem(.separator())
        add(m, "Hide MarkText", #selector(NSApplication.hide(_:)), "h")
        add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        m.addItem(.separator())
        add(m, "Quit MarkText", #selector(AppDelegate.quit(_:)), "q")
        return m
    }

    private static func fileMenu() -> NSMenu {
        let m = NSMenu()
        add(m, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        add(m, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        let recent = NSMenu(title: "Open Recent")
        add(recent, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
        m.addItem(submenu("Open Recent", recent))
        m.addItem(.separator())
        add(m, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(m, "Save…", #selector(NSDocument.save(_:)), "s")
        add(m, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        m.addItem(.separator())
        add(m, "Export as PDF…", #selector(DocumentWindowController.exportPDF(_:)), "p", [.command, .option])
        add(m, "Export as HTML…", #selector(DocumentWindowController.exportHTML(_:)))
        m.addItem(.separator())
        add(m, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
        add(m, "Print…", #selector(NSDocument.printDocument(_:)), "p")
        return m
    }

    private static func editMenu() -> NSMenu {
        let m = NSMenu()
        add(m, "Undo", Selector(("undo:")), "z")
        add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
        m.addItem(.separator())
        add(m, "Cut", #selector(NSText.cut(_:)), "x")
        add(m, "Copy", #selector(NSText.copy(_:)), "c")
        add(m, "Paste", #selector(NSText.paste(_:)), "v")
        add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
        m.addItem(.separator())
        let find = NSMenu(title: "Find")
        add(find, "Find…", #selector(DocumentWindowController.mtShowFind(_:)), "f")
        add(find, "Find Next", #selector(DocumentWindowController.mtFindNext(_:)), "g")
        add(find, "Find Previous", #selector(DocumentWindowController.mtFindPrevious(_:)), "g", [.command, .shift])
        m.addItem(submenu("Find", find))
        return m
    }

    private static func viewMenu() -> NSMenu {
        let m = NSMenu()
        let sel = #selector(DocumentWindowController.selectMode(_:))
        add(m, "Read", sel, "1", tag: 0)
        add(m, "Split", sel, "2", tag: 1)
        add(m, "Edit", sel, "3", tag: 2)
        m.addItem(.separator())
        add(m, "Toggle Read / Split", #selector(DocumentWindowController.toggleReadSplit(_:)), "e")
        add(m, "Edit Only", #selector(DocumentWindowController.editOnly(_:)), "e", [.command, .option])
        m.addItem(.separator())
        add(m, "Bigger Text", #selector(AppDelegate.increaseTextSize(_:)), "+")
        add(m, "Smaller Text", #selector(AppDelegate.decreaseTextSize(_:)), "-")
        add(m, "Actual Size", #selector(AppDelegate.resetTextSize(_:)), "0")
        m.addItem(.separator())
        add(m, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        // "Enter Full Screen" is added to View by AppKit itself; adding our own produced a duplicate.
        return m
    }

    private static func windowMenu() -> NSMenu {
        let m = NSMenu()
        add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
        m.addItem(.separator())
        add(m, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return m
    }
}
