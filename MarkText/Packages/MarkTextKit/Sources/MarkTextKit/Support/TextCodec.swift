import Foundation

public enum LineEndingStyle: Sendable, Equatable {
    case lf, crlf, cr
    /// More than one style in the file: the text is kept exactly as read and never converted.
    case mixed
}

public struct DecodedText: Sendable {
    /// LF-normalised for uniformly CRLF/CR files; byte-for-byte as read for LF and mixed files.
    public let text: String
    public let encoding: String.Encoding
    public let hasBOM: Bool
    public let lineEnding: LineEndingStyle
}

public enum TextCodecError: Error { case cannotDecode, cannotEncode }

/// File bytes <-> editor text, preserving encoding, BOM and line endings.
public enum TextCodec {
    /// Pure: nothing is committed anywhere unless the whole decode succeeds.
    public static func decode(_ data: Data) throws -> DecodedText {
        var body = data
        var encoding = String.Encoding.utf8
        var bom = false
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { bom = true; body = data.dropFirst(3) }
        else if data.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; bom = true; body = data.dropFirst(2) }
        else if data.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; bom = true; body = data.dropFirst(2) }

        var text: String
        if let s = String(data: body, encoding: encoding) { text = s }
        else if encoding == .utf8, let s = String(data: body, encoding: .isoLatin1) { text = s; encoding = .isoLatin1; bom = false }
        else { throw TextCodecError.cannotDecode }

        let style = detectLineEnding(text)
        switch style {
        case .crlf: text = text.replacing("\r\n", with: "\n")
        case .cr: text = text.replacing("\r", with: "\n")
        case .lf, .mixed: break
        }
        return DecodedText(text: text, encoding: encoding, hasBOM: bom, lineEnding: style)
    }

    public static func encode(_ text: String, encoding: String.Encoding, hasBOM: Bool, lineEnding: LineEndingStyle) throws -> Data {
        var out = text
        switch lineEnding {
        case .crlf: out = out.replacing("\n", with: "\r\n")
        case .cr: out = out.replacing("\n", with: "\r")
        case .lf, .mixed: break
        }
        guard var data = out.data(using: encoding) else { throw TextCodecError.cannotEncode }
        if hasBOM {
            // A BOM only exists for the Unicode encodings; never prepend one to Latin-1 and friends.
            switch encoding {
            case .utf8: data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
            case .utf16LittleEndian: data.insert(contentsOf: [0xFF, 0xFE], at: 0)
            case .utf16BigEndian: data.insert(contentsOf: [0xFE, 0xFF], at: 0)
            default: break
            }
        }
        return data
    }

    public static func detectLineEnding(_ s: String) -> LineEndingStyle {
        var crlf = 0, lf = 0, cr = 0
        var prev: UInt8 = 0
        for b in s.utf8 {
            if b == 0x0A { if prev == 0x0D { crlf += 1 } else { lf += 1 } }
            else if prev == 0x0D { cr += 1 }
            prev = b
        }
        if prev == 0x0D { cr += 1 }
        let kinds = [crlf, lf, cr].filter { $0 > 0 }.count
        if kinds > 1 { return .mixed }
        if crlf > 0 { return .crlf }
        if cr > 0 { return .cr }
        return .lf
    }
}
