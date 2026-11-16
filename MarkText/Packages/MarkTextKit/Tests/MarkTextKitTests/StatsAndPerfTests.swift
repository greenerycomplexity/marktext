import Testing
import Foundation
@testable import MarkTextKit

@Suite("Stats")
struct StatsTests {
    @Test func wordsExcludeCodeMathUrlsAndFrontMatter() {
        let src = """
        ---
        title: ignored words in front matter
        ---
        # Two words

        Hello **bold** world, see https://example.com/long/path and www.example.org now.

        Inline math $a + b$ and `code` here.

        $$
        x y z
        $$

        ```swift
        let ignored = 1 words in code
        ```

        [link text](https://x.y) ![alt text](p.png)
        """
        let r = render(src)
        // Two words | Hello bold world, see and now. (6) | Inline math and code here. (5) | link text (2)
        #expect(r.stats.words == 2 + 6 + 5 + 2)
        #expect(r.stats.readingMinutes == 1)
    }

    @Test func wordsAcrossInlineMarkupAreOneWord() {
        #expect(render("foo*bar*baz and **x**y").stats.words == 3)
    }

    @Test func cjkCountsPerCharacter() {
        #expect(render("你好世界 ok").stats.words == 5)
    }

    @Test func readingMinutesRounding() {
        func words(_ n: Int) -> DocumentStats { render(Array(repeating: "w", count: n).joined(separator: " ")).stats }
        #expect(words(1).readingMinutes == 1)
        #expect(words(230).readingMinutes == 1)
        #expect(words(231).readingMinutes == 2)
        #expect(words(460).readingMinutes == 2)
        #expect(words(461).readingMinutes == 3)
        #expect(words(461).words == 461)
    }

    @Test func tablesAndListsCount() {
        #expect(render("| a | b |\n|---|---|\n| c | d |\n\n- e\n- f g\n").stats.words == 7)
    }
}

@Suite("Concurrency and performance")
struct PerformanceTests {
    @Test func concurrentRendersAreDeterministic() async throws {
        let src = try showcaseSource()
        let expected = render(src).html
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<16 { group.addTask { MarkdownRenderer.render(src).html } }
            for await h in group { #expect(h == expected) }
        }
    }

    @Test func renderOneMegabyte() throws {
        var unit = try showcaseSource()
        // Drop the front matter so repetitions are plain markdown.
        if let r = unit.range(of: "\n---\n\n") { unit = String(unit[r.upperBound...]) }
        var doc = ""
        while doc.utf8.count < 1_000_000 { doc += unit + "\n" }
        let bytes = doc.utf8.count
        #expect(bytes >= 1_000_000)

        _ = render(String(doc.prefix(50_000)))  // warm up
        var best = Duration.seconds(1000)
        var result: RenderedDocument?
        for _ in 0..<5 {
            let clock = ContinuousClock()
            let t = clock.measure { result = MarkdownRenderer.render(doc) }
            best = min(best, t)
        }
        let ms = Double(best.components.attoseconds) / 1e15 + Double(best.components.seconds) * 1000
        print("PERF render \(bytes) bytes: \(String(format: "%.1f", ms)) ms (best of 5)")
        let r = try #require(result)
        #expect(r.headings.count > 100)
        #expect(r.hasMath && r.hasMermaid)
        #expect(!r.html.contains("MTKMATH"))
        #if !DEBUG
        // The 400 ms budget is for a quiet machine. When other processes keep the CPU saturated
        // (1-minute load average above half the core count) only a loose sanity bound is enforced.
        var load = [Double](repeating: 0, count: 1)
        getloadavg(&load, 1)
        let busy = load[0] > Double(ProcessInfo.processInfo.activeProcessorCount) / 2
        if busy { print("PERF note: machine busy (load \(load[0])), enforcing 2000 ms instead of 400 ms") }
        #expect(ms < (busy ? 2000 : 400), "1 MB render took \(ms) ms (load \(load[0]))")
        #endif
    }
}
