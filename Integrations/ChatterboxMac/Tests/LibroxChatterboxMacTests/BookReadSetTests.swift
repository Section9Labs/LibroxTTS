#if os(macOS)
import Foundation
import CryptoKit
import Testing
import LibroxChatterbox
@testable import LibroxChapterWorker
@testable import LibroxChatterboxPlanning

@Suite struct BookReadSetPlanningTests {
    @Test func actualPreparedBookAndAuthoredContentRebindToReceiverWithoutLocalPathsAndAckChurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources"), plans = root.appendingPathComponent("Plans"), contentRoot = root.appendingPathComponent("Content")
        for path in [sources, plans, contentRoot] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let control = root.appendingPathComponent("Books"); try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let descriptor = try ChatterboxStockVoiceDescriptor(modelSHA256: String(repeating: "b", count: 64), conditioningSHA256: String(repeating: "c", count: 64), rendererProfile: "synthetic-readset-no-model")
        let book = try descriptor.prepareBook(source: .init(bookSHA256: String(repeating: "d", count: 64), extractionRevision: "reader-1",
            chapterKeys: ["spine:0", "spine:1", "spine:2"]), settings: .init(language: "es", delivery: .smaller,
                direction: .storyteller, grouping: .sentences, seed: .max), session: session)
        let text = "Cafe\u{301} 🐈.\r\nSigue.", directions = try ChatterboxPerformanceDirections(source: text, annotations: [
            .init(range: NSRange(location: 0, length: text.utf16.count), originalText: text,
                performance: .init(delivery: .soft, strength: .subtle), controls: .init(exaggeration: Float(bitPattern: 0x80000000), guidance: 0.3, temperature: 0.8))
        ], scope: .chapterV1)
        let entry = try book.prepareEntry(chapterIndex: 1, text: text, performanceDirections: directions, session: session)
        guard case .chapter(let pair) = entry else { Issue.record("No narrated pair"); return }
        let content = try ChatterboxBookEntryContent(book: book, chapterIndex: 1, originalText: text, entry: entry, session: session)
        let box = try ChapterBookOutbox(directory: control, accountPartition: session.accountPartition, deviceID: UUID())
        let budget = try ChapterArtifactStorageBudget(controlDirectory: contentRoot, managedDirectories: [sources, plans, contentRoot],
            policy: .init(maximumManagedBytes: 64 * 1024 * 1024, minimumAvailableBytes: 0))
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 1, sourceUTF16Offset: 0))
        _ = try await ChatterboxBookSubmissionAdmission.submit(pair, book: book, chapterIndex: 1, gate: gate, outbox: box,
            budget: budget, sourceDirectory: sources, planDirectory: plans)
        let beforeContent = try ChapterBookReadSet(#require(await box.stored(scopeID: book.scope.identifier)))
        #expect(beforeContent.entries.first?.content == nil)
        let pending = try ChatterboxPreparedBookReadSet(beforeContent, session: session)
        #expect(throws: ChapterBookJournalError.staleAdmission) { try pending.validate(content, session: session) }
        _ = try await ChatterboxLocalBookContent.persist(content, book: book, session: session, gate: gate, outbox: box,
            budget: budget, directory: contentRoot, sourceDirectory: sources, planDirectory: plans)
        let snapshot = try #require(await box.stored(scopeID: book.scope.identifier)), readSet = try ChapterBookReadSet(snapshot), bytes = try readSet.encoded()
        #expect(readSet.scope.book.chapterKeys.count == 3); #expect(readSet.entries.count == 1)
        #expect(bytes.range(of: Data(session.epoch.uuidString.utf8)) == nil)
        #expect(bytes.range(of: Data("renderPlanReference".utf8)) == nil)
        #expect(try await box.confirmContent(content.identity(), intent: snapshot.intent, serverRevision: .init(opaqueValue: "content-ack")))
        #expect(try await box.confirm(snapshot.intent, serverRevision: .init(opaqueValue: "book-ack")))
        #expect(try ChapterBookReadSet(#require(await box.stored(scopeID: book.scope.identifier))).encoded() == bytes)
        let fresh = try await gate.open(accountPartition: session.accountPartition)
        let typed = try ChatterboxPreparedBookReadSet(ChapterBookReadSetIdentity(readSet).decodeContent(bytes), session: fresh)
        let actual = try ChatterboxBookEntryContent.decode(content.encoded(), identity: content.identity(), book: typed.book, chapterIndex: 1, session: fresh)
        try typed.validate(actual, session: fresh)
        // A self-consistent immutable asset is still not semantic permission to
        // substitute another desired render key for the downloaded exact plan.
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var rows = try #require(object["entries"] as? [[String: Any]])
        rows[0]["renderKey"] = String(repeating: "e", count: 64); object["entries"] = rows
        let mismatched = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let mismatchedSHA = SHA256.hash(data: mismatched).map { String(format: "%02x", $0) }.joined()
        let wrong = try ChapterBookReadSet.decode(mismatched, expectedSHA256: mismatchedSHA, accountPartition: fresh.accountPartition,
            scopeID: book.scope.identifier, deviceID: snapshot.intent.deviceID)
        let wrongPrepared = try ChatterboxPreparedBookReadSet(wrong, session: fresh)
        #expect(throws: ChapterWorkerError.invalidIdentity) { try wrongPrepared.validate(actual, session: fresh) }
        guard case .chapter(let restored) = actual.entry else { Issue.record("Lost pair"); return }
        #expect(try restored.plan.restore(source: text).performanceDirections?.annotations.first?.controls?.exaggeration.bitPattern == 0x80000000)
        #expect(typed.book.settings.seed == .max)
        #expect(throws: (any Error).self) { try typed.validate(content, session: fresh) }
        await box.close(); try await budget.close()
    }
}
#endif
