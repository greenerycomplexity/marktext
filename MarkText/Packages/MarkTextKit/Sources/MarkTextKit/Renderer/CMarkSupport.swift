import Foundation
import cmark_gfm
import cmark_gfm_extensions

typealias CMarkNode = UnsafeMutablePointer<cmark_node>
typealias CMarkIter = UnsafeMutablePointer<cmark_iter>

/// Thin wrappers around the cmark-gfm C API shared by the math pre-pass and the HTML emitter.
enum CMark {
    /// `ensure_registered` mutates global state; a Swift lazy global makes the first call thread-safe.
    private static let registered: Void = { cmark_gfm_core_extensions_ensure_registered() }()

    /// Parses UTF-8 `bytes` into a cmark document. The caller owns the result (`cmark_node_free`).
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, options: Int32, extensions: [StaticString]) -> CMarkNode? {
        _ = registered
        guard let parser = cmark_parser_new(options) else { return nil }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            name.withUTF8Buffer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count + 1) { ptr in
                    if let ext = cmark_find_syntax_extension(ptr) { cmark_parser_attach_syntax_extension(parser, ext) }
                }
            }
        }
        if let base = bytes.baseAddress, bytes.count > 0 {
            base.withMemoryRebound(to: CChar.self, capacity: bytes.count) { cmark_parser_feed(parser, $0, bytes.count) }
        }
        return cmark_parser_finish(parser)
    }

    static func parse(_ text: String, options: Int32, extensions: [StaticString]) -> CMarkNode? {
        var s = text
        return s.withUTF8 { parse($0, options: options, extensions: extensions) }
    }
}

extension UnsafeBufferPointer<UInt8> {
    /// The NUL-terminated C string as a byte view (no copy).
    @inline(__always) init(cString c: UnsafePointer<CChar>?) {
        guard let c else { self.init(start: nil, count: 0); return }
        self.init(start: UnsafeRawPointer(c).assumingMemoryBound(to: UInt8.self), count: strlen(c))
    }
}
