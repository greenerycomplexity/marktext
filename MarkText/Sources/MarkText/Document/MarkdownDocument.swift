import AppKit
import MarkTextKit
import Observation
import OSLog

final class MarkdownDocument: NSDocument {
    nonisolated static let log = Logger(subsystem: "io.github.greenerycomplexity.MarkText", category: "document")

    let model = DocumentModel()
    // NSDocument's data-reading/writing entry points are NS_SWIFT_NONISOLATED; with
    // canConcurrentlyReadDocuments == false they always run on the main thread.
    nonisolated(unsafe) private(set) var encoding: String.Encoding = .utf8
    nonisolated(unsafe) private(set) var hasBOM = false
    nonisolated(unsafe) private(set) var lineEnding: LineEndingStyle = .lf

    /// Save As, rename and move change the folder relative images resolve against.
    override nonisolated var fileURL: URL? {
        didSet {
            guard oldValue != fileURL else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.model.preview.setDocumentDirectory(self.fileURL?.deletingLastPathComponent())
                    self.windowControllers.forEach { ($0 as? DocumentWindowController)?.updateShareItem() }
                }
            }
        }
    }

    override nonisolated class var autosavesInPlace: Bool { true }
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    /// NSDocument is an NSFilePresenter and sees external writes even while the app is in the background,
    /// but its built-in silent auto-revert did not fire for an inactive (accessory) app in testing,
    /// so a clean document is reverted explicitly here. The file is only ever read, never rewritten.
    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.revertIfCleanAndChangedOnDisk() } }
    }

    private func revertIfCleanAndChangedOnDisk() {
        guard UserDefaults.standard.bool(forKey: PrefKey.reloadOnChange), !isDocumentEdited, !hasUnautosavedChanges,
              (undoManager?.groupingLevel ?? 0) == 0, let url = fileURL,
              let disk = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let known = fileModificationDate, disk > known else { return }
        do { try revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown") }
        catch { Self.log.error("revert failed: \(error.localizedDescription)") }
    }

    override func makeWindowControllers() {
        model.document = self
        model.mode = Harness.config?.mode ?? (model.text.allSatisfy(\.isWhitespace) ? .split : PrefKey.defaultViewMode)
        let wc = DocumentWindowController(document: self)
        addWindowController(wc)
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        // Decode first; encoding/BOM/line-ending state is committed only after a successful decode.
        let decoded: DecodedText
        do { decoded = try TextCodec.decode(data) } catch { throw CocoaError(.fileReadInapplicableStringEncoding) }
        encoding = decoded.encoding
        hasBOM = decoded.hasBOM
        lineEnding = decoded.lineEnding
        FileHandle.standardError.write(Data("[MarkText] document read: \(fileURL?.lastPathComponent ?? "?") bytes=\(data.count)\n".utf8))
        MainActor.assumeIsolated {
            model.preview.setDocumentDirectory(fileURL?.deletingLastPathComponent())
            model.load(decoded.text)
        }
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        let text = MainActor.assumeIsolated { model.text }
        do { return try TextCodec.encode(text, encoding: encoding, hasBOM: hasBOM, lineEnding: lineEnding) }
        catch { throw CocoaError(.fileWriteInapplicableStringEncoding) }
    }

    /// Edited, never saved: closing or quitting must ask whether to keep it.
    var needsSavePrompt: Bool { fileURL == nil && (isDocumentEdited || hasUnautosavedChanges) }

    // MARK: Print and export

    /// Printing needs the preview in a window; Edit mode detaches it, so switch to Read first (as export does).
    override func printDocument(_ sender: Any?) {
        guard model.mode == .edit else { super.printDocument(sender); return }
        model.mode = .read
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.printAfterSwitch(sender)
        }
    }

    private func printAfterSwitch(_ sender: Any?) { super.printDocument(sender) }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        MainActor.assumeIsolated {
            let op = model.preview.printOperation()
            for (k, v) in printSettings { op.printInfo.dictionary()[k] = v }
            return op
        }
    }

    /// Export needs the preview in a window; Edit mode detaches it, so switch to Read first.
    @MainActor private func ensurePreviewMounted() async {
        if model.mode == .edit { model.mode = .read; try? await Task.sleep(for: .milliseconds(600)) }
    }

    @MainActor func exportPDF(to url: URL, window: NSWindow?) async -> Bool {
        await ensurePreviewMounted()
        return await model.preview.exportPDF(to: url, window: window ?? windowControllers.first?.window)
    }

    @MainActor func exportHTML(to url: URL) async -> Bool {
        await ensurePreviewMounted()
        guard let html = await model.preview.exportHTML() else { return false }
        return (try? html.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}
