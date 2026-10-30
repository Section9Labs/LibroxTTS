import Foundation
import Testing
import CryptoKit
@testable import LibroxChapterWorker

private actor IntentPause {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { exit = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; exit?.resume(); exit = nil }
}
private final class IntentFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("intent-snapshot-" + UUID().uuidString)
    let outboxDirectory: URL, sources: URL, published: URL
    let reader = ChapterAccountSessionGate(), worker = ChapterAccountSessionGate()
    let deviceID = UUID()
    init() throws {
        outboxDirectory = root.appendingPathComponent("Reader-Outbox")
        sources = root.appendingPathComponent("Reader-Sources"); published = root.appendingPathComponent("Reader-Published")
        for path in [root, outboxDirectory, sources, published] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func setup(complete: Bool = true) async throws -> (ChapterSubmission, ChapterDemandOutbox) {
        let text = "Cafe\u{301} 🐈.\r\n¡Sigue!", session = try await reader.open(accountPartition: String(repeating: "a", count: 64))
        let request = try ChapterRenderRequest(accountPartition: session.accountPartition,
            source: .init(bookSHA256: String(repeating: "b", count: 64), chapterKey: "chapter:1",
                textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), extractionRevision: "synthetic-1", utf16Length: text.utf16.count),
            recipe: .init(language: "es", stockVoiceID: "synthetic", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-rendering", plannerRevision: "p",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-per-unit-1:42", watermarkRevision: "disabled-1"), delivery: .smaller)
        let submission = try ChapterSubmission(request: request, originalText: text, session: session)
        let source = try await ChapterLocalSource.publish(submission, gate: reader, directory: sources)
        let outbox = try ChapterDemandOutbox(directory: outboxDirectory, accountPartition: session.accountPartition, deviceID: deviceID)
        if complete {
            // Synthetic metadata publication: this suite never loads/render options
            // or invokes a model. Actual plan custody has separate component tests.
            let plan = ChapterLocalRenderPlanPublication(reference: try .init(identifier: String(repeating: "1", count: 64)),
                sourceReference: source.reference, accountPartition: session.accountPartition, renderKey: try request.renderKey())
            _ = try await outbox.setDemand(true, for: request, source: source, renderPlan: plan)
        } else { _ = try await outbox.setDemand(true, for: request, source: source) }
        return (submission, outbox)
    }
    func authority(_ store: ChapterDemandOutbox, _ submission: ChapterSubmission) -> ChapterReaderIntentAuthority {
        .init(outbox: store, session: submission.session, gate: reader)
    }
    func publish(_ submission: ChapterSubmission, _ store: ChapterDemandOutbox) async throws -> ChapterLocalIntentPublication {
        try await ChapterLocalIntentSnapshot.publishCurrent(for: submission.request, outbox: store, session: submission.session, gate: reader, directory: published)
    }
    func receive(_ value: ChapterLocalIntentPublication, submission: ChapterSubmission, outbox: ChapterDemandOutbox) async throws -> ChapterIntentReadSet {
        let session = try await worker.open(accountPartition: submission.request.accountPartition)
        return try await ChapterLocalIntentSnapshot.receive(value.reference, request: submission.request, requestingDevice: deviceID,
            session: session, gate: worker, authority: authority(outbox, submission), directory: published)
    }
    func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: published.path) }
}

@Suite(.serialized) struct ChapterLocalIntentSnapshotTests {
    @Test func completeWantedReadSetPublishesAndFreshWorkerValidatesReadOnlyAuthority() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup()
        let readSet = try await #require(store.wantedReadSet(for: submission.request))
        #expect(try await store.validateCurrent(readSet))
        let first = try await f.publish(submission, store), second = try await f.publish(submission, store)
        #expect(first.reference == second.reference && first.readSet == readSet)
        #expect(try f.files().count == 1)
        #expect(try await f.receive(first, submission: submission, outbox: store) == readSet)
        #expect(try await store.acknowledge(readSet.intent))
        // Local delivery acknowledgement does not alter wanted authority.
        #expect(try await store.validateCurrent(readSet))
        #expect(try await store.confirmation(for: submission.request) == nil)
        await store.close()
    }
    @Test func incompleteAndCancelledIntentsNeverPublishOrAuthorizeWork() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup(complete: false)
        #expect(try await store.wantedReadSet(for: submission.request) == nil)
        await #expect(throws: ChapterLocalIntentError.incompleteIntent) { try await f.publish(submission, store) }
        #expect(try f.files().isEmpty)
        _ = try await store.setDemand(false, for: submission.request)
        await #expect(throws: ChapterLocalIntentError.incompleteIntent) { try await f.publish(submission, store) }
        await store.close()
    }
    @Test func cancellationAndRerequestNeverResurrectOldSnapshot() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup()
        let publication = try await f.publish(submission, store)
        _ = try await store.setDemand(false, for: submission.request)
        #expect(try await !store.validateCurrent(publication.readSet))
        await #expect(throws: ChapterLocalIntentError.staleIntent) { try await f.receive(publication, submission: submission, outbox: store) }
        _ = try await store.setDemand(true, for: submission.request)
        #expect(try await !store.validateCurrent(publication.readSet))
        let current = try await f.publish(submission, store)
        #expect(current.reference != publication.reference)
        #expect(current.readSet.intent.revision > publication.readSet.intent.revision)
        #expect(try await f.receive(current, submission: submission, outbox: store) == current.readSet)
        #expect(try f.files().count == 2) // Old immutable evidence is preserved.
        await store.close()
    }
    @Test func cancelledStagingIsJoinedAndCurrentIntentRaceBeforeCommitRejects() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup(), pause = IntentPause()
        let keep = f.published.appendingPathComponent("unknown"); try Data("preserve".utf8).write(to: keep)
        let work = Task {
            try await ChapterLocalIntentSnapshot.publishCurrent(for: submission.request, outbox: store,
                session: submission.session, gate: f.reader, directory: f.published) { event in
                    if case .beforeCommit = event { await pause.pause() }
                }
        }
        await pause.wait(); work.cancel(); await pause.open()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try f.files() == ["unknown"])
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await ChapterLocalIntentSnapshot.publishCurrent(for: submission.request, outbox: store,
                session: submission.session, gate: f.reader, directory: f.published) { event in
                    if case .beforeCommit = event { _ = try await store.setDemand(false, for: submission.request) }
                }
        }
        #expect(try f.files() == ["unknown"])
        await store.close()
    }
    @Test func postCommitCancellationReturnsNoReceiptAndOldFileDoesNotAuthorize() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup()
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await ChapterLocalIntentSnapshot.publishCurrent(for: submission.request, outbox: store,
                session: submission.session, gate: f.reader, directory: f.published) { event in
                    if case .afterCommit = event { _ = try await store.setDemand(false, for: submission.request) }
                }
        }
        let file = try #require(f.files().first)
        let reference = try ChapterLocalIntentReference(identifier: String(file.dropLast(5)))
        let own = try await f.worker.open(accountPartition: submission.request.accountPartition)
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await ChapterLocalIntentSnapshot.receive(reference, request: submission.request, requestingDevice: f.deviceID,
                session: own, gate: f.worker, authority: f.authority(store, submission), directory: f.published)
        }
        #expect(try f.files().count == 1)
        await store.close()
    }
    @Test func readerAndWorkerEpochsAreSeparatelyFencedAndOfflineAuthorityFailsClosed() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup(), value = try await f.publish(submission, store)
        let own = try await f.worker.open(accountPartition: submission.request.accountPartition)
        #expect(own.epoch != submission.session.epoch)
        _ = try await f.reader.open(accountPartition: submission.request.accountPartition) // A -> A revokes the old endpoint.
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterLocalIntentSnapshot.receive(value.reference, request: submission.request, requestingDevice: f.deviceID,
                session: own, gate: f.worker, authority: f.authority(store, submission), directory: f.published)
        }
        let freshReader = try await f.reader.open(accountPartition: submission.request.accountPartition)
        let authority = ChapterReaderIntentAuthority(outbox: store, session: freshReader, gate: f.reader)
        _ = try await ChapterLocalIntentSnapshot.receive(value.reference, request: submission.request, requestingDevice: f.deviceID,
            session: own, gate: f.worker, authority: authority, directory: f.published)
        await store.close()
        await #expect(throws: ChapterOutboxError.closed) {
            try await ChapterLocalIntentSnapshot.requireCurrent(value.readSet, authority: authority, session: own, gate: f.worker)
        }
    }
    @Test func wrongRequestDeviceAndPostReadRevocationFailClosed() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup(), value = try await f.publish(submission, store)
        let own = try await f.worker.open(accountPartition: submission.request.accountPartition)
        await #expect(throws: ChapterLocalIntentError.invalidRecord) {
            try await ChapterLocalIntentSnapshot.receive(value.reference, request: submission.request, requestingDevice: UUID(),
                session: own, gate: f.worker, authority: f.authority(store, submission), directory: f.published)
        }
        let other = try ChapterRenderRequest(accountPartition: submission.request.accountPartition, source: submission.request.source,
            recipe: submission.request.recipe, delivery: .lossless)
        await #expect(throws: ChapterLocalIntentError.invalidRecord) {
            try await ChapterLocalIntentSnapshot.receive(value.reference, request: other, requestingDevice: f.deviceID,
                session: own, gate: f.worker, authority: f.authority(store, submission), directory: f.published)
        }
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterLocalIntentSnapshot.receive(value.reference, request: submission.request, requestingDevice: f.deviceID,
                session: own, gate: f.worker, authority: f.authority(store, submission), directory: f.published) { event in
                    if case .afterRead = event { await f.worker.close() }
                }
        }
        await store.close()
    }
    @Test func forgedCanonicalReferenceIsRejectedByActualReaderAndReopenPreservesObservation() async throws {
        let f = try IntentFixture(), (submission, store) = try await f.setup(), value = try await f.publish(submission, store)
        let path = f.published.appendingPathComponent(value.reference.identifier + ".json")
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var readSet = try #require(payload["readSet"] as? [String: Any])
        readSet["renderPlanReference"] = ["identifier": String(repeating: "2", count: 64)]; payload["readSet"] = readSet
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let identifier = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: f.published.appendingPathComponent(identifier + ".json"))
        let own = try await f.worker.open(accountPartition: submission.request.accountPartition)
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await ChapterLocalIntentSnapshot.receive(.init(identifier: identifier), request: submission.request,
                requestingDevice: f.deviceID, session: own, gate: f.worker, authority: f.authority(store, submission), directory: f.published)
        }
        await store.close()
        let reopened = try ChapterDemandOutbox(directory: f.outboxDirectory, accountPartition: submission.request.accountPartition, deviceID: f.deviceID)
        #expect(try await reopened.wantedReadSet(for: submission.request) == value.readSet)
        #expect(try await f.receive(value, submission: submission, outbox: reopened) == value.readSet)
        await reopened.close()
    }
}
