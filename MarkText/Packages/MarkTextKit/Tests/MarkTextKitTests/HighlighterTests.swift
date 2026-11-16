import Foundation
import Testing
@testable import MarkTextKit

private func toks(_ s: String, _ r: NSRange? = nil) -> [(String, SyntaxKind)] {
    let ns = s as NSString
    return MarkdownSyntax.tokens(in: s, range: r).map { (ns.substring(with: $0.range), $0.kind) }
}

private func has(_ t: [(String, SyntaxKind)], _ text: String, _ kind: SyntaxKind) -> Bool {
    t.contains { $0.0 == text && $0.1 == kind }
}

@Suite("Highlighter")
struct HighlighterTests {
    @Test func headings() {
        let t = toks("## Hello *world*\n#NoSpace\n####### seven")
        #expect(has(t, "##", .headingMarker))
        #expect(has(t, "Hello *world*", .headingText(level: 2)))
        #expect(has(t, "*", .emphasisMarker))
        #expect(!t.contains { $0.0 == "#" })
        #expect(!t.contains { if case .headingMarker = $0.1 { return $0.0.count > 2 }; return false })
        #expect(has(toks("# Title ##"), "Title", .headingText(level: 1)))
    }

    @Test func inlineStyles() {
        let t = toks("a **bold** and *em* and ***both*** and __b__ and _e_ and snake_case_word")
        #expect(has(t, "bold", .strong))
        #expect(has(t, "em", .emphasis))
        #expect(has(t, "both", .strong) && has(t, "both", .emphasis))
        #expect(has(t, "b", .strong))
        #expect(has(t, "e", .emphasis))
        #expect(!t.contains { $0.0 == "case" })
        #expect(toks("2 * 3 * 4").isEmpty)
    }

    @Test func codeSpansProtectContent() {
        let t = toks("`a *b* c` and ``x ` *y*`` end")
        #expect(has(t, "`a *b* c`", .codeSpan))
        #expect(has(t, "``x ` *y*``", .codeSpan))
        #expect(!t.contains { $0.1 == .emphasis })
    }

    @Test func links() {
        let t = toks("see [the **docs**](https://x.y/z) and ![img](a.png) <https://q.io> https://example.com/path.")
        #expect(has(t, "[the **docs**]", .linkText))
        #expect(has(t, "(https://x.y/z)", .linkURL))
        #expect(has(t, "![img]", .linkText))
        #expect(has(t, "<https://q.io>", .linkURL))
        #expect(has(t, "https://example.com/path", .linkURL))
        #expect(has(t, "docs", .strong))
    }

    @Test func listsAndTasks() {
        let t = toks("- item\n  * nested\n1. one\n10) ten\n- [ ] todo\n- [x] done\n+ plus")
        #expect(t.filter { $0.1 == .listMarker }.map(\.0) == ["-", "*", "1.", "10)", "-", "-", "+"])
        #expect(t.filter { $0.1 == .taskBox }.map(\.0) == ["[ ]", "[x]"])
        #expect(toks("-notalist").isEmpty)
    }

    @Test func blockquoteAndHR() {
        let t = toks("> quote **b**\n>> nested\n---\n***\n- - -")
        #expect(has(t, "> quote **b**", .blockquote))
        #expect(has(t, ">> nested", .blockquote))
        #expect(t.filter { $0.1 == .hr }.count == 3)
    }

    @Test func fencesKeepState() {
        let src = "text\n```swift\nlet a = *b*\n# not heading\n```\n# real\n~~~\nx\n~~~~\nafter"
        let t = toks(src)
        #expect(t.filter { $0.1 == .fenceLine }.map(\.0) == ["```swift", "```", "~~~", "~~~~"])
        #expect(t.filter { $0.1 == .codeBlock }.map(\.0) == ["let a = *b*", "# not heading", "x"])
        #expect(has(t, "real", .headingText(level: 1)))
        #expect(!t.contains { $0.1 == .emphasis })
    }

    @Test func rangeInsideFenceStillCode() {
        let src = "```\n# a\n*b*\n```\n"
        let ns = src as NSString
        let r = ns.range(of: "*b*")
        let t = toks(src, r)
        #expect(t.map(\.1) == [.codeBlock])
        let p = MarkdownSyntax.paragraphRangeForHighlight(in: src, around: r)
        #expect(p == NSRange(location: 0, length: ns.length))
    }

    @Test func paragraphRangeOutsideFence() {
        let src = "one\ntwo\n```\ncode\n```\nthree\n"
        let ns = src as NSString
        let p = MarkdownSyntax.paragraphRangeForHighlight(in: src, around: NSRange(location: ns.range(of: "two").location + 1, length: 0))
        #expect(ns.substring(with: p) == "two\n")
    }

    @Test func unterminatedFenceRunsToEnd() {
        let t = toks("```\na\nb")
        #expect(t.filter { $0.1 == .codeBlock }.count == 2)
    }

    @Test func mathRules() {
        let t = toks("inline $E = mc^2$ here, costs $5 and $10 total, \\$x\\$ escaped, $$a+b$$ ok")
        #expect(has(t, "$E = mc^2$", .math))
        #expect(has(t, "$$a+b$$", .math))
        #expect(t.filter { $0.1 == .math }.count == 2)
        let b = toks("$$\n\\int x\n$$\nafter *em*")
        #expect(b.filter { $0.1 == .math }.count == 3)
        #expect(has(b, "em", .emphasis))
    }

    @Test func ruleParagraphRuleIsNotFrontMatter() {
        let t = toks("---\n\nIntro\n\n---\n")
        #expect(!t.contains { $0.1 == .frontMatter })
    }

    @Test func frontMatterAndHTML() {
        let t = toks("---\ntitle: x\n---\n# H\n<div class=\"a\">\n<!-- multi\nline -->\n*e*")
        #expect(t.first?.1 == .frontMatter)
        #expect(t.first?.0 == "---\ntitle: x\n---")
        #expect(has(t, "<div class=\"a\">", .html))
        #expect(has(t, "<!-- multi", .html) && has(t, "line -->", .html))
        #expect(has(t, "e", .emphasis))
        // A lone leading hr is not front matter.
        #expect(toks("---\ntext").first?.1 == .hr)
    }

    @Test func referenceDefinitions() {
        let t = toks("[ref]: https://example.com \"Title\"\n[^1]: note")
        #expect(has(t, "[ref]", .linkText))
        #expect(has(t, "https://example.com \"Title\"", .linkURL))
    }

    @Test func utf16RangesWithEmoji() {
        let s = "😀 **bold** 日本語 *e*"
        let ns = s as NSString
        let t = MarkdownSyntax.tokens(in: s)
        let strong = t.first { $0.kind == .strong }!
        #expect(ns.substring(with: strong.range) == "bold")
        let em = t.first { $0.kind == .emphasis }!
        #expect(ns.substring(with: em.range) == "e")
    }

    @Test func crlf() {
        let t = toks("# A\r\n- b\r\n```\r\nc\r\n```\r\n")
        #expect(has(t, "A", .headingText(level: 1)))
        #expect(has(t, "c", .codeBlock))
    }

    @Test func showcaseHasNoOutOfBoundsTokens() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/showcase", withExtension: "md"))
        let s = try String(contentsOf: url, encoding: .utf8)
        let len = (s as NSString).length
        let t = MarkdownSyntax.tokens(in: s)
        #expect(!t.isEmpty)
        for k in t { #expect(k.range.location >= 0 && k.range.length > 0 && NSMaxRange(k.range) <= len) }
    }

    @Test func performanceOneMegabyte() {
        let unit = (try? String(contentsOf: Bundle.module.url(forResource: "Fixtures/showcase", withExtension: "md")!, encoding: .utf8)) ?? "# T\n**b** *e* `c` [l](u)\n- x\n"
        var s = ""
        while s.utf8.count < 1_000_000 { s += unit }
        let t0 = ContinuousClock.now
        let toks = MarkdownSyntax.tokens(in: s)
        let dt = ContinuousClock.now - t0
        print("HIGHLIGHT 1MB: \(dt) tokens=\(toks.count)")
        #expect(toks.count > 1000)
        #if !DEBUG
        #expect(dt < .milliseconds(150))
        #endif
    }
}

@Suite("Highlighter list continuation")
struct ListContinuationTests {
    private func act(_ l: String, _ caret: Int? = nil) -> ListContinuation.Action {
        ListContinuation.action(line: l, caret: caret ?? (l as NSString).length)
    }

    @Test func bulletsOrderedTasksQuotes() {
        #expect(act("- item") == .insert("\n- "))
        #expect(act("  * nested") == .insert("\n  * "))
        #expect(act("9. nine") == .insert("\n10. "))
        #expect(act("3) three") == .insert("\n4) "))
        #expect(act("- [x] done") == .insert("\n- [ ] "))
        #expect(act("> quote") == .insert("\n> "))
        #expect(act("> - item") == .insert("\n> - "))
        #expect(act("plain") == .none)
        #expect(act("-notlist") == .none)
    }

    @Test func emptyMarkerClears() {
        #expect(act("- ") == .clear(NSRange(location: 0, length: 2)))
        #expect(act("  1. ") == .clear(NSRange(location: 0, length: 5)))
        #expect(act("- [ ] ") == .clear(NSRange(location: 0, length: 6)))
        #expect(act(">") == .clear(NSRange(location: 0, length: 1)))
    }

    @Test func caretInsideMarkerIsPlain() {
        #expect(act("- item", 1) == .none)
        #expect(act("- item", 2) == .insert("\n- "))
    }
}
