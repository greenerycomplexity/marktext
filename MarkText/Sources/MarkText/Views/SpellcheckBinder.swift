import SwiftUI

/// Applies the persisted continuous-spellcheck choice (default off) to the editor's text view and
/// writes the user's toggles from Edit > Spelling back to the preference.
struct SpellcheckBinder: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var textView: NSTextView?
        private var observation: NSKeyValueObservation?

        func attach(from view: NSView) {
            guard let root = view.window?.contentView, let tv: NSTextView = root.firstDescendant(), tv !== textView else { return }
            textView = tv
            tv.isContinuousSpellCheckingEnabled = UserDefaults.standard.bool(forKey: PrefKey.spellcheck)
            let key = PrefKey.spellcheck   // read on the main actor; the observer closure is Sendable
            observation = tv.observe(\.isContinuousSpellCheckingEnabled, options: [.new]) { _, change in
                guard let on = change.newValue else { return }
                UserDefaults.standard.set(on, forKey: key)
            }
        }
    }
}
