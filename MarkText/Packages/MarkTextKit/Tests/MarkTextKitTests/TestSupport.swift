import Testing
import Foundation
@testable import MarkTextKit

func render(_ s: String) -> RenderedDocument { MarkdownRenderer.render(s) }
func html(_ s: String) -> String { MarkdownRenderer.render(s).html }

func showcaseSource() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/showcase", withExtension: "md"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// Extracts every `data-line="N"` attribute together with its tag name, in order.
func dataLines(_ html: String) -> [(tag: String, line: Int)] {
    var result: [(String, Int)] = []
    let regex = try! NSRegularExpression(pattern: "<([a-z0-9]+)[^>]*? data-line=\"(\\d+)\"")
    let ns = html as NSString
    for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
        result.append((ns.substring(with: m.range(at: 1)), Int(ns.substring(with: m.range(at: 2)))!))
    }
    return result
}

func sourceLines(_ s: String) -> [String] { s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
