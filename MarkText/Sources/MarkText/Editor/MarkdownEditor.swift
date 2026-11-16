import AppKit
import SwiftUI

/// Source editor: TextKit 2 `NSTextView` with Markdown syntax highlighting.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var style: EditorStyle
    var scrollRequest: EditorScrollRequest?
    var onTopLineChange: (Int) -> Void
    var focusOnAppear: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = EditorController(text: text, style: style)
        context.coordinator.controller = controller
        context.coordinator.lastText = text
        wire(controller, context.coordinator)
        if focusOnAppear { controller.focusWhenAttached() }
        if let r = scrollRequest { DispatchQueue.main.async { controller.scroll(to: r) } }
        return controller.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let controller = c.controller else { return }
        wire(controller, c)
        controller.apply(style: style)
        if text != c.lastText {
            // External change (reload from disk, revert): the editor's own edits already set lastText.
            c.lastText = text
            if controller.textView.string != text { controller.setExternalText(text) }
        }
        if let r = scrollRequest { controller.scroll(to: r) }
    }

    private func wire(_ controller: EditorController, _ c: Coordinator) {
        c.binding = $text
        c.topLine = onTopLineChange
        controller.onTextChange = { [weak c] new in
            guard let c else { return }
            c.lastText = new
            c.binding?.wrappedValue = new
        }
        controller.onTopLineChange = { [weak c] line in c?.topLine?(line) }
    }

    @MainActor
    final class Coordinator {
        var controller: EditorController?
        var binding: Binding<String>?
        var topLine: ((Int) -> Void)?
        var lastText = ""
    }
}
