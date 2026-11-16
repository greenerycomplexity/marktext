import MarkTextKit
import SwiftUI

struct DocumentView: View {
    @Bindable var model: DocumentModel
    @AppStorage(PrefKey.outline) private var outlinePref = OutlineVisibility.automatic.rawValue
    @AppStorage(PrefKey.sidebarChoice) private var sidebarChoice = ""
    @State private var columns: NavigationSplitViewVisibility = .detailOnly
    @State private var expectedColumns: NavigationSplitViewVisibility = .detailOnly
    @State private var autoDecided = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            OutlineSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            content
        }
        .onChange(of: model.headings.count, initial: true) { decideSidebar() }
        .onChange(of: outlinePref) { autoDecided = false; decideSidebar() }
        .onChange(of: columns) {
            // A change we didn't make is the user's own toggle: remember it.
            guard columns != expectedColumns else { return }
            expectedColumns = columns
            sidebarChoice = columns == .detailOnly ? "hidden" : "shown"
        }
    }

    private func decideSidebar() {
        let visibility = OutlineVisibility(rawValue: outlinePref) ?? .automatic
        let count = model.headings.count
        let show: Bool
        switch visibility {
        case .never: show = false
        case .always: show = true
        case .automatic:
            if sidebarChoice == "shown" { show = true } else if sidebarChoice == "hidden" { show = false }
            else {
                guard count > 0 || autoDecided else { return }   // headings arrive after the async render
                guard !autoDecided else { return }
                show = count >= 3
            }
        }
        autoDecided = true
        let target: NavigationSplitViewVisibility = show ? .all : .detailOnly
        if target != columns { expectedColumns = target; columns = target }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .read: preview
        case .edit: EditorContainer(model: model) { model.setEditorScrolled($0 > 1) }
        case .split:
            HSplitView {
                EditorContainer(model: model) { line in model.setEditorScrolled(line > 1); model.preview.scrollToLine(line) }
                    .frame(minWidth: 200)
                preview.frame(minWidth: 200)
            }
        }
    }

    private var preview: some View {
        PreviewView(controller: model.preview)
            .ignoresSafeArea(.container, edges: .top)
            .overlay(alignment: .top) { ScrollEdgeFade(visible: model.previewScrolled) }
            .overlay {
                if model.isEmpty {
                    ContentUnavailableView("Empty Document", systemImage: "doc.text", description: Text("Press ⌘E to start writing."))
                }
            }
            .overlay(alignment: .topTrailing) {
                if model.findVisible { FindBar(model: model).padding(12) }
            }
    }
}
