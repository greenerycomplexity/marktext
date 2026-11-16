import Foundation

public struct Heading: Hashable, Sendable, Identifiable {
    public let id: String
    public let level: Int
    public let title: String
    public init(id: String, level: Int, title: String) { self.id = id; self.level = level; self.title = title }
}

public struct DocumentStats: Hashable, Sendable {
    public let words: Int
    public let readingMinutes: Int
    public init(words: Int, readingMinutes: Int) { self.words = words; self.readingMinutes = readingMinutes }
}

public struct RenderedDocument: Sendable {
    public let html: String
    public let headings: [Heading]
    public let stats: DocumentStats
    public let hasMath: Bool
    public let hasMermaid: Bool
    public init(html: String, headings: [Heading], stats: DocumentStats, hasMath: Bool, hasMermaid: Bool) {
        self.html = html; self.headings = headings; self.stats = stats
        self.hasMath = hasMath; self.hasMermaid = hasMermaid
    }
}

public enum PreviewAssets {
    /// The resource bundle of this package.
    public static var bundle: Bundle { Bundle.module }
    /// Folder containing template.html, marktext.css, marktext.js, vendor/…
    public static var webRoot: URL { Bundle.module.url(forResource: "web", withExtension: nil)! }
    public static var templateURL: URL { webRoot.appendingPathComponent("template.html") }
}
