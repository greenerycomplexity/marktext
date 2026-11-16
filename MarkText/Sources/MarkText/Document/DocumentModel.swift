import AppKit
import MarkTextKit
import Observation

/// State shared between the NSDocument, the window controller and the SwiftUI root view.
@MainActor @Observable
final class DocumentModel {
    /// Source text. Editing it (from the editor binding or a disk reload) schedules a debounced off-main render.
    /// Deliberately not observed: it changes on every keystroke, and observing it re-evaluated the whole
    /// document view (toolbar, outline, editor wrapper) each time. Views depend on `textRevision`, `isEmpty`,
    /// `headings` and `stats` instead.
    @ObservationIgnored var text = "" {
        didSet {
            guard text != oldValue else { return }
            let empty = text.allSatisfy(\.isWhitespace)   // exits at the first visible character
            if empty != isEmpty { isEmpty = empty }
            scheduleRender(debounce: loadingFromDisk ? 0 : 80)
        }
    }
    /// Outline and stats are observed separately and only reassigned when they change, so a render that
    /// leaves them alone does not re-evaluate the outline or the toolbar subtitle.
    private(set) var headings: [Heading] = []
    private(set) var stats = DocumentStats(words: 0, readingMinutes: 0)
    private(set) var isEmpty = true
    /// Bumped when the text is replaced from outside the editor (disk reload), so the editor view refreshes.
    private(set) var textRevision = 0
    var mode: ViewMode = .read
    var activeHeading: String?
    var findVisible = false
    var findText = ""
    var findNoMatch = false
    var findFocusToken = 0
    var showAppearance = false
    var previewScrolled = false
    var editorScrolled = false

    @ObservationIgnored let preview = PreviewController.make()
    @ObservationIgnored weak var document: MarkdownDocument?
    @ObservationIgnored var pendingFragment: String?
    @ObservationIgnored private var loadingFromDisk = false
    @ObservationIgnored private var version = 0
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    init() {
        preview.onActiveHeading = { [weak self] id in self?.activeHeading = id.isEmpty ? nil : id }
        preview.onScroll = { [weak self] f in self?.setPreviewScrolled(f > 0.001) }
        preview.onLink = { [weak self] url in self?.route(url) }
        preview.onRendered = { [weak self] _ in
            guard let self, let frag = self.pendingFragment else { return }
            self.pendingFragment = nil
            self.preview.scrollToHeading(frag)
        }
    }

    var subtitle: String {
        let s = stats
        guard s.words > 0 else { return "" }
        return "\(s.words.formatted()) words · \(max(s.readingMinutes, 1)) min read"
    }

    /// Replace the text from disk (open or external change); renders immediately.
    func load(_ newText: String) {
        loadingFromDisk = true
        defer { loadingFromDisk = false }
        if text == newText { scheduleRender(debounce: 0) } else { text = newText; textRevision += 1 }
    }

    private func scheduleRender(debounce: Int) {
        renderTask?.cancel()
        version += 1
        let v = version
        renderTask = Task { [weak self] in
            if debounce > 0 {
                do { try await Task.sleep(for: .milliseconds(debounce)) } catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            let source = self.text
            let result = await Task.detached(priority: .userInitiated) { MarkdownRenderer.render(source) }.value
            guard v == self.version else { return }   // stale: a newer edit is already queued
            if result.headings != self.headings { self.headings = result.headings }
            if result.stats != self.stats { self.stats = result.stats }
            self.preview.render(result)
        }
    }

    // @Observable setters notify even when the value is unchanged, so scroll-driven flags are guarded.
    func setPreviewScrolled(_ v: Bool) { if previewScrolled != v { previewScrolled = v } }
    func setEditorScrolled(_ v: Bool) { if editorScrolled != v { editorScrolled = v } }

    // MARK: Find

    func openFind() {
        findVisible = true
        findFocusToken += 1
        if !findText.isEmpty { Task { await find(backwards: false) } }
    }

    func closeFind() {
        findVisible = false
        findNoMatch = false
        preview.clearFind()
    }

    func find(backwards: Bool) async {
        guard !findText.isEmpty else { findNoMatch = false; preview.clearFind(); return }
        findNoMatch = !(await preview.find(findText, backwards: backwards))
    }

    // MARK: Links

    func route(_ url: URL) {
        switch url.scheme {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "mtdoc", "file":
            let file = URL(fileURLWithPath: url.path(percentEncoded: false))
            let frag = url.fragment
            let markdown = ["md", "markdown", "mmd", "mdown", "mdtxt", "mdtext"]
            guard markdown.contains(file.pathExtension.lowercased()) else {
                // Never launch applications, executables, scripts or directories from a document link.
                if LocalLinkPolicy.shouldRevealInsteadOfOpen(file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                else { NSWorkspace.shared.open(file) }
                return
            }
            if let doc = document, doc.fileURL?.standardizedFileURL == file.standardizedFileURL {
                if let frag { preview.scrollToHeading(frag) }
                return
            }
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { opened, alreadyOpen, _ in
                MainActor.assumeIsolated {
                    guard let frag, let doc = opened as? MarkdownDocument else { return }
                    if alreadyOpen && doc.model.preview.renderedCount > 0 { doc.model.preview.scrollToHeading(frag) }
                    else { doc.model.pendingFragment = frag }
                }
            }
        default:
            break
        }
    }
}
