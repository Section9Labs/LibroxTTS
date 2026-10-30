#if os(macOS)
import Foundation
import CryptoKit
import Testing
import LibroxChapterWorker
import LibroxChatterbox
@testable import LibroxChatterboxPlanning

@Suite struct BookEntryContentTests {
    private func book(_ session: ChapterAccountSession) throws -> ChatterboxPreparedBookSubmission {
        try ChatterboxStockVoiceDescriptor(modelSHA256: String(repeating: "b", count: 64),
            conditioningSHA256: String(repeating: "c", count: 64), rendererProfile: "synthetic-content-no-model")
            .prepareBook(source: .init(bookSHA256: String(repeating: "d", count: 64), extractionRevision: "reader-1",
                chapterKeys: ["spine:0", "spine:1"]), settings: .init(language: "es", delivery: .smaller,
                direction: .storyteller, grouping: .sentences, seed: .max), session: session)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    @Test func exactContentRetainsUnicodeControlBitsSeedAndReceiverEpochWithoutPathsOrConditioning() async throws {
        let gate = ChapterAccountSessionGate(), sender = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let book = try book(sender), text = "Cafe\u{301} 🐈.\r\nSigue.\u{0}"
        let range = (text as NSString).range(of: "Cafe\u{301} 🐈.")
        let directions = try ChatterboxPerformanceDirections(source: text, annotations: [
            .init(range: range, originalText: (text as NSString).substring(with: range), performance: .init(delivery: .soft, strength: .subtle),
                controls: .init(exaggeration: Float(bitPattern: 0x80000000), guidance: Float(bitPattern: 0x3e99999a), temperature: 0.8))
        ], scope: .chapterV1)
        let entry = try book.prepareEntry(chapterIndex: 1, text: text, performanceDirections: directions, session: sender)
        let content = try ChatterboxBookEntryContent(book: book, chapterIndex: 1, originalText: text, entry: entry, session: sender)
        let bytes = try content.encoded(), identity = try content.identity()
        #expect(bytes.range(of: Data(sender.epoch.uuidString.utf8)) == nil)
        #expect(identity.kind == .chapter); #expect(try identity.key() == "be-" + digest(identity.encoded()))
        let receiver = try await gate.open(accountPartition: sender.accountPartition)
        let restored = try ChatterboxBookEntryContent.decode(bytes, identity: identity, book: book, chapterIndex: 1, session: receiver)
        #expect(Data(restored.originalText.utf8) == Data(text.utf8))
        guard case .chapter(let pair) = restored.entry else { Issue.record("Lost source/plan"); return }
        #expect(pair.submission.session == receiver); #expect(pair.submission.session != sender)
        let options = try pair.plan.restore(source: text)
        #expect(options.seed == .max); #expect(options.delivery == .smaller)
        #expect(options.performanceDirections?.annotations.first?.controls?.exaggeration.bitPattern == 0x80000000)
        #expect(try restored.encoded() == bytes)
    }
    @Test func literalSilentTextCrossesAsExactBytesAndCannotBecomeCopyrightOrZeroFrameAudio() async throws {
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let book = try book(session)
        for text in ["", "\u{FFFC}\r\n\t ", "\u{2003}"] {
            let entry = try book.prepareEntry(chapterIndex: 0, text: text, session: session)
            let content = try ChatterboxBookEntryContent(book: book, chapterIndex: 0, originalText: text, entry: entry, session: session)
            let bytes = try content.encoded(), identity = try content.identity()
            #expect(identity.kind == .silent)
            let received = try ChatterboxBookEntryContent.decode(bytes, identity: identity, book: book, chapterIndex: 0, session: session)
            guard case .silent(let proof) = received.entry else { Issue.record("Invented silent audio"); continue }
            try proof.validate(text: text)
            #expect(throws: (any Error).self) { try ChatterboxBookEntryContent(book: book, chapterIndex: 0,
                originalText: "Copyright 1900.", entry: entry, session: session) }
            var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            object["originalText"] = "Copyright 1900."
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            #expect(throws: (any Error).self) { try ChatterboxBookEntryContent.decode(changed, expectedSHA256: digest(changed), book: book, chapterIndex: 0, session: session) }
        }
    }
    @Test func canonicalBindingsRejectWrongSpineAccountKindPayloadAndSwiftEquivalentSource() async throws {
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64)), book = try book(session)
        let text = "Cafe\u{301}.", entry = try book.prepareEntry(chapterIndex: 1, text: text, session: session)
        let content = try ChatterboxBookEntryContent(book: book, chapterIndex: 1, originalText: text, entry: entry, session: session)
        let bytes = try content.encoded(), identity = try content.identity()
        #expect(throws: (any Error).self) { try ChatterboxBookEntryContent.decode(bytes, identity: identity, book: book, chapterIndex: 0, session: session) }
        let foreign = try await gate.open(accountPartition: String(repeating: "e", count: 64))
        #expect(throws: (any Error).self) { try ChatterboxBookEntryContent.decode(bytes, identity: identity, book: book, chapterIndex: 1, session: foreign) }
        let wrongKind = try ChapterBookEntryContentIdentity(accountPartition: session.accountPartition, scopeID: book.scope.identifier,
            chapterIndex: 1, kind: .silent, payload: bytes)
        #expect(throws: (any Error).self) { try ChatterboxBookEntryContent.decode(bytes, identity: wrongKind, book: book, chapterIndex: 1, session: session) }
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); object["originalText"] = "Café."
        let aliased = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(throws: (any Error).self) { try ChatterboxBookEntryContent.decode(aliased, expectedSHA256: digest(aliased), book: book, chapterIndex: 1, session: session) }
        let padded = bytes + Data(" ".utf8)
        #expect(throws: (any Error).self) { try ChatterboxBookEntryContent.decode(padded, expectedSHA256: digest(padded), book: book, chapterIndex: 1, session: session) }
    }
}
#endif
