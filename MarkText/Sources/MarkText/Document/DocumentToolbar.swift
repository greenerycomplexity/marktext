import AppKit
import SwiftUI

extension NSToolbarItem.Identifier {
    static let mtRead = NSToolbarItem.Identifier("mt.read")
    static let mtSplit = NSToolbarItem.Identifier("mt.split")
    static let mtEdit = NSToolbarItem.Identifier("mt.edit")
    static let mtFind = NSToolbarItem.Identifier("mt.find")
    static let mtAppearance = NSToolbarItem.Identifier("mt.appearance")
    static let mtShare = NSToolbarItem.Identifier("mt.share")
}

/// The window toolbar, built natively. SwiftUI's bridged `.toolbar` hosted every item in its own hosting view
/// and dominated the time to open a window (measured: more than half of a 0.6-1.3 s main-thread stall).
/// Native items get the system glass capsules; items separated by a space sit in separate capsules.
extension DocumentWindowController: NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSPopoverDelegate {
    private static let modes: [(mode: ViewMode, title: String, symbol: String, key: String)] = [
        (.read, "Read", "book", "1"), (.split, "Split", "rectangle.split.2x1", "2"), (.edit, "Edit", "pencil.line", "3"),
    ]

    private static let modeIdentifiers: [NSToolbarItem.Identifier] = [.mtRead, .mtSplit, .mtEdit]

    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "MarkTextDocument")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    private var hasShareItem: Bool { model.document?.fileURL != nil }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The leading flexible space keeps the sidebar button at the sidebar's trailing edge.
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .mtRead, .mtSplit, .mtEdit, .space, .mtFind, .mtAppearance]
            + (hasShareItem ? [.space, .mtShare] : [])
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space, .mtRead, .mtSplit, .mtEdit, .mtFind, .mtAppearance, .mtShare]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .mtRead, .mtSplit, .mtEdit:
            // Three toggle buttons rather than a segmented group: the system draws separators between
            // unselected segments only, which looked inconsistent. Adjacent items share one glass capsule.
            guard let index = Self.modeIdentifiers.firstIndex(of: id) else { return nil }
            let mode = Self.modes[index]
            let item = NSToolbarItem(itemIdentifier: id)
            let image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title) ?? NSImage()
            let toggle = NSButton(image: image, target: self, action: #selector(toolbarSelectMode(_:)))
            toggle.bezelStyle = .toolbar
            toggle.setButtonType(.pushOnPushOff)
            toggle.tag = index
            toggle.state = model.mode == mode.mode ? .on : .off
            item.view = toggle
            item.label = mode.title
            item.toolTip = "\(mode.title) (⌘\(mode.key))"
            // In the overflow menu (narrow window) the item is a menu command with a checkmark.
            let menuItem = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            item.menuFormRepresentation = menuItem
            modeButtons[index] = toggle
            return item
        case .mtFind:
            let item = NSToolbarItem(itemIdentifier: id)
            let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find") ?? NSImage()
            let find = NSButton(image: image, target: self, action: #selector(mtShowFind(_:)))
            find.bezelStyle = .toolbar
            item.view = find
            item.label = "Find"
            item.toolTip = "Find (⌘F)"
            let menuItem = NSMenuItem(title: "Find", action: #selector(mtShowFind(_:)), keyEquivalent: "")
            menuItem.target = self
            item.menuFormRepresentation = menuItem
            findButton = find
            setFindAvailable(model.mode != .edit)
            return item
        case .mtAppearance:
            let item = button(id, "Appearance", "textformat.size", "Appearance", #selector(toggleAppearance(_:)))
            appearanceItem = item
            return item
        case .mtShare:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.label = "Share"
            item.toolTip = "Share"
            item.delegate = self
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ tip: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        model.document?.fileURL.map { [$0] } ?? []
    }

    /// Share appears once the document has a file (after the first save) and goes away if it loses it.
    func updateShareItem() {
        guard let toolbar = window?.toolbar else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .mtShare }
        if hasShareItem, index == nil {
            toolbar.insertItem(withItemIdentifier: .space, at: toolbar.items.count)
            toolbar.insertItem(withItemIdentifier: .mtShare, at: toolbar.items.count)
        } else if !hasShareItem, let index {
            toolbar.removeItem(at: index)
            if index > 0, toolbar.items[index - 1].itemIdentifier == .space { toolbar.removeItem(at: index - 1) }
        }
    }

    /// Keeps the mode control, the Find button and the Appearance popover in step with the model
    /// (menu commands and shortcuts change the same state).
    func trackToolbarState() {
        let (mode, showAppearance) = withObservationTracking { (model.mode, model.showAppearance) } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackToolbarState() } }
        }
        for (index, toggle) in modeButtons { toggle.state = Self.modes[index].mode == mode ? .on : .off }
        setFindAvailable(mode != .edit)
        if showAppearance != (appearancePopover?.isShown ?? false) {
            if showAppearance { presentAppearancePopover() } else { appearancePopover?.close() }
        }
    }

    /// Find is unavailable in Edit mode (the editor has its own find bar under ⌘F).
    private func setFindAvailable(_ available: Bool) {
        findButton?.isEnabled = available
    }

    @objc func toolbarSelectMode(_ sender: NSButton) {
        guard Self.modes.indices.contains(sender.tag) else { return }
        sender.state = .on   // clicking the selected mode must not switch it off
        model.mode = Self.modes[sender.tag].mode
    }

    @objc func toggleAppearance(_ sender: Any?) {
        // The click that lands on the button while the popover is open has already dismissed it (transient):
        // do not open it again.
        if let closed = appearanceClosedAt, Date().timeIntervalSince(closed) < 0.3 { return }
        model.showAppearance.toggle()
    }

    private func presentAppearancePopover() {
        guard let appearanceItem else { model.showAppearance = false; return }
        let popover = NSPopover()
        let content = NSHostingController(rootView: AppearancePopover())
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.behavior = .transient
        popover.delegate = self
        appearancePopover = popover
        popover.show(relativeTo: appearanceItem)
    }

    func popoverDidClose(_ notification: Notification) {
        appearancePopover = nil
        appearanceClosedAt = Date()
        if model.showAppearance { model.showAppearance = false }
    }
}
