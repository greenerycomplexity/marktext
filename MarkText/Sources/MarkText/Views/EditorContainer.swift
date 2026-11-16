import SwiftUI

/// Seam between the document UI and the editor implementation in Editor/.
struct EditorContainer: View {
    @Bindable var model: DocumentModel
    var onTopLineChange: (Int) -> Void
    @AppStorage(PrefKey.theme) private var theme = Theme.auto.rawValue
    @AppStorage(PrefKey.fontSize) private var size = 16.0

    var body: some View {
        let _ = model.textRevision   // refresh the editor when the text is replaced from disk
        // The proxy sits inside the safe area, so it reports the toolbar height; the editor itself runs under it
        // and applies that height as its scroll-view content inset.
        GeometryReader { proxy in
            MarkdownEditor(
                text: Binding(get: { model.text }, set: { model.text = $0 }),
                style: EditorStyle(fontSize: size, theme: EditorTheme(rawValue: theme) ?? .auto, topInset: proxy.safeAreaInsets.top),
                scrollRequest: nil,
                onTopLineChange: onTopLineChange,
                focusOnAppear: model.mode == .edit || model.isEmpty)
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .top) { ScrollEdgeFade(visible: model.editorScrolled) }
                .background { SpellcheckBinder() }
        }
    }
}
