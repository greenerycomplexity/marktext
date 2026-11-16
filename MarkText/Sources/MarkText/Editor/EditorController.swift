import AppKit
import MarkTextKit
import QuartzCore

/// NSTextView subclass: keeps the text column centred (max 760pt) and reports window attachment.
final class EditorTextView: NSTextView {
    static let maxColumnWidth: CGFloat = 760
    var onLayoutWidthChange: (() -> Void)?
    var onMoveToWindow: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onLayoutWidthChange?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }
}

/// Owns the NSScrollView + NSTextView (TextKit 2), highlighting, list continuation and scroll sync.
/// SwiftUI-free so the debug harness can host it offscreen.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView: NSScrollView
    let textView: EditorTextView
    private(set) var style: EditorStyle

    var onTextChange: ((String) -> Void)?
    var onTopLineChange: ((Int) -> Void)?

    // Highlight state
    private var palette: EditorPalette
    private var fonts = Fonts(size: 13.5)
    private var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private var cachedUnits: [UInt16] = []
    private var lineStarts: [Int]?
    private var blocks: [NSRange] = []
    private var pending: NSRange?
    private var continuing = false
    private let defaultSelectedAttributes: [NSAttributedString.Key: Any]

    // Scroll state
    private var lastReport: CFTimeInterval = 0
    private var trailingScheduled = false
    private var lastLine = 0
    private var suppressReports = false
    private var lastScrollID: UUID?

    private static let chunkSize = 100_000
    private static let incrementalThreshold = 200_000

    struct Fonts {
        var regular: NSFont, semibold: NSFont, italic: NSFont, semiboldItalic: NSFont
        init(size: CGFloat) {
            regular = .monospacedSystemFont(ofSize: size, weight: .regular)
            semibold = .monospacedSystemFont(ofSize: size, weight: .semibold)
            italic = Fonts.italicized(regular)
            semiboldItalic = Fonts.italicized(semibold)
        }
        static func italicized(_ f: NSFont) -> NSFont {
            let d = f.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: d, size: f.pointSize) ?? f
        }
    }

    init(text: String, style: EditorStyle) {
        let sv = EditorTextView.scrollableTextView()
        guard let tv = sv.documentView as? EditorTextView else { fatalError("scrollableTextView did not create EditorTextView") }
        scrollView = sv
        textView = tv
        self.style = style
        palette = EditorPalette.make(style.theme)
        defaultSelectedAttributes = tv.selectedTextAttributes
        super.init()

        // TextKit 2 only: never touch `.layoutManager`.
        assert(tv.textLayoutManager != nil, "EditorTextView must use TextKit 2")

        sv.drawsBackground = false
        sv.contentView.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.automaticallyAdjustsContentInsets = false
        sv.borderType = .noBorder
        sv.contentView.postsBoundsChangedNotifications = true

        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = false
        tv.usesFontPanel = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 5

        tv.delegate = self
        tv.textStorage?.delegate = self
        tv.onLayoutWidthChange = { [weak self] in self?.updateInsets() }

        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: sv.contentView)

        applyStyleCore()
        setExternalText(text)
    }

    // MARK: Style

    func apply(style new: EditorStyle) {
        guard new != style else { return }
        let old = style
        style = new
        applyStyleCore()
        if old.theme != new.theme || old.fontSize != new.fontSize {
            scheduleHighlight(NSRange(location: 0, length: cachedUnits.count))
        }
    }

    private func applyStyleCore() {
        palette = EditorPalette.make(style.theme)
        fonts = Fonts(size: style.editorFontSize)
        let ps = NSMutableParagraphStyle()
        let natural = fonts.regular.ascender - fonts.regular.descender + fonts.regular.leading
        ps.lineSpacing = (natural * 0.5).rounded()
        ps.lineBreakMode = .byWordWrapping
        baseAttributes = [.font: fonts.regular, .foregroundColor: palette.text, .paragraphStyle: ps]
        textView.defaultParagraphStyle = ps
        textView.typingAttributes = baseAttributes
        textView.insertionPointColor = palette.caret
        textView.selectedTextAttributes = style.theme == .sepia ? [.backgroundColor: palette.selection] : defaultSelectedAttributes
        let appearance: NSAppearance? = switch style.theme {
        case .auto: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light, .sepia: NSAppearance(named: .aqua)
        }
        scrollView.appearance = appearance
        scrollView.contentInsets = NSEdgeInsets(top: style.topInset, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        updateInsets()
    }

    private func updateInsets() {
        let w = textView.frame.width
        let h = max(24, ((w - EditorTextView.maxColumnWidth) / 2).rounded(.down))
        let inset = NSSize(width: h, height: 24)
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
    }

    // MARK: Text

    private func fetchUnits() -> [UInt16] {
        let ns = textView.textStorage?.mutableString ?? NSMutableString()
        let n = ns.length
        return [UInt16](unsafeUninitializedCapacity: n) { buf, count in
            if n > 0 { ns.getCharacters(buf.baseAddress!, range: NSRange(location: 0, length: n)) }
            count = n
        }
    }

    /// Replace the document text from outside (load / external reload) with a minimal edit,
    /// preserving selection and scroll position.
    func setExternalText(_ new: String) {
        guard let storage = textView.textStorage else { return }
        let old = cachedUnits
        let newUnits = Array(new.utf16)
        if old == newUnits, storage.length == old.count { return }
        var p = 0
        let m = min(old.count, newUnits.count)
        while p < m, old[p] == newUnits[p] { p += 1 }
        var s = 0
        while s < m - p, old[old.count - 1 - s] == newUnits[newUnits.count - 1 - s] { s += 1 }
        if p > 0, UTF16.isLeadSurrogate(old[p - 1]) { p -= 1 }
        if s > 0, UTF16.isTrailSurrogate(old[old.count - s]) { s -= 1 }
        let oldRange = NSRange(location: p, length: old.count - p - s)
        let replacement = String(decoding: newUnits[p..<(newUnits.count - s)], as: UTF16.self)
        let sel = textView.selectedRange()
        textView.undoManager?.removeAllActions(withTarget: textView)
        storage.replaceCharacters(in: oldRange, with: replacement)
        let delta = replacement.utf16.count - oldRange.length
        func map(_ i: Int) -> Int {
            if i <= p { return i }
            if i >= p + oldRange.length { return i + delta }
            return p + replacement.utf16.count
        }
        let newLen = storage.length
        let a = min(map(sel.location), newLen)
        let b = min(map(sel.location + sel.length), newLen)
        textView.setSelectedRange(NSRange(location: a, length: max(0, b - a)))
    }

    func textDidChange(_ notification: Notification) {
        onTextChange?(textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Keep typing attributes plain so a bold run does not leak into new text.
        textView.typingAttributes = baseAttributes
    }

    // MARK: Editing / highlighting

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { handleEdit(editedRange, delta: delta) }
    }

    private func handleEdit(_ edited: NSRange, delta: Int) {
        let units = fetchUnits()
        cachedUnits = units
        lineStarts = nil
        let newBlocks = MarkdownSyntax.blockRanges(utf16: units)
        var region = MarkdownSyntax.paragraphRange(utf16: units, around: edited, blocks: newBlocks)

        // Re-highlight any multi-line block whose extent changed (e.g. an opening fence was typed).
        let editStart = edited.location
        let oldEditEnd = editStart + edited.length - delta
        let newEditEnd = editStart + edited.length
        var mapped = Set<NSRange>()
        var dirty: [NSRange] = []
        for b in blocks {
            let bEnd = b.location + b.length
            if bEnd <= editStart { mapped.insert(b) } else if b.location >= oldEditEnd {
                mapped.insert(NSRange(location: b.location + delta, length: b.length))
            } else {
                let start = min(b.location, editStart)
                let end = bEnd <= oldEditEnd ? newEditEnd : bEnd + delta
                dirty.append(NSRange(location: start, length: max(0, end - start)))
            }
        }
        let newSet = Set(newBlocks)
        for b in newBlocks where !mapped.contains(b) { dirty.append(b) }
        for b in mapped where !newSet.contains(b) { dirty.append(b) }
        for d in dirty { region = NSUnionRange(region, d) }
        region = NSIntersectionRange(region, NSRange(location: 0, length: units.count))
        blocks = newBlocks

        if var pend = pending {
            if edited.location < pend.location { pend.location = max(0, pend.location + delta) }
            pend = NSIntersectionRange(pend, NSRange(location: 0, length: units.count))
            pending = pend.length > 0 ? pend : nil
        }
        scheduleHighlight(region)
    }

    private func scheduleHighlight(_ region: NSRange) {
        let full = NSRange(location: 0, length: cachedUnits.count)
        let region = NSIntersectionRange(region, full)
        guard region.length > 0 else { return }
        if region.length <= Self.incrementalThreshold {
            highlight(region)
            return
        }
        let first = chunk(startingAt: region.location, end: NSMaxRange(region))
        highlight(first)
        let rest = NSRange(location: NSMaxRange(first), length: NSMaxRange(region) - NSMaxRange(first))
        if rest.length > 0 {
            pending = pending.map { NSUnionRange($0, rest) } ?? rest
            continuePending()
        }
    }

    private func chunk(startingAt start: Int, end: Int) -> NSRange {
        var e = min(end, start + Self.chunkSize)
        if e < end {
            while e < end, cachedUnits[e - 1] != 10 { e += 1 }
        }
        return NSRange(location: start, length: e - start)
    }

    private func continuePending() {
        guard !continuing else { return }
        continuing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.continuing = false
            guard let p = self.pending else { return }
            let r = NSIntersectionRange(p, NSRange(location: 0, length: self.cachedUnits.count))
            guard r.length > 0 else { self.pending = nil; return }
            let c = self.chunk(startingAt: r.location, end: NSMaxRange(r))
            self.highlight(c)
            let rest = NSRange(location: NSMaxRange(c), length: NSMaxRange(r) - NSMaxRange(c))
            self.pending = rest.length > 0 ? rest : nil
            if rest.length > 0 { self.continuePending() }
        }
    }

    /// Paints `region` (UTF-16 range, whole lines) with the syntax attributes.
    private func highlight(_ region: NSRange) {
        guard let storage = textView.textStorage, region.length > 0, NSMaxRange(region) <= storage.length else { return }
        let tokens = MarkdownSyntax.tokens(utf16: cachedUnits, range: region)
        // Per-character style: bits 0-2 = color slot, 8 = bold, 16 = italic.
        var st = [UInt8](repeating: 0, count: region.length)
        let origin = region.location
        func paint(_ r: NSRange, color: UInt8? = nil, bits: UInt8 = 0) {
            let a = max(r.location, origin) - origin
            let b = min(NSMaxRange(r), NSMaxRange(region)) - origin
            guard b > a else { return }
            if let color {
                for i in a..<b { st[i] = (st[i] & ~7) | color }
            }
            if bits != 0 {
                for i in a..<b { st[i] |= bits }
            }
        }
        for t in tokens {
            switch t.kind {
            case .headingMarker, .strongMarker, .emphasisMarker, .fenceLine, .listMarker, .taskBox, .hr, .linkURL:
                paint(t.range, color: 2)
            case .headingText, .strong: paint(t.range, bits: 8)
            case .emphasis: paint(t.range, bits: 16)
            case .codeSpan, .codeBlock: paint(t.range, color: 3)
            case .linkText: paint(t.range, color: 4)
            case .blockquote, .html, .frontMatter: paint(t.range, color: 1)
            case .math: paint(t.range, color: 5)
            }
        }
        let slots = palette.slots
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: region)
        var i = 0
        let n = st.count
        while i < n {
            let v = st[i]
            var j = i + 1
            while j < n, st[j] == v { j += 1 }
            if v != 0 {
                var attrs: [NSAttributedString.Key: Any] = [:]
                let slot = Int(v & 7)
                if slot != 0 { attrs[.foregroundColor] = slots[slot] }
                switch v & 24 {
                case 8: attrs[.font] = fonts.semibold
                case 16: attrs[.font] = fonts.italic
                case 24: attrs[.font] = fonts.semiboldItalic
                default: break
                }
                storage.addAttributes(attrs, range: NSRange(location: origin + i, length: j - i))
            }
            i = j
        }
        storage.endEditing()
    }

    // MARK: Return key

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        return handleReturn()
    }

    private func handleReturn() -> Bool {
        guard let storage = textView.textStorage else { return false }
        let sel = textView.selectedRange()
        guard sel.length == 0 else { return false }
        let ns = storage.mutableString
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: sel.location, length: 0))
        guard sel.location <= contentsEnd else { return false }
        let lineRange = NSRange(location: start, length: contentsEnd - start)
        // Lists inside code, math, front matter or HTML are plain text.
        let toks = MarkdownSyntax.tokens(utf16: cachedUnits, range: lineRange)
        if toks.contains(where: { [.codeBlock, .fenceLine, .math, .frontMatter, .html].contains($0.kind) }) { return false }
        let line = ns.substring(with: lineRange)
        switch ListContinuation.action(line: line, caret: sel.location - start) {
        case .none:
            return false
        case .insert(let s):
            textView.insertText(s, replacementRange: sel)
            return true
        case .clear(let r):
            let abs = NSRange(location: start + r.location, length: r.length)
            if textView.shouldChangeText(in: abs, replacementString: "") {
                storage.replaceCharacters(in: abs, with: "")
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: abs.location, length: 0))
            }
            return true
        }
    }

    // MARK: Scrolling

    private func ensureLineStarts() -> [Int] {
        if let l = lineStarts { return l }
        var l = [0]
        let u = cachedUnits
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == 10 { l.append(i + 1) } else if c == 13 {
                if i + 1 < u.count, u[i + 1] == 10 { i += 1 }
                l.append(i + 1)
            }
            i += 1
        }
        lineStarts = l
        return l
    }

    private var topPadding: CGFloat { textView.textContainerInset.height }

    func scroll(to request: EditorScrollRequest) {
        guard request.id != lastScrollID else { return }
        lastScrollID = request.id
        scrollToLine(request.line)
    }

    func scrollToLine(_ line: Int) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return }
        let starts = ensureLineStarts()
        let idx = starts[max(0, min(line - 1, starts.count - 1))]
        guard let loc = tcm.location(tcm.documentRange.location, offsetBy: idx) else { return }
        let docStart = tcm.documentRange.location
        let upTo = tcm.location(loc, offsetBy: 1) ?? loc
        if let r = NSTextRange(location: docStart, end: upTo) { tlm.ensureLayout(for: r) }
        var y: CGFloat = 0
        if let frag = tlm.textLayoutFragment(for: loc) {
            y = frag.layoutFragmentFrame.minY
        }
        let origin = textView.textContainerOrigin.y
        let target = y + origin - style.topInset - topPadding
        let clip = scrollView.contentView
        let maxY = max(-style.topInset, textView.frame.height - clip.bounds.height)
        suppressReports = true
        clip.scroll(to: NSPoint(x: 0, y: max(-style.topInset, min(target, maxY))))
        scrollView.reflectScrolledClipView(clip)
        suppressReports = false
        lastLine = line
        lastReport = CACurrentMediaTime()
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        guard !suppressReports, onTopLineChange != nil else { return }
        let now = CACurrentMediaTime()
        let interval = 1.0 / 30.0
        if now - lastReport >= interval {
            reportTopLine()
        } else if !trailingScheduled {
            trailingScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - (now - lastReport))) { [weak self] in
                guard let self else { return }
                self.trailingScheduled = false
                self.reportTopLine()
            }
        }
    }

    private func reportTopLine() {
        lastReport = CACurrentMediaTime()
        let line = currentTopLine()
        guard line != lastLine else { return }
        lastLine = line
        onTopLineChange?(line)
    }

    func currentTopLine() -> Int {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return 1 }
        let clip = scrollView.contentView.bounds
        let probe = max(0, clip.origin.y + style.topInset + topPadding + 2)
        let local = CGPoint(x: textView.textContainerInset.width + 8, y: probe) // textView coords
        let containerPoint = CGPoint(x: 8, y: local.y - textView.textContainerOrigin.y)
        guard let frag = tlm.textLayoutFragment(for: containerPoint) else { return 1 }
        let idx = tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.location)
        let starts = ensureLineStarts()
        // Binary search for the last start <= idx.
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= idx { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    // MARK: Focus

    func focusWhenAttached() {
        textView.onMoveToWindow = { [weak self] in
            guard let self else { return }
            self.textView.onMoveToWindow = nil
            DispatchQueue.main.async { self.textView.window?.makeFirstResponder(self.textView) }
        }
        if textView.window != nil { textView.onMoveToWindow?() }
    }
}
