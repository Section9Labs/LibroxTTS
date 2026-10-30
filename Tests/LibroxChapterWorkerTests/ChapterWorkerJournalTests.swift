import Foundation
import Testing
import CryptoKit
import AVFoundation
@testable import LibroxChapterWorker

private actor WorkerPause {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; entry?.resume(); entry = nil; if !released { await withCheckedContinuation { exit = $0 } } }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; exit?.resume(); exit = nil }
}
private actor WorkerAuthorityCounter { var count = 0; func next() -> Int { count += 1; return count } }
private struct WorkerPausedAuthority: ChapterIntentAuthority {
    let base: ChapterDurableIntentAuthority, pause: WorkerPause, counter: WorkerAuthorityCounter
    let when: Int
    func validateCurrent(_ readSet: ChapterIntentReadSet) async throws -> Bool {
        if await counter.next() == when { await pause.pause() }
        return try await base.validateCurrent(readSet)
    }
}
private final class WorkerFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("worker-journal-" + UUID().uuidString)
    let readerOutbox: URL, authorityRoot: URL, sources: URL, workerState: URL, workerCustody: URL, published: URL, readerCustody: URL, incoming: URL
    let readerGate = ChapterAccountSessionGate(), workerGate = ChapterAccountSessionGate()
    let partition = String(repeating: "a", count: 64), device = UUID(), workerID = UUID()
    let text = " A🙂B \n"
    init() throws {
        readerOutbox = root.appendingPathComponent("Reader-Outbox"); authorityRoot = root.appendingPathComponent("Reader-Authority")
        sources = root.appendingPathComponent("Reader-Sources"); workerState = root.appendingPathComponent("Worker-State")
        workerCustody = root.appendingPathComponent("Worker-Custody"); published = root.appendingPathComponent("Worker-Published")
        readerCustody = root.appendingPathComponent("Reader-Custody"); incoming = root.appendingPathComponent("synthetic.wav")
        for url in [root, readerOutbox, authorityRoot, sources, workerState, workerCustody, published, readerCustody] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2401)!; buffer.frameLength = 2401
        for i in 0..<2401 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.25 }
        try autoreleasepool { let file = try AVAudioFile(forWriting: incoming, settings: format.settings); try file.write(from: buffer) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func setup() async throws -> (ChapterSubmission, ChapterDemandOutbox, ChapterIntentReadSet, ChapterDurableIntentAuthority, ChapterWorkerJournal, ChapterAccountSession) {
        let session = try await readerGate.open(accountPartition: partition)
        let request = try ChapterRenderRequest(accountPartition: partition, source: .init(bookSHA256: String(repeating: "b", count: 64),
            chapterKey: "chapter:1", textSHA256: hash(Data(text.utf8)), extractionRevision: "synthetic-1", utf16Length: text.utf16.count),
            recipe: .init(language: "en", stockVoiceID: "synthetic", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-model", plannerRevision: "p",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-per-unit-1:42", watermarkRevision: "disabled-1"))
        let submission = try ChapterSubmission(request: request, originalText: text, session: session)
        let source = try await ChapterLocalSource.publish(submission, gate: readerGate, directory: sources)
        let outbox = try await ChapterDemandOutbox.openWithDurableAuthority(directory: readerOutbox, authorityDirectory: authorityRoot,
            accountPartition: partition, deviceID: device)
        let plan = ChapterLocalRenderPlanPublication(reference: try .init(identifier: String(repeating: "1", count: 64)),
            sourceReference: source.reference, accountPartition: partition, renderKey: try request.renderKey())
        _ = try await outbox.setDemand(true, for: request, source: source, renderPlan: plan)
        let readSet = try await #require(outbox.wantedReadSet(for: request))
        let authority = try await ChapterDurableIntentAuthority(directory: authorityRoot, descriptor: outbox.durableIntentDescriptor())
        let worker = try openWorker(), own = try await workerGate.open(accountPartition: partition)
        return (submission, outbox, readSet, authority, worker, own)
    }
    func openWorker() throws -> ChapterWorkerJournal { try .init(directory: workerState, accountPartition: partition, workerID: workerID) }
    func workerArtifact(_ request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> (ChapterLocalArtifact, ChapterSubmission) {
        let bytes = try Data(contentsOf: incoming), span = ChapterTextRange(offset: 1, length: 4)
        let manifest = ChapterArtifactManifest(renderKey: try request.renderKey(), audioSHA256: hash(bytes), audioByteCount: Int64(bytes.count),
            decodedFrameCount: 2401, codecRevision: "wav-f32-1", units: [.init(source: span, fragments: [span], startFrame: 0, frameCount: 2401)])
        let artifact = try await ChapterLocalArtifact.adopt(download: incoming, request: request, manifest: manifest, originalText: text,
            session: session, gate: workerGate, storageDirectory: workerCustody)
        return (artifact, try ChapterSubmission(request: request, originalText: text, session: session))
    }
    func publishedArtifact(_ submission: ChapterSubmission, session: ChapterAccountSession) async throws -> (ChapterLocalHandoffPublication, ChapterLocalArtifact) {
        let (artifact, producer) = try await workerArtifact(submission.request, session: session)
        let receipt = try await ChapterLocalHandoff.publishVerified(artifact, submission: producer, gate: workerGate, directory: published)
        let received = try await ChapterLocalHandoff.receive(receipt.reference, submission: submission, gate: readerGate,
            directory: published, storageDirectory: readerCustody)
        return (receipt, received)
    }
    var journal: URL { workerState.appendingPathComponent(partition).appendingPathComponent(workerID.uuidString.lowercased()).appendingPathComponent("journal.json") }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

@Suite(.serialized) struct ChapterWorkerJournalTests {
    @Test func oneClaimMeasuredProgressDisableAndGenerationFences() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        await #expect(throws: ChapterWorkerJournalError.disabled) { try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate) }
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        await #expect(throws: ChapterWorkerJournalError.busy) { try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate) }
        await #expect(throws: ChapterWorkerJournalError.busy) { try await worker.close() }
        try await worker.recordProgress(.init(completedUnits: 1, totalUnits: 2), token: token, authority: authority, session: own, gate: f.workerGate)
        await #expect(throws: ChapterWorkerJournalError.corrupt) { try await worker.recordProgress(.init(completedUnits: 0, totalUnits: 2), token: token, authority: authority, session: own, gate: f.workerGate) }
        await #expect(throws: ChapterWorkerJournalError.corrupt) { try await worker.recordProgress(.init(completedUnits: 2, totalUnits: 3), token: token, authority: authority, session: own, gate: f.workerGate) }
        #expect(try await worker.validateBeforeWork(token, authority: authority, session: own, gate: f.workerGate) == readSet)
        try await worker.setClaimsEnabled(false)
        await #expect(throws: ChapterWorkerJournalError.disabled) { try await worker.validateBeforeWork(token, authority: authority, session: own, gate: f.workerGate) }
        try await worker.relinquishAfterJoining(token)
        await #expect(throws: ChapterWorkerJournalError.staleGeneration) { try await worker.validateBeforeWork(token, authority: authority, session: own, gate: f.workerGate) }
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .interrupted)
        try await worker.close(); await outbox.close()
    }
    @Test func realPublicationCheckpointDoesNotAcceptReaderDemandUntilVerifiedAdoption() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        let (artifact, producer) = try await f.workerArtifact(submission.request, session: own)
        let expected = try await worker.beginPublication(token, artifact: artifact, submission: producer, authority: authority, gate: f.workerGate)
        let receipt = try await ChapterLocalHandoff.publishVerified(artifact, submission: producer, gate: f.workerGate, directory: f.published)
        #expect(receipt.reference == expected)
        let checkpoint = try await worker.recordPublished(receipt, token: token, authority: authority, gate: f.workerGate)
        #expect(checkpoint.phase == .published && checkpoint.completedHandoff == expected)
        await #expect(throws: ChapterWorkerJournalError.busy) { try await worker.close() }
        await #expect(throws: ChapterWorkerJournalError.busy) { try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate) }
        // Only the orchestrator's explicit all-producers-joined boundary releases ownership.
        try await worker.relinquishAfterJoining(token)
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .published)
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        let received = try await ChapterLocalHandoff.receive(receipt.reference, submission: submission, gate: f.readerGate,
            directory: f.published, storageDirectory: f.readerCustody)
        let accepted = try await outbox.acceptVerifiedHandoff(received, submission: submission, readSet: readSet, gate: f.readerGate)
        #expect(accepted.reference == expected && accepted.artifact.decodedFrameCount == 2401)
        #expect(try await outbox.retainedHandoff(for: submission.request)?.recordedAtIntentRevision == readSet.intent.revision)
        #expect(try await outbox.pending() == [readSet.intent])
        #expect(try await outbox.confirmation(for: submission.request) == nil)
        try await worker.close(); await outbox.close()
    }
    @Test func cancellationBeforeAndAfterReaderAcceptanceNeverReturnsStaleArtifact() async throws {
        let f = try WorkerFixture(), (submission, outbox, old, _, worker, own) = try await f.setup()
        let (receipt, artifact) = try await f.publishedArtifact(submission, session: own)
        _ = try await outbox.setDemand(false, for: submission.request)
        await #expect(throws: ChapterLocalIntentError.staleIntent) { try await outbox.acceptVerifiedHandoff(artifact, submission: submission, readSet: old, gate: f.readerGate) }
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        _ = try await outbox.setDemand(true, for: submission.request)
        let fresh = try await #require(outbox.wantedReadSet(for: submission.request))
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await outbox.acceptVerifiedHandoff(artifact, submission: submission, readSet: fresh, gate: f.readerGate) {
                _ = try await outbox.setDemand(false, for: submission.request)
            }
        }
        let retained = try await #require(outbox.retainedHandoff(for: submission.request))
        #expect(retained.reference == receipt.reference && retained.recordedAtIntentRevision == fresh.intent.revision)
        // Explicit fresh demand may reuse the verified completed asset, not old callbacks.
        _ = try await outbox.setDemand(true, for: submission.request)
        let newest = try await #require(outbox.wantedReadSet(for: submission.request))
        #expect(try await outbox.acceptVerifiedHandoff(artifact, submission: submission, readSet: newest, gate: f.readerGate).readSet == newest)
        try await worker.close(); await outbox.close()
    }
    @Test func reopenInterruptsOldRunAndNeverResumesFromProgressAsAudio() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        try await worker.setClaimsEnabled(true)
        let old = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        try await worker.recordProgress(.init(completedUnits: 1, totalUnits: 2), token: old, authority: authority, session: own, gate: f.workerGate)
        try await worker.closeAfterJoining(old) // Simulated producer has no work/task.
        let reopened = try f.openWorker(), prior = try await #require(reopened.checkpoint(for: submission.request))
        #expect(prior.phase == .interrupted && prior.progress?.completedUnits == 1)
        #expect(prior.completedHandoff == nil)
        try await reopened.setClaimsEnabled(true)
        let next = try await reopened.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        #expect(next.runID != old.runID && next.generation > old.generation)
        #expect(try await reopened.checkpoint(for: submission.request)?.progress == nil)
        await #expect(throws: ChapterWorkerJournalError.staleGeneration) { try await reopened.relinquishAfterJoining(old) }
        try await reopened.relinquishAfterJoining(next); try await reopened.close(); await outbox.close()
    }
    @Test func ambiguousProgressWriteCanCloseAfterJoiningAndReconcileGeneration() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        await worker.failAfterNextRenameForTesting()
        await #expect(throws: ChapterWorkerJournalError.ambiguousWrite) { try await worker.recordProgress(.init(completedUnits: 1, totalUnits: 1), token: token, authority: authority, session: own, gate: f.workerGate) }
        await #expect(throws: ChapterWorkerJournalError.ambiguousWrite) { try await worker.checkpoint(for: submission.request) }
        try await worker.closeAfterJoining(token)
        let reopened = try f.openWorker()
        #expect(try await reopened.checkpoint(for: submission.request)?.progress?.completedUnits == 1)
        try await reopened.setClaimsEnabled(true)
        let newer = try await reopened.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        #expect(newer.generation > token.generation)
        try await reopened.relinquishAfterJoining(newer); try await reopened.close(); await outbox.close()
    }
    @Test func plannedPublicationRecoveryIdentitySurvivesReopenAndAnotherClaim() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        let (artifact, producer) = try await f.workerArtifact(submission.request, session: own)
        let planned = try await worker.beginPublication(token, artifact: artifact, submission: producer, authority: authority, gate: f.workerGate)
        _ = try await ChapterLocalHandoff.publishVerified(artifact, submission: producer, gate: f.workerGate, directory: f.published)
        // Simulate loss of the publication callback, after its actual file task joined.
        try await worker.closeAfterJoining(token)
        let reopened = try f.openWorker()
        #expect(try await reopened.checkpoint(for: submission.request)?.plannedHandoff == planned)
        try await reopened.setClaimsEnabled(true)
        let next = try await reopened.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        let checkpoint = try await #require(reopened.checkpoint(for: submission.request))
        #expect(checkpoint.recoveryHandoff == planned && checkpoint.completedHandoff == nil)
        // A candidate is only a lookup key; actual complete copy/decode is still required.
        let received = try await ChapterLocalHandoff.receive(planned, submission: submission, gate: f.readerGate,
            directory: f.published, storageDirectory: f.readerCustody)
        #expect(received.decodedFrameCount == 2401)
        try await reopened.relinquishAfterJoining(next); try await reopened.close(); await outbox.close()
    }
    @Test func failedAttemptRequiresNewExplicitReaderIntent() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        try await worker.relinquishAfterJoining(token, failure: .renderer)
        await #expect(throws: ChapterWorkerJournalError.retryRequired) { try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate) }
        _ = try await outbox.setDemand(false, for: submission.request); _ = try await outbox.setDemand(true, for: submission.request)
        let fresh = try await #require(outbox.wantedReadSet(for: submission.request))
        let next = try await worker.claim(fresh, authority: authority, session: own, gate: f.workerGate)
        #expect(next.generation > token.generation)
        try await worker.relinquishAfterJoining(next); try await worker.close(); await outbox.close()
    }
    @Test(arguments: [1, 2]) func disableDuringClaimAwaitReturnsNoLiveClaim(_ pauseAt: Int) async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup(), pause = WorkerPause()
        let delayed = WorkerPausedAuthority(base: authority, pause: pause, counter: WorkerAuthorityCounter(), when: pauseAt)
        try await worker.setClaimsEnabled(true)
        let task = Task { try await worker.claim(readSet, authority: delayed, session: own, gate: f.workerGate) }
        await pause.wait()
        try await worker.setClaimsEnabled(false)
        await #expect(throws: ChapterWorkerJournalError.busy) { try await worker.close() }
        await pause.open()
        await #expect(throws: ChapterWorkerJournalError.disabled) { try await task.value }
        #expect(try await worker.checkpoint(for: submission.request)?.phase != .rendering)
        try await worker.close(); await outbox.close()
    }
    @Test func newEpochRejectsLatePublicationAndReaderAcceptance() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        let (artifact, producer) = try await f.workerArtifact(submission.request, session: own)
        _ = try await worker.beginPublication(token, artifact: artifact, submission: producer, authority: authority, gate: f.workerGate)
        let receipt = try await ChapterLocalHandoff.publishVerified(artifact, submission: producer, gate: f.workerGate, directory: f.published)
        _ = try await f.workerGate.open(accountPartition: f.partition)
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await worker.recordPublished(receipt, token: token, authority: authority, gate: f.workerGate) }
        try await worker.relinquishAfterJoining(token)
        let received = try await ChapterLocalHandoff.receive(receipt.reference, submission: submission, gate: f.readerGate,
            directory: f.published, storageDirectory: f.readerCustody)
        _ = try await f.readerGate.open(accountPartition: f.partition)
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await outbox.acceptVerifiedHandoff(received, submission: submission, readSet: readSet, gate: f.readerGate) }
        try await worker.close(); await outbox.close()
    }
    @Test func oldGenerationCannotBorrowANewValidSameAccountEpoch() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        let newSession = try await f.workerGate.open(accountPartition: f.partition)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await worker.validateBeforeWork(token, authority: authority, session: newSession, gate: f.workerGate)
        }
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await worker.recordProgress(.init(completedUnits: 1, totalUnits: 1), token: token, authority: authority, session: newSession, gate: f.workerGate)
        }
        let (newArtifact, newProducer) = try await f.workerArtifact(submission.request, session: newSession)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await worker.beginPublication(token, artifact: newArtifact, submission: newProducer, authority: authority, gate: f.workerGate)
        }
        try await worker.relinquishAfterJoining(token)
        let fresh = try await worker.claim(readSet, authority: authority, session: newSession, gate: f.workerGate)
        #expect(fresh.generation > token.generation)
        try await worker.relinquishAfterJoining(fresh); try await worker.close(); await outbox.close()
    }
    @Test(arguments: [false, true]) func missingEstablishedWorkerJournalNeverResetsGeneration(_ claimed: Bool) async throws {
        let f = try WorkerFixture(), (_, outbox, readSet, authority, worker, own) = try await f.setup()
        if claimed {
            try await worker.setClaimsEnabled(true)
            let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
            try await worker.relinquishAfterJoining(token)
        }
        try await worker.close()
        let marker = f.journal.deletingLastPathComponent().appendingPathComponent("worker-established.json")
        let proof = try Data(contentsOf: marker)
        try FileManager.default.removeItem(at: f.journal)
        #expect(throws: ChapterWorkerJournalError.corrupt) { try f.openWorker() }
        #expect(!FileManager.default.fileExists(atPath: f.journal.path))
        #expect(try Data(contentsOf: marker) == proof)
        await outbox.close()
    }
    @Test func cancellationOfUnreturnedPersistedClaimReopensAsInterrupted() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup(), pause = WorkerPause()
        let delayed = WorkerPausedAuthority(base: authority, pause: pause, counter: WorkerAuthorityCounter(), when: 2)
        try await worker.setClaimsEnabled(true)
        let task = Task { try await worker.claim(readSet, authority: delayed, session: own, gate: f.workerGate) }
        await pause.wait()
        let prior = try await #require(worker.checkpoint(for: submission.request))
        task.cancel(); await pause.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await worker.close() // Token was never returned, so no producer could have started.
        let reopened = try f.openWorker()
        #expect(try await reopened.checkpoint(for: submission.request)?.phase == .interrupted)
        try await reopened.setClaimsEnabled(true)
        let next = try await reopened.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        #expect(next.generation > prior.generation)
        try await reopened.relinquishAfterJoining(next); try await reopened.close(); await outbox.close()
    }
    @Test func workerAndReaderRoleLocksAndCorruptionNeverResetState() async throws {
        let f = try WorkerFixture(), (submission, outbox, readSet, authority, worker, own) = try await f.setup()
        #expect(throws: ChapterWorkerJournalError.alreadyOpen) { try f.openWorker() }
        #expect(throws: ChapterWorkerJournalError.alreadyOpen) { try ChapterWorkerJournal(directory: f.readerOutbox, accountPartition: f.partition, workerID: f.device) }
        await outbox.close()
        #expect(throws: ChapterWorkerJournalError.corrupt) { try ChapterWorkerJournal(directory: f.readerOutbox, accountPartition: f.partition, workerID: f.device) }
        try await worker.setClaimsEnabled(true)
        let token = try await worker.claim(readSet, authority: authority, session: own, gate: f.workerGate)
        try await worker.closeAfterJoining(token)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as? [String: Any])
        var body = try #require(json["body"] as? [String: Any]); body["lastGeneration"] = 0
        let changed = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        json["body"] = body; json["checksum"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: f.journal)
        #expect(throws: ChapterWorkerJournalError.corrupt) { try f.openWorker() }
        #expect(FileManager.default.fileExists(atPath: f.journal.path))
        _ = submission
    }
}
