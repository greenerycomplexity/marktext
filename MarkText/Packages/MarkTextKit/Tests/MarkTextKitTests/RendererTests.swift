import Testing
import Foundation
@testable import MarkTextKit

@Suite("Blocks and inline basics")
struct BasicTests {
    @Test func paragraphEmphasisAndBreaks() {
        let h = html("Hello *world* and **bold** and ~~gone~~.\nsoft  \nhard")
        #expect(h.contains("<em>world</em>"))
        #expect(h.contains("<strong>bold</strong>"))
        #expect(h.contains("<del>gone</del>"))
        #expect(h.contains("soft<br>\nhard"))
        let soft = html("one\ntwo")
        #expect(soft.contains("one\ntwo"))
        #expect(!soft.contains("<br>"))
    }

    @Test func listsAndNesting() {
        let h = html("- a\n- b\n  - c\n\n1. x\n2. y\n\n3. start\n")
        #expect(h.contains("<ul data-line=\"1\">"))
        #expect(h.contains("<li data-line=\"1\">a</li>"))
        #expect(h.contains("<li data-line=\"2\">b\n<ul data-line=\"3\">"))
        #expect(h.contains("<ol data-line=\"5\">"))
    }

    @Test func orderedListStart() {
        #expect(html("3. a\n4. b").contains("<ol start=\"3\" data-line=\"1\">"))
    }

    @Test func looseListWrapsParagraphs() {
        let h = html("- a\n\n- b\n")
        #expect(h.contains("<p data-line=\"1\">a</p>"))
        #expect(h.contains("<p data-line=\"3\">b</p>"))
    }

    @Test func blockquoteAndHr() {
        let h = html("> quote\n\n---\n")
        #expect(h.contains("<blockquote data-line=\"1\">"))
        #expect(h.contains("<hr data-line=\"3\">"))
    }

    @Test func rawHTMLPassesThroughUnchanged() {
        let block = "<div class=\"x\" onclick=\"y()\">\n  <b>hi</b>\n</div>"
        #expect(html(block).contains(block))
        let inline = html("text <kbd>⌘</kbd> and <script>alert(1)</script>")
        #expect(inline.contains("<kbd>⌘</kbd>"))
        #expect(inline.contains("<script>"))
    }

    @Test func imagesAndLinks() {
        let h = html("![alt *text*](rel/pic.png \"Title\") [l](other.md \"t\") [a](#anchor)")
        #expect(h.contains("<img src=\"rel/pic.png\" alt=\"alt text\" title=\"Title\">"))
        #expect(h.contains("<a href=\"other.md\" title=\"t\">l</a>"))
        #expect(h.contains("<a href=\"#anchor\">a</a>"))
        #expect(html("![x](https://a.b/c.svg)").contains("<img src=\"https://a.b/c.svg\" alt=\"x\">"))
    }

    @Test func noSmartPunctuation() {
        #expect(html("\"quoted\" -- dash...").contains("\"quoted\" -- dash..."))
    }

    @Test func emptyDocument() {
        let r = render("")
        #expect(r.html.isEmpty)
        #expect(r.headings.isEmpty)
        #expect(r.stats == DocumentStats(words: 0, readingMinutes: 0))
        #expect(!r.hasMath && !r.hasMermaid)
    }

    @Test func crlfAndBOM() {
        let r = render("\u{FEFF}# Title\r\n\r\ntext\r\n")
        #expect(r.html.contains("<h1 id=\"title\" data-line=\"1\">Title</h1>"))
        #expect(r.html.contains("<p data-line=\"3\">text</p>"))
    }
}

@Suite("GFM")
struct GFMTests {
    @Test func tableAlignment() {
        let h = html("| a | b | c | d |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |\n")
        #expect(h.contains("<table data-line=\"1\">"))
        #expect(h.contains("<th align=\"left\" style=\"text-align:left\">a</th>"))
        #expect(h.contains("<th align=\"center\" style=\"text-align:center\">b</th>"))
        #expect(h.contains("<td align=\"right\" style=\"text-align:right\">3</td>"))
        #expect(h.contains("<td>4</td>"))
        #expect(h.contains("<thead>") && h.contains("<tbody>"))
    }

    @Test func tableCellsRenderInlines() {
        let h = html("| x |\n|---|\n| `c` **b** $m$ |\n")
        #expect(h.contains("<td><code>c</code> <strong>b</strong> <span class=\"math-inline\">m</span></td>"))
    }

    @Test func taskLists() {
        let h = html("- [x] done\n- [ ] todo\n- plain\n")
        #expect(h.contains("<li class=\"task\" data-line=\"1\"><input type=\"checkbox\" disabled checked> done</li>"))
        #expect(h.contains("<li class=\"task\" data-line=\"2\"><input type=\"checkbox\" disabled> todo</li>"))
        #expect(h.contains("<li data-line=\"3\">plain</li>"))
    }

    @Test func autolinksInText() {
        let h = html("See https://example.com/a?b=1&c=2, and www.example.org.\n")
        #expect(h.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">https://example.com/a?b=1&amp;c=2</a>,"))
        #expect(h.contains("\">www.example.org</a>."))
        #expect(h.contains("<a href=\"http"))
    }

    @Test func autolinksSkipCodeAndLinks() {
        let h = html("`https://a.com` [https://b.com](https://c.com)\n\n```\nhttps://d.com\n```\n")
        #expect(!h.contains("href=\"https://a.com\""))
        #expect(!h.contains("href=\"https://d.com\""))
        #expect(!h.contains("href=\"https://b.com\""))
        #expect(h.contains("<a href=\"https://c.com\">https://b.com</a>"))
        #expect(h.components(separatedBy: "<a ").count == 2)
    }

    @Test func angleBracketAutolinkAndEmailNotLinkified() {
        let h = html("<https://e.com/x> mail me@example.com")
        #expect(h.contains("<a href=\"https://e.com/x\">https://e.com/x</a>"))
        #expect(!h.contains("mailto"))
    }
}

@Suite("Headings and slugs")
struct HeadingTests {
    @Test func slugRules() {
        let r = render("# Hello, World!\n## Foo_bar  baz\n### C++ & Swift (6)\n#### Ünïcode Ñ\n")
        #expect(r.headings.map(\.id) == ["hello-world", "foo_bar--baz", "c--swift-6", "ünïcode-ñ"])
        #expect(r.headings.map(\.level) == [1, 2, 3, 4])
        #expect(r.headings[0].title == "Hello, World!")
    }

    @Test func dedupe() {
        let r = render("# A\n# A\n# A\n# A-1\n")
        #expect(r.headings.map(\.id) == ["a", "a-1", "a-2", "a-1-1"])
    }

    @Test func emptySlugFallsBackToSection() {
        let r = render("# 🎉\n# !!!\n#\n")
        #expect(r.headings.map(\.id) == ["section", "section-1", "section-2"])
        #expect(r.html.contains("<h1 id=\"section\" data-line=\"1\">🎉</h1>"))
    }

    @Test func emojiPrefixKeepsGitHubLeadingHyphen() {
        #expect(render("## 🎉 What's new").headings[0].id == "-whats-new")
    }

    @Test func inlineMarkupInTitle() {
        let r = render("## The `code` and *emph* [link](x)\n")
        #expect(r.headings[0].title == "The code and emph link")
        #expect(r.headings[0].id == "the-code-and-emph-link")
        #expect(r.html.contains("<h2 id=\"the-code-and-emph-link\" data-line=\"1\">The <code>code</code> and <em>emph</em> <a href=\"x\">link</a></h2>"))
    }

    @Test func headingsInsideContainersAreListed() {
        let r = render("> ## Quoted\n\n- ### In list\n")
        #expect(r.headings.map(\.title) == ["Quoted", "In list"])
    }

    @Test func titleContainingMathUsesRawTeX() {
        let r = render("# Energy $E=mc^2$\n")
        #expect(r.headings[0].title == "Energy E=mc^2")
        #expect(r.html.contains("<span class=\"math-inline\">E=mc^2</span>"))
    }
}

@Suite("Code, mermaid, math fences")
struct CodeTests {
    @Test func codeBlockEscapesAndLanguage() {
        let h = html("```swift\nlet a = 1 < 2 && \"x\" > \"y\"\n```\n")
        #expect(h.contains("<pre data-line=\"1\"><code class=\"language-swift\">let a = 1 &lt; 2 &amp;&amp; \"x\" &gt; \"y\"\n</code></pre>"))
    }

    @Test func infoStringExtraWordsIgnoredAndNoLanguage() {
        #expect(html("```js {1,3} title=x\nx\n```").contains("<code class=\"language-js\">"))
        #expect(html("```\nx\n```").contains("<pre data-line=\"1\"><code>x\n</code></pre>"))
    }

    @Test func indentedCodeBlock() {
        #expect(html("para\n\n    <b>code</b>\n").contains("<pre data-line=\"3\"><code>&lt;b&gt;code&lt;/b&gt;\n</code></pre>"))
    }

    @Test func mermaid() {
        let r = render("text\n\n```mermaid\ngraph TD\n  A[\"x\"] --> B\n```\n")
        #expect(r.hasMermaid)
        #expect(!r.hasMath)
        #expect(r.html.contains("<div class=\"mermaid\" data-line=\"3\" data-source=\"graph TD\n  A[&quot;x&quot;] --&gt; B\n\"></div>"))
        #expect(!r.html.contains("<pre"))
    }

    @Test func mathFence() {
        let r = render("```math\n\\frac{a}{b} < 1\n```\n")
        #expect(r.hasMath)
        #expect(r.html == "<div class=\"math-display\" data-line=\"1\">\\frac{a}{b} &lt; 1</div>\n")
    }

    @Test func flagsFalseWhenAbsent() {
        let r = render("# plain\n\ntext\n")
        #expect(!r.hasMath && !r.hasMermaid)
    }
}

@Suite("Math")
struct MathTests {
    @Test func inline() {
        let r = render("Let $x_1 + y$ be.")
        #expect(r.hasMath)
        #expect(r.html == "<p data-line=\"1\">Let <span class=\"math-inline\">x_1 + y</span> be.</p>\n")
    }

    @Test func texIsEscaped() {
        #expect(html("$a < b > c & d$").contains("<span class=\"math-inline\">a &lt; b &gt; c &amp; d</span>"))
    }

    @Test func currencyStaysLiteral() {
        let r = render("It costs $5 and $10 in total.")
        #expect(!r.hasMath)
        #expect(r.html == "<p data-line=\"1\">It costs $5 and $10 in total.</p>\n")
        #expect(!render("Pay $20, or $30.").hasMath)
    }

    @Test func currencyThenRealMath() {
        let r = render("Costs $5 and $10, but $x+1$ is math.")
        #expect(r.html.contains("Costs $5 and $10, but <span class=\"math-inline\">x+1</span> is math."))
    }

    @Test func escapedDollar() {
        let r = render("An escaped \\$x\\$ is text, \\\\$y$ is math.")
        #expect(r.html.contains("An escaped $x$ is text"))
        #expect(r.html.contains("<span class=\"math-inline\">y</span>"))
    }

    @Test func closingDollarFollowedByDigitIsNotMath() {
        #expect(!render("$a$1").hasMath)
        #expect(!render("$ a$ and $b $").hasMath)
    }

    @Test func displayStandaloneIsUnwrapped() {
        let r = render("Before\n\n$$\n\\sum_{i} x_i\n$$\n\nAfter\n")
        #expect(r.html.contains("<div class=\"math-display\" data-line=\"3\">\\sum_{i} x_i</div>"))
        #expect(!r.html.contains("<p data-line=\"3\">"))
        #expect(!r.html.contains("<p><div"))
        #expect(r.html.contains("<p data-line=\"7\">After</p>"))
    }

    @Test func singleLineDisplayStandalone() {
        #expect(html("$$ a+b $$").contains("<div class=\"math-display\" data-line=\"1\">a+b</div>"))
    }

    @Test func displayInsideParagraphUsesSpan() {
        #expect(html("x $$a$$ y").contains("<p data-line=\"1\">x <span class=\"math-display\">a</span> y</p>"))
    }

    @Test func displayInsideListAndQuote() {
        let h = html("- item\n\n  $$\n  x^2\n  $$\n\n> $$y$$\n")
        #expect(h.contains("<div class=\"math-display\""))
        #expect(!h.contains("MTKMATH"))
    }

    @Test func codeIsNeverMath() {
        let r = render("`$a$` and `$b` $c`\n\n```\n$$ x $$ and $y$\n```\n\n    $z$\n")
        #expect(!r.hasMath)
        #expect(r.html.contains("<code>$a$</code>"))
        #expect(r.html.contains("$$ x $$ and $y$"))
        #expect(!r.html.contains("MTKMATH"))
    }

    @Test func rawHTMLBlockIsNotMath() {
        let r = render("<div>\n$a$ and $b$\n</div>\n")
        #expect(!r.hasMath)
        #expect(r.html.contains("$a$ and $b$"))
    }

    @Test func inlineSpansDoNotCrossLines() {
        #expect(!render("$a\nb$").hasMath)
    }

    @Test func displayDoesNotCrossBlankLines() {
        let r = render("$$ a\n\nb $$")
        #expect(!r.hasMath)
    }

    @Test func manyMathItemsKeepOrder() {
        let src = (0..<25).map { "$m\($0)$" }.joined(separator: " ")
        let h = html(src)
        for i in 0..<25 { #expect(h.contains("<span class=\"math-inline\">m\(i)</span>")) }
        #expect(!h.contains("MTKMATH"))
    }

    @Test func emphasisAroundMath() {
        let h = html("**$a$** and *$b$*")
        #expect(h.contains("<strong><span class=\"math-inline\">a</span></strong>"))
        #expect(h.contains("<em><span class=\"math-inline\">b</span></em>"))
    }
}

@Suite("Front matter")
struct FrontMatterTests {
    @Test func strippedAndEmitted() {
        let r = render("---\ntitle: A <b>\nx: 1\n---\n# Heading\n")
        #expect(r.html.hasPrefix("<details class=\"front-matter\" data-line=\"1\"><summary>Front matter</summary><pre>title: A &lt;b&gt;\nx: 1</pre></details>\n"))
        #expect(r.html.contains("<h1 id=\"heading\" data-line=\"5\">Heading</h1>"))
        #expect(r.headings.map(\.title) == ["Heading"])
        #expect(!r.html.contains("<hr"))
    }

    @Test func unclosedIsThematicBreak() {
        let r = render("---\n\ntext\n")
        #expect(!r.html.contains("front-matter"))
        #expect(r.html.contains("<hr data-line=\"1\">"))
    }

    @Test func onlyAtStart() {
        let r = render("# T\n\n---\nkey: v\n---\n")
        #expect(!r.html.contains("front-matter"))
    }

    @Test func emptyFenceIsNotFrontMatter() {
        let r = render("---\n---\ntext")
        #expect(!r.html.contains("front-matter"))
        #expect(r.html.contains("<p data-line=\"3\">text</p>"))
    }

    @Test func hrParagraphHrIsNotFrontMatter() {
        let r = render("---\n\nIntro\n\n---\n")
        #expect(!r.html.contains("front-matter"))
        #expect(r.html.components(separatedBy: "<hr").count == 3)
        #expect(r.html.contains("Intro"))
    }

    @Test func proseBetweenRulesIsNotFrontMatter() {
        let r = render("---\nJust a line\n---\nafter\n")
        #expect(!r.html.contains("front-matter"))
    }

    @Test func commentStartIsFrontMatter() {
        let r = render("---\n# a comment\nk: v\n...\ntext\n")
        #expect(r.html.contains("front-matter"))
    }

    @Test func mathDelimitersInFrontMatterIgnored() {
        let r = render("---\nprice: $5\ncost: $6\n---\ntext\n")
        #expect(!r.hasMath)
    }
}

@Suite("Line mapping")
struct LineMappingTests {
    @Test func lineAfterMultilineDisplayMath() {
        let src = "# Title\n\n$$\na\nb\nc\n$$\n\nPara after\n\n- item\n\n```swift\ncode\n```\n"
        let r = render(src)
        #expect(r.html.contains("<h1 id=\"title\" data-line=\"1\">"))
        #expect(r.html.contains("<div class=\"math-display\" data-line=\"3\">"))
        #expect(r.html.contains("<p data-line=\"9\">Para after</p>"))
        #expect(r.html.contains("<li data-line=\"11\">item</li>"))
        #expect(r.html.contains("<pre data-line=\"13\">"))
    }

    @Test func lineAfterMultipleMathBlocksAndInlineMath() {
        let src = "$$\na\n$$\n\ntext $x$ here\n\n$$\nb\nc\n$$\n\nend\n"
        let h = html(src)
        #expect(h.contains("<div class=\"math-display\" data-line=\"1\">a</div>"))
        #expect(h.contains("<p data-line=\"5\">text"))
        #expect(h.contains("<div class=\"math-display\" data-line=\"7\">b\nc</div>"))
        #expect(h.contains("<p data-line=\"12\">end</p>"))
    }

    @Test func frontMatterKeepsLineNumbers() {
        let src = "---\na: 1\n---\n\ntext $x$\n\n$$\ny\n$$\n\nlast\n"
        let h = html(src)
        #expect(h.contains("<p data-line=\"5\">text"))
        #expect(h.contains("<p data-line=\"11\">last</p>"))
    }

    @Test func showcaseLinesPointAtTheRightSourceLines() throws {
        let src = try showcaseSource()
        let lines = sourceLines(src)
        let r = render(src)
        var checked = 0
        for (tag, line) in dataLines(r.html) {
            let text = lines[line - 1]
            switch tag {
            case "h1", "h2", "h3": #expect(text.hasPrefix("#"), "h at \(line): \(text)")
            case "hr": #expect(text == "---", "hr at \(line)")
            case "pre": #expect(text.hasPrefix("```") || text.hasPrefix("    "), "pre at \(line): \(text)")
            case "table": #expect(text.hasPrefix("|"), "table at \(line)")
            case "ul", "ol", "li": #expect(!text.isEmpty, "list at \(line)")
            case "blockquote": #expect(text.hasPrefix(">"))
            case "div": #expect(text == "$$" || text.hasPrefix("```") , "div at \(line): \(text)")
            case "p": #expect(!text.isEmpty && !text.hasPrefix("#") && !text.hasPrefix("```"), "p at \(line): \(text)")
            default: break
            }
            checked += 1
        }
        #expect(checked > 60)
        // Spot checks, computed from the fixture itself.
        func line(of prefix: String) -> Int { lines.firstIndex { $0.hasPrefix(prefix) }! + 1 }
        #expect(r.html.contains("<h2 id=\"math\" data-line=\"\(line(of: "## Math"))\">"))
        #expect(r.html.contains("<h2 id=\"diagrams\" data-line=\"\(line(of: "## Diagrams"))\">"))
        #expect(r.html.contains("<p data-line=\"\(line(of: "A single-line display"))\">"))
        #expect(r.html.contains("<div class=\"mermaid\" data-line=\"\(line(of: "```mermaid"))\""))
        #expect(r.html.contains("<h2 id=\"images\" data-line=\"\(line(of: "## Images"))\">"))
        #expect(r.html.contains("<hr data-line=\"\((lines.lastIndex { $0 == "---" }! + 1))\">"))
    }
}
