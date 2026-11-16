import SwiftUI

struct FindBar: View {
    @Bindable var model: DocumentModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: $model.findText)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .foregroundStyle(model.findNoMatch ? Color.red : Color.primary)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    Task { await model.find(backwards: press.modifiers.contains(.shift)) }
                    return .handled
                }
                .onExitCommand { model.closeFind() }
                .onChange(of: model.findText) { Task { await model.find(backwards: false) } }
            Button("Previous Match", systemImage: "chevron.up") { Task { await model.find(backwards: true) } }
            Button("Next Match", systemImage: "chevron.down") { Task { await model.find(backwards: false) } }
            Button("Close", systemImage: "xmark") { model.closeFind() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .onAppear { focused = true }
        .onChange(of: model.findFocusToken) { focused = true }
    }
}
