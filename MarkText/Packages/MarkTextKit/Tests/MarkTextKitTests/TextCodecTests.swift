import Testing
import Foundation
@testable import MarkTextKit

@Suite("Text codec")
struct TextCodecTests {
    private func roundTrip(_ bytes: [UInt8]) throws -> (DecodedText, Data) {
        let d = try TextCodec.decode(Data(bytes))
        return (d, try TextCodec.encode(d.text, encoding: d.encoding, hasBOM: d.hasBOM, lineEnding: d.lineEnding))
    }

    @Test func uniformCRLFNormalisesAndRestores() throws {
        let src = Array("a\r\nb\r\n\r\nc".utf8)
        let (d, out) = try roundTrip(src)
        #expect(d.lineEnding == .crlf)
        #expect(d.text == "a\nb\n\nc")
        #expect(Array(out) == src)
    }

    @Test func uniformCRNormalisesAndRestores() throws {
        let src = Array("a\rb\rc".utf8)
        let (d, out) = try roundTrip(src)
        #expect(d.lineEnding == .cr && d.text == "a\nb\nc")
        #expect(Array(out) == src)
    }

    @Test func mixedIsLeftExactlyAlone() throws {
        let src = Array("a\r\nb\nc\rd\n".utf8)
        let (d, out) = try roundTrip(src)
        #expect(d.lineEnding == .mixed)
        #expect(d.text == "a\r\nb\nc\rd\n")
        #expect(Array(out) == src)
    }

    @Test func editedLineInCRLFFileKeepsCRLF() throws {
        let d = try TextCodec.decode(Data("one\r\ntwo\r\n".utf8))
        let out = try TextCodec.encode(d.text + "three\n", encoding: d.encoding, hasBOM: d.hasBOM, lineEnding: d.lineEnding)
        #expect(String(decoding: out, as: UTF8.self) == "one\r\ntwo\r\nthree\r\n")
    }

    @Test func utf8BOMRoundTrips() throws {
        let src: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("héllo\n".utf8)
        let (d, out) = try roundTrip(src)
        #expect(d.hasBOM && d.encoding == .utf8 && d.text == "héllo\n")
        #expect(Array(out) == src)
    }

    @Test func utf16LittleEndianBOMRoundTrips() throws {
        var src: [UInt8] = [0xFF, 0xFE]
        for u in "hi\n".utf16 { src += [UInt8(u & 0xFF), UInt8(u >> 8)] }
        let (d, out) = try roundTrip(src)
        #expect(d.encoding == .utf16LittleEndian && d.text == "hi\n")
        #expect(Array(out) == src)
    }

    @Test func latin1FallbackNeverGainsABOM() throws {
        let src: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A]   // "café\n", invalid UTF-8
        let (d, out) = try roundTrip(src)
        #expect(d.encoding == .isoLatin1 && !d.hasBOM && d.text == "café\n")
        #expect(Array(out) == src)
        let forced = try TextCodec.encode("x", encoding: .isoLatin1, hasBOM: true, lineEnding: .lf)
        #expect(Array(forced) == [0x78])
    }

    @Test func unencodableTextThrows() {
        #expect(throws: TextCodecError.self) { try TextCodec.encode("😀", encoding: .isoLatin1, hasBOM: false, lineEnding: .lf) }
    }
}

@Suite("Local link policy")
struct LocalLinkPolicyTests {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "mt-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func revealsDirectoriesAppsAndScripts() throws {
        let d = try temp(); defer { try? FileManager.default.removeItem(at: d) }
        let app = d.appending(path: "Thing.app"); try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let sh = d.appending(path: "run.sh"); try "#!/bin/sh\necho hi\n".write(to: sh, atomically: true, encoding: .utf8)
        let command = d.appending(path: "x.command"); try "echo".write(to: command, atomically: true, encoding: .utf8)
        #expect(LocalLinkPolicy.shouldRevealInsteadOfOpen(d))
        #expect(LocalLinkPolicy.shouldRevealInsteadOfOpen(app))
        #expect(LocalLinkPolicy.shouldRevealInsteadOfOpen(sh))
        #expect(LocalLinkPolicy.shouldRevealInsteadOfOpen(command))
    }

    @Test func plainDocumentsStillOpen() throws {
        let d = try temp(); defer { try? FileManager.default.removeItem(at: d) }
        let png = d.appending(path: "a.png"); try Data([0x89, 0x50]).write(to: png)
        let txt = d.appending(path: "a.txt"); try "hi".write(to: txt, atomically: true, encoding: .utf8)
        #expect(!LocalLinkPolicy.shouldRevealInsteadOfOpen(png))
        #expect(!LocalLinkPolicy.shouldRevealInsteadOfOpen(txt))
    }
}
