import Foundation
import Testing
import CryptoKit
import Darwin
@testable import LibroxChapterWorker

private actor SourcePause {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { exit = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; exit?.resume(); exit = nil }
}
private final class SourceFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-source-" + UUID().uuidString)
    let sources: URL, outbox: URL
    let reader = ChapterAccountSessionGate(), worker = ChapterAccountSessionGate()
    init() throws {
        sources = root.appendingPathComponent("Reader-Sources"); outbox = root.appendingPathComponent("Reader-Outbox")
        for path in [root, sources, outbox] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func submission(_ text: String = " A\r\ne\u{301}🙂\u{FFFC}\u{0000}終\n", key: String = "chapter:1", delivery: ChapterAudioDelivery = .smaller) async throws -> ChapterSubmission {
        let session = try await reader.open(accountPartition: String(repeating: "a", count: 64))
        let request = try ChapterRenderRequest(accountPartition: session.accountPartition, source: .init(
            bookSHA256: String(repeating: "b", count: 64), chapterKey: key,
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            extractionRevision: "synthetic-reader-1", utf16Length: text.utf16.count), recipe: .init(
                language: "en", stockVoiceID: "synthetic", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-inference", plannerRevision: "p",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-1", watermarkRevision: "disabled-1"), delivery: delivery)
        return try .init(request: request, originalText: text, session: session)
    }
    func receiver(_ request: ChapterRenderRequest) async throws -> ChapterAccountSession { try await worker.open(accountPartition: request.accountPartition) }
    func file(_ reference: ChapterLocalSourceReference) -> URL { sources.appendingPathComponent(reference.identifier + ".json") }
    func children(_ directory: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
}

@Suite(.serialized) struct ChapterLocalSourceTests {
    @Test func durableUnicodeSourceReopensWithWorkerEpochAndOriginalBytes() async throws {
        let f = try SourceFixture(), text = String(repeating: " A\r\ne\u{301}🙂\u{FFFC}\u{0000}終\n", count: 4500)
        let submission = try await f.submission(text)
        #expect(text.utf8.count > 65536)
        let published = try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources)
        #expect(try ChapterLocalSource.contentReference(for: submission) == published.reference)
        let session = try await f.receiver(submission.request)
        #expect(session.epoch != submission.session.epoch)
        let received = try await ChapterLocalSource.receive(published.reference, request: submission.request,
            session: session, gate: f.worker, directory: f.sources)
        #expect(received.session == session)
        #expect(Data(received.originalText.utf8) == Data(text.utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: f.file(published.reference).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    }
    @Test func sourcePublicationIsIndependentOfDeliveryAndIdempotent() async throws {
        let f = try SourceFixture(), a = try await f.submission(delivery: .smaller)
        let first = try await ChapterLocalSource.publish(a, gate: f.reader, directory: f.sources)
        let b = try await f.submission(delivery: .lossless)
        let second = try await ChapterLocalSource.publish(b, gate: f.reader, directory: f.sources)
        #expect(first.reference == second.reference)
        #expect(try f.children(f.sources).count == 1)
    }
    @Test func sourceAndIntentCommitTogetherThenSurviveCancelAndReopen() async throws {
        let f = try SourceFixture(), submission = try await f.submission(), device = UUID()
        let source = try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources)
        let store = try ChapterDemandOutbox(directory: f.outbox, accountPartition: submission.request.accountPartition, deviceID: device)
        let first = try await store.setDemand(true, for: submission.request, source: source)
        #expect(try await store.setDemand(true, for: submission.request, source: source) == first)
        #expect(try await store.pending() == [first]); #expect(try await store.confirmation(for: submission.request) == nil)
        let cancelled = try await store.setDemand(false, for: submission.request)
        await store.close()
        let reopened = try ChapterDemandOutbox(directory: f.outbox, accountPartition: submission.request.accountPartition, deviceID: device)
        let saved = try await #require(reopened.storedSubmission(for: submission.request))
        #expect(saved.intent == cancelled && saved.sourceReference == source.reference)
        #expect(!saved.intent.wanted)
        let session = try await f.receiver(submission.request)
        let received = try await ChapterLocalSource.receive(saved.sourceReference, request: saved.intent.request,
            session: session, gate: f.worker, directory: f.sources)
        #expect(Data(received.originalText.utf8) == Data(submission.originalText.utf8))
        let file = f.outbox.appendingPathComponent(submission.request.accountPartition).appendingPathComponent(device.uuidString.lowercased()).appendingPathComponent("journal.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((json["version"] as? Int) == 3)
        await reopened.close()
    }
    @Test func attachingSourceToOlderIntentAdvancesRevisionAndRejectsLateAck() async throws {
        let f = try SourceFixture(), submission = try await f.submission()
        let source = try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources)
        let store = try ChapterDemandOutbox(directory: f.outbox, accountPartition: submission.request.accountPartition, deviceID: UUID())
        let old = try await store.setDemand(true, for: submission.request)
        #expect(try await store.storedSubmission(for: submission.request) == nil)
        let new = try await store.setDemand(true, for: submission.request, source: source)
        #expect(new.revision == old.revision + 1)
        #expect(try await !store.acknowledge(old)); #expect(try await store.pending() == [new])
        await store.close()
    }
    @Test func ambiguousJournalCommitRetainsWholeSourceIntentPair() async throws {
        let f = try SourceFixture(), submission = try await f.submission(), device = UUID()
        let source = try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources)
        let store = try ChapterDemandOutbox(directory: f.outbox, accountPartition: submission.request.accountPartition, deviceID: device)
        _ = try await store.setDemand(true, for: submission.request)
        await store.failAfterNextRenameForTesting()
        await #expect(throws: ChapterOutboxError.ambiguousWrite) { try await store.setDemand(true, for: submission.request, source: source) }
        await store.close()
        let reopened = try ChapterDemandOutbox(directory: f.outbox, accountPartition: submission.request.accountPartition, deviceID: device)
        let recovered = try await #require(reopened.storedSubmission(for: submission.request))
        #expect(recovered.intent.revision == 2 && recovered.sourceReference == source.reference)
        await reopened.close()
    }
    @Test func wrongSourceIdentityCannotBeRecordedOrRead() async throws {
        let f = try SourceFixture(), original = try await f.submission()
        let source = try await ChapterLocalSource.publish(original, gate: f.reader, directory: f.sources)
        let other = try await f.submission(key: "another-chapter")
        let store = try ChapterDemandOutbox(directory: f.outbox, accountPartition: original.request.accountPartition, deviceID: UUID())
        await #expect(throws: ChapterWorkerError.invalidIdentity) { try await store.setDemand(true, for: other.request, source: source) }
        #expect(try await store.pending().isEmpty)
        let session = try await f.receiver(other.request)
        await #expect(throws: ChapterLocalSourceError.invalidRecord) {
            try await ChapterLocalSource.receive(source.reference, request: other.request, session: session, gate: f.worker, directory: f.sources)
        }
        await store.close()
    }
    @Test func cancelledStagingIsJoinedAndDoesNotTouchUnknownFiles() async throws {
        let f = try SourceFixture(), submission = try await f.submission(), pause = SourcePause()
        let sentinel = f.sources.appendingPathComponent("unknown"); try Data("preserve".utf8).write(to: sentinel)
        let work = Task {
            try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources) { event in
                if case .beforeCommit = event { await pause.pause() }
            }
        }
        await pause.wait(); work.cancel(); await pause.open()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try f.children(f.sources).map(\.lastPathComponent) == ["unknown"])
        #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
    }
    @Test func lateRevocationPreservesCommittedSourceButReturnsNoPublication() async throws {
        let f = try SourceFixture(), submission = try await f.submission()
        let reference = try ChapterLocalSource.contentReference(for: submission)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources) { event in
                if case .afterCommit = event { await f.reader.close() }
            }
        }
        #expect(FileManager.default.fileExists(atPath: f.file(reference).path))
        let session = try await f.receiver(submission.request)
        let received = try await ChapterLocalSource.receive(reference, request: submission.request, session: session, gate: f.worker, directory: f.sources)
        #expect(Data(received.originalText.utf8) == Data(submission.originalText.utf8))
    }
    @Test func receiverRevocationAfterReadReturnsNoSubmission() async throws {
        let f = try SourceFixture(), submission = try await f.submission()
        let source = try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources)
        let session = try await f.receiver(submission.request)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterLocalSource.receive(source.reference, request: submission.request, session: session, gate: f.worker, directory: f.sources) { event in
                if case .afterRead = event { await f.worker.close() }
            }
        }
    }
    @Test func corruptExistingPayloadIsRejectedAndNeverReplaced() async throws {
        let f = try SourceFixture(), submission = try await f.submission()
        let source = try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources), file = f.file(source.reference)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var bytes = try Data(contentsOf: file); bytes[bytes.count / 2] ^= 1; try bytes.write(to: file)
        await #expect(throws: ChapterLocalSourceError.invalidRecord) { try await ChapterLocalSource.publish(submission, gate: f.reader, directory: f.sources) }
        let session = try await f.receiver(submission.request)
        await #expect(throws: ChapterLocalSourceError.invalidRecord) {
            try await ChapterLocalSource.receive(source.reference, request: submission.request, session: session, gate: f.worker, directory: f.sources)
        }
        #expect(try Data(contentsOf: file) == bytes)
    }
    @Test func sourceBoundsAndFIFOsRejectBeforeUnboundedReads() async throws {
        let f = try SourceFixture(), tooLong = try await f.submission(String(repeating: "a", count: 131073))
        await #expect(throws: ChapterLocalSourceError.budget) { try await ChapterLocalSource.publish(tooLong, gate: f.reader, directory: f.sources) }
        let submission = try await f.submission(), reference = try ChapterLocalSource.contentReference(for: submission)
        #expect(mkfifo(f.file(reference).path, 0o600) == 0)
        let session = try await f.receiver(submission.request)
        await #expect(throws: ChapterLocalSourceError.invalidRecord) {
            try await ChapterLocalSource.receive(reference, request: submission.request, session: session, gate: f.worker, directory: f.sources)
        }
    }
    @Test func canonicallyEqualButByteDifferentSourceKeysDoNotMatch() async throws {
        let f = try SourceFixture(), nfd = try await f.submission(key: "cafe\u{301}"), nfc = try await f.submission(key: "café")
        let current = try ChapterSubmission(request: nfd.request, originalText: nfd.originalText, session: nfc.session)
        let source = try await ChapterLocalSource.publish(current, gate: f.reader, directory: f.sources)
        #expect(current.request.source == nfc.request.source) // Swift String equality alone is insufficient.
        let store = try ChapterDemandOutbox(directory: f.outbox, accountPartition: current.request.accountPartition, deviceID: UUID())
        await #expect(throws: ChapterWorkerError.invalidIdentity) { try await store.setDemand(true, for: nfc.request, source: source) }
        #expect(try await store.pending().isEmpty)
        await store.close()
    }
}
