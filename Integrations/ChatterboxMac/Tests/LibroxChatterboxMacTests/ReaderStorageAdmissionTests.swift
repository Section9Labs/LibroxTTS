#if os(macOS)
import Foundation
import Testing
import AVFoundation
import CryptoKit
import LibroxChatterbox
@testable import LibroxChapterWorker
@testable import LibroxChatterboxPlanning
@testable import LibroxChatterboxMac

private actor ReaderAdmissionPause {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; entry?.resume(); entry = nil; if !released { await withCheckedContinuation { exit = $0 } } }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; exit?.resume(); exit = nil }
}
private struct ReaderAdmissionBackend: ResidentChapterBackend {
    let profile = "synthetic-reader-storage"
    let modelSHA256 = String(repeating: "b", count: 64), conditioningSHA256 = String(repeating: "c", count: 64)
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL,
                receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        throw ChatterboxMacRendererError.unavailable
    }
}
private final class ReaderAdmissionFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-storage-" + UUID().uuidString)
    let sources, plans, outboxRoot, authorityRoot, artifacts, workerCustody, workerPublished: URL
    let reader = ChapterAccountSessionGate(), worker = ChapterAccountSessionGate()
    let text = "Cafe\u{301} 🐈.\r\n¡Sigue adelante!", partition = String(repeating: "a", count: 64)
    init() throws {
        sources = root.appendingPathComponent("Sources"); plans = root.appendingPathComponent("Plans")
        outboxRoot = root.appendingPathComponent("Outbox"); authorityRoot = root.appendingPathComponent("Authority")
        artifacts = root.appendingPathComponent("Reader-Artifacts"); workerCustody = root.appendingPathComponent("Worker-Custody")
        workerPublished = root.appendingPathComponent("Worker-Published")
        for url in [root, sources, plans, outboxRoot, authorityRoot, artifacts, workerCustody, workerPublished] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func values(maximum: UInt64 = 16 * 1024 * 1024) async throws -> (ChapterSubmission, ChatterboxChapterRenderPlan, ChapterDemandOutbox, ChapterArtifactStorageBudget) {
        let own = try await reader.open(accountPartition: partition)
        let annotation = try ChatterboxPerformanceAnnotation(range: .init(location: 0, length: text.utf16.count), originalText: text,
            performance: .init(delivery: .urgent, strength: .strong), controls: .init(exaggeration: 0.9, guidance: 0.3, temperature: 0.8))
        let options = try ChatterboxChapterRenderOptions(text: text, language: "es", delivery: .smaller,
            performanceDirections: .init(source: text, annotations: [annotation], scope: .chapterV1), seed: .max)
        let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: "chapter:1",
            textSHA256: Self.hash(Data(text.utf8)), extractionRevision: "synthetic-1", utf16Length: text.utf16.count)
        let renderer = ChatterboxMacResidentRenderer(testFactory: { ReaderAdmissionBackend() })
        _ = try await renderer.prepare()
        let binding = try await renderer.bindChapter(source: source, request: options, session: own, gate: reader)
        await renderer.shutdown()
        let outbox = try await ChapterDemandOutbox.openWithDurableAuthority(directory: outboxRoot, authorityDirectory: authorityRoot,
            accountPartition: partition, deviceID: UUID())
        let budget = try ChapterArtifactStorageBudget(controlDirectory: sources, managedDirectories: [sources, plans],
            policy: .init(maximumManagedBytes: maximum, minimumAvailableBytes: 0))
        return (binding.submission, try .init(request: options), outbox, budget)
    }
    func submit(_ s: ChapterSubmission, _ p: ChatterboxChapterRenderPlan, _ o: ChapterDemandOutbox, _ b: ChapterArtifactStorageBudget,
                checkpoint: @escaping ChatterboxLocalSubmissionAdmission.Checkpoint = { _ in }) async throws -> ChapterDemandIntent {
        try await ChatterboxLocalSubmissionAdmission.submit(p, submission: s, gate: reader, outbox: o, budget: b,
            sourceDirectory: sources, planDirectory: plans, checkpoint: checkpoint)
    }
    func publication(_ submission: ChapterSubmission) async throws -> (ChapterLocalHandoffReference, Int64) {
        let file = root.appendingPathComponent("generated-synthetic.m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2401)!; buffer.frameLength = 2401
        for i in 0..<2401 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
        // Actual AAC encode/decode solely to produce a small complete fixture.
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let data = try Data(contentsOf: file), span = ChapterTextRange(offset: 0, length: text.utf16.count)
        let manifest = ChapterArtifactManifest(renderKey: try submission.request.renderKey(), audioSHA256: Self.hash(data),
            audioByteCount: Int64(data.count), decodedFrameCount: 2401, codecRevision: "aac-lc-64k-1",
            units: [.init(source: span, fragments: [span], startFrame: 0, frameCount: 2401)])
        let own = try await worker.open(accountPartition: partition)
        let producer = try ChapterSubmission(request: submission.request, originalText: text, session: own)
        let artifact = try await ChapterLocalArtifact.adopt(download: file, request: submission.request, manifest: manifest,
            originalText: text, session: own, gate: worker, storageDirectory: workerCustody)
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: worker, directory: workerPublished)
        return (reference, Int64(data.count))
    }
    func artifactBudget(_ bytes: UInt64) throws -> ChapterArtifactStorageBudget {
        try .init(controlDirectory: artifacts, managedDirectories: [artifacts], policy: .init(maximumManagedBytes: bytes, minimumAvailableBytes: 0))
    }
    func accept(_ reference: ChapterLocalHandoffReference, _ submission: ChapterSubmission, _ readSet: ChapterIntentReadSet,
                _ outbox: ChapterDemandOutbox, _ budget: ChapterArtifactStorageBudget,
                checkpoint: @escaping ChapterReaderStorageAdmission.Checkpoint = { _ in }) async throws -> ChapterReaderArtifactAcceptance {
        try await ChapterReaderStorageAdmission.receiveAndAccept(reference, submission: submission, readSet: readSet,
            gate: reader, outbox: outbox, budget: budget, publicationDirectory: workerPublished, storageDirectory: artifacts, checkpoint: checkpoint)
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
@Suite(.serialized) struct ReaderStorageAdmissionTests {
    @Test func exactSourceExpressionsPlanAndIntentCommitAfterBudgetSettlement() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values()
        let intent = try await f.submit(s, p, o, b)
        let set = try await #require(o.wantedReadSet(for: s.request))
        #expect(intent == set.intent && intent.revision == 1)
        let own = try await f.worker.open(accountPartition: f.partition)
        let source = try await ChapterLocalSource.receive(set.sourceReference, request: s.request, session: own, gate: f.worker, directory: f.sources)
        let plan = try await ChatterboxLocalRenderPlan.receive(set.renderPlanReference, submission: source, gate: f.worker, directory: f.plans)
        #expect(Data(source.originalText.utf8) == Data(f.text.utf8) && plan.encoded() == p.encoded())
        let restored = try plan.restore(source: source.originalText)
        #expect(restored.seed == .max && restored.performanceDirections?.annotations.first?.controls?.exaggeration.bitPattern == Float(0.9).bitPattern)
        #expect(try await o.confirmation(for: s.request) == nil)
        try await b.close(); await o.close()
    }
    @Test func capacityFailureWritesNoIntentAndExhaustionCannotBlockCancellation() async throws {
        let f = try ReaderAdmissionFixture(), cap = ChatterboxLocalSubmissionAdmission.maximumPublicationGrowthBytes
        let (s, p, o, b) = try await f.values(maximum: cap)
        _ = try await f.submit(s, p, o, b)
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await f.submit(s, p, o, b) }
        let cancelled = try await o.setDemand(false, for: s.request)
        #expect(!cancelled.wanted && cancelled.revision == 2)
        #expect(try await o.storedSubmission(for: s.request)?.renderPlanReference != nil)
        try await b.close(); await o.close()
    }
    @Test func rejectedFirstPublicationAndUnmanagedDestinationsNeverAttachIntent() async throws {
        let f = try ReaderAdmissionFixture()
        let (s, p, o, b) = try await f.values(maximum: ChatterboxLocalSubmissionAdmission.maximumPublicationGrowthBytes - 1)
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await f.submit(s, p, o, b) }
        #expect(try await o.pending().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.sources.path) == ["artifact-budget.lock"])
        try await b.close()
        let onlyPlans = try ChapterArtifactStorageBudget(controlDirectory: f.plans, managedDirectories: [f.plans],
            policy: .init(maximumManagedBytes: 16 * 1024 * 1024, minimumAvailableBytes: 0))
        await #expect(throws: ChapterStorageBudgetError.invalidConfiguration) { try await f.submit(s, p, o, onlyPlans) }
        #expect(try await o.pending().isEmpty)
        try await onlyPlans.close(); await o.close()
    }
    @Test func cancellationJoinsSourceProducerAndReleasesAllowanceWithoutIntent() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values(), pause = ReaderAdmissionPause()
        let task = Task { try await f.submit(s, p, o, b) { if case .afterSource = $0 { await pause.pause() } } }
        await pause.wait(); task.cancel()
        await #expect(throws: ChapterStorageBudgetError.busy) { try await b.close() }
        await pause.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await o.pending().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.sources.path).count == 2) // lock+complete orphan
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.plans.path) == ["artifact-budget.lock"])
        try await b.close(); await o.close()
    }
    @Test func settlementFailureNeverMakesOrphanPublicationsWanted() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values(maximum: 12 * 1024 * 1024)
        let unknown = f.sources.appendingPathComponent("uncoordinated-preserved")
        await #expect(throws: ChapterStorageBudgetError.capacity) {
            try await f.submit(s, p, o, b) {
                if case .beforeSettlement = $0 { try Data(repeating: 4, count: 12 * 1024 * 1024).write(to: unknown) }
            }
        }
        #expect(try await o.pending().isEmpty)
        #expect(try Data(contentsOf: unknown).count == 12 * 1024 * 1024)
        try await b.close(); await o.close()
    }
    @Test func lostIntentAcknowledgementKeepsAuthoritativeTripleAndNoServerAck() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values()
        await #expect(throws: CancellationError.self) {
            try await f.submit(s, p, o, b) { if case .afterIntent = $0 { throw CancellationError() } }
        }
        let set = try await #require(o.wantedReadSet(for: s.request))
        #expect(set.intent.revision == 1 && set.intent.wanted)
        #expect(try await f.submit(s, p, o, b) == set.intent)
        #expect(try await o.confirmation(for: s.request) == nil)
        try await b.close(); await o.close()
    }
    @Test(arguments: [false, true]) func olderSubmissionCannotResurrectCancelledOrRerequestedIntent(_ rerequest: Bool) async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values(), pause = ReaderAdmissionPause()
        let task = Task { try await f.submit(s, p, o, b) { if case .beforeIntent = $0 { await pause.pause() } } }
        await pause.wait()
        var newer = try await o.setDemand(false, for: s.request)
        if rerequest { newer = try await o.setDemand(true, for: s.request) }
        await pause.open()
        await #expect(throws: ChapterLocalIntentError.staleIntent) { try await task.value }
        #expect(try await o.pending() == [newer])
        #expect(try await o.storedSubmission(for: s.request) == nil)
        try await b.close(); await o.close()
    }
    @Test func repeatedIdempotentCancelAlsoInvalidatesPendingAdmission() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values(), pause = ReaderAdmissionPause()
        let cancelled = try await o.setDemand(false, for: s.request)
        let task = Task { try await f.submit(s, p, o, b) { if case .beforeIntent = $0 { await pause.pause() } } }
        await pause.wait()
        #expect(try await o.setDemand(false, for: s.request) == cancelled)
        await pause.open()
        await #expect(throws: ChapterLocalIntentError.staleIntent) { try await task.value }
        #expect(try await o.pending() == [cancelled])
        try await b.close(); await o.close()
    }
    @Test func absentIntentAdmissionUsesCanonicalKeyRatherThanSwiftUnicodeEquality() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values()
        func request(_ key: String) throws -> ChapterRenderRequest {
            let original = s.request.source
            return try .init(accountPartition: s.request.accountPartition,
                source: .init(bookSHA256: original.bookSHA256, chapterKey: key, textSHA256: original.textSHA256,
                    extractionRevision: original.extractionRevision, utf16Length: original.utf16Length),
                recipe: s.request.recipe, delivery: s.request.delivery)
        }
        let nfd = try request("Cafe\u{301}"), nfc = try request("Café")
        #expect(nfd == nfc)
        #expect(try nfd.renderKey() != nfc.renderKey())
        let observation = try await o.observeAdmission(for: nfd)
        let normalized = try ChapterSubmission(request: nfc, originalText: s.originalText, session: s.session)
        let source = try await ChapterLocalSource.publish(normalized, gate: f.reader, directory: f.sources)
        let plan = try await ChatterboxLocalRenderPlan.publish(p, submission: normalized, source: source, gate: f.reader, directory: f.plans)
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await o.setDemand(true, for: nfc, source: source, renderPlan: plan, admission: observation)
        }
        #expect(try await o.pending().isEmpty)
        try await b.close(); await o.close()
    }
    @Test func exactArtifactBytesAreAdmittedThenActuallyDecodedAndAccepted() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values()
        _ = try await f.submit(s, p, o, b)
        let set = try await #require(o.wantedReadSet(for: s.request)), (reference, bytes) = try await f.publication(s)
        let tooSmall = try f.artifactBudget(UInt64(bytes - 1))
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await f.accept(reference, s, set, o, tooSmall) }
        #expect(try await o.retainedHandoff(for: s.request) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.artifacts.path) == ["artifact-budget.lock"])
        try await tooSmall.close()
        let exact = try f.artifactBudget(UInt64(bytes))
        let accepted = try await f.accept(reference, s, set, o, exact)
        #expect(accepted.reference == reference && accepted.artifact.decodedFrameCount == 2401)
        #expect(accepted.artifact.codec == .aac64 && accepted.artifact.session == s.session)
        #expect(try await exact.inventory().logicalBytes == UInt64(bytes))
        #expect(try await o.pending() == [set.intent])
        #expect(try await o.confirmation(for: s.request) == nil)
        try await exact.close(); try await b.close(); await o.close()
    }
    @Test func cancellationBeforeAcceptanceNeverRecordsStalePlayableReference() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values()
        _ = try await f.submit(s, p, o, b)
        let set = try await #require(o.wantedReadSet(for: s.request)), (reference, bytes) = try await f.publication(s)
        let budget = try f.artifactBudget(UInt64(bytes))
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await f.accept(reference, s, set, o, budget) {
                if case .beforeAcceptance = $0 { _ = try await o.setDemand(false, for: s.request) }
            }
        }
        #expect(try await o.retainedHandoff(for: s.request) == nil)
        #expect(FileManager.default.fileExists(atPath: f.workerPublished.appendingPathComponent(reference.identifier).appendingPathComponent("audio").path))
        try await budget.close(); try await b.close(); await o.close()
    }
    @Test func inspectedMetadataNeverBypassesRealAudioCopyAndDecode() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values()
        _ = try await f.submit(s, p, o, b)
        let set = try await #require(o.wantedReadSet(for: s.request)), (reference, bytes) = try await f.publication(s)
        let manifest = try await ChapterLocalHandoff.inspectManifest(reference, submission: s, gate: f.reader, directory: f.workerPublished)
        #expect(manifest.audioByteCount == bytes)
        let budget = try f.artifactBudget(UInt64(bytes))
        let audio = f.workerPublished.appendingPathComponent(reference.identifier).appendingPathComponent("audio")
        await #expect(throws: ChapterLocalArtifactError.invalidFile) {
            try await f.accept(reference, s, set, o, budget) {
                if case .beforeCopy = $0 {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
                    try Data("corrupt".utf8).write(to: audio)
                }
            }
        }
        #expect(try await o.retainedHandoff(for: s.request) == nil)
        try await budget.close(); try await b.close(); await o.close()
    }
    @Test func revocationAfterAcceptanceReturnsNoOldEpochHandleAndFreshEpochReadopts() async throws {
        let f = try ReaderAdmissionFixture(), (s, p, o, b) = try await f.values()
        _ = try await f.submit(s, p, o, b)
        let set = try await #require(o.wantedReadSet(for: s.request)), (reference, bytes) = try await f.publication(s)
        let budget = try f.artifactBudget(UInt64(bytes * 2))
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await f.accept(reference, s, set, o, budget) { if case .afterAcceptance = $0 { await f.reader.close() } }
        }
        #expect(try await o.retainedHandoff(for: s.request)?.reference == reference)
        let own = try await f.reader.open(accountPartition: f.partition)
        let fresh = try ChapterSubmission(request: s.request, originalText: s.originalText, session: own)
        let accepted = try await f.accept(reference, fresh, set, o, budget)
        #expect(accepted.artifact.session.epoch == own.epoch && own.epoch != s.session.epoch)
        try await budget.close(); try await b.close(); await o.close()
    }
}
#endif
