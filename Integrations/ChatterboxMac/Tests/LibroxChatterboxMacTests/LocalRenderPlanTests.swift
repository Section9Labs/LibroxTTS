#if os(macOS)
import Foundation
import Testing
import CryptoKit
import LibroxChatterbox
@testable import LibroxChapterWorker
@testable import LibroxChatterboxPlanning
@testable import LibroxChatterboxMac

private struct StoragePlanBackend: ResidentChapterBackend {
    let profile = "synthetic-plan-storage"
    let modelSHA256 = String(repeating: "b", count: 64)
    let conditioningSHA256 = String(repeating: "c", count: 64)
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL,
                receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        throw ChatterboxMacRendererError.unavailable
    }
}
private actor PlanPause {
    var entered = false, released = false
    var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { exit = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; exit?.resume(); exit = nil }
}
private final class PlanStorageFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-store-" + UUID().uuidString)
    let sourceDirectory: URL, planDirectory: URL, outboxDirectory: URL, authorityDirectory: URL
    let reader = ChapterAccountSessionGate(), worker = ChapterAccountSessionGate()
    let text = "Cafe\u{301} 🐈.\r\n¡Sigue adelante!"
    init() throws {
        sourceDirectory = root.appendingPathComponent("Sources")
        planDirectory = root.appendingPathComponent("Plans")
        outboxDirectory = root.appendingPathComponent("Outbox")
        authorityDirectory = root.appendingPathComponent("Authority")
        for path in [root, sourceDirectory, planDirectory, outboxDirectory, authorityDirectory] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func values(seed: UInt64 = .max) async throws -> (ChapterSubmission, ChatterboxChapterRenderPlan, ChapterLocalSourcePublication) {
        let session = try await reader.open(accountPartition: String(repeating: "a", count: 64))
        let annotation = try ChatterboxPerformanceAnnotation(range: .init(location: 0, length: (text as NSString).length), originalText: text,
            performance: .init(delivery: .urgent, strength: .strong),
            controls: .init(exaggeration: Float(bitPattern: 0x3f666667), guidance: Float(bitPattern: 0x80000000), temperature: 0.8))
        let options = try ChatterboxChapterRenderOptions(text: text, language: "es", delivery: .smaller,
            performanceDirections: .init(source: text, annotations: [annotation], scope: .chapterV1), seed: seed)
        let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: "chapter:1",
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
            extractionRevision: "synthetic-1", utf16Length: text.utf16.count)
        let renderer = ChatterboxMacResidentRenderer(testFactory: { StoragePlanBackend() })
        _ = try await renderer.prepare()
        let binding = try await renderer.bindChapter(source: source, request: options, session: session, gate: reader)
        await renderer.shutdown()
        let published = try await ChapterLocalSource.publish(binding.submission, gate: reader, directory: sourceDirectory)
        return (binding.submission, try .init(request: options), published)
    }
    func durableStore(_ submission: ChapterSubmission, plan: ChatterboxChapterRenderPlan,
                      source: ChapterLocalSourcePublication) async throws -> ChapterDemandOutbox {
        let published = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source,
            gate: reader, directory: planDirectory)
        let store = try await ChapterDemandOutbox.openWithDurableAuthority(directory: outboxDirectory,
            authorityDirectory: authorityDirectory, accountPartition: submission.request.accountPartition, deviceID: UUID())
        _ = try await store.setDemand(true, for: submission.request, source: source, renderPlan: published)
        return store
    }
    func path(_ ref: ChapterLocalRenderPlanReference) -> URL { planDirectory.appendingPathComponent(ref.identifier + ".json") }
    func workerSubmission(_ request: ChapterRenderRequest, source: ChapterLocalSourceReference) async throws -> ChapterSubmission {
        let session = try await worker.open(accountPartition: request.accountPartition)
        return try await ChapterLocalSource.receive(source, request: request, session: session, gate: worker, directory: sourceDirectory)
    }
    func journal(_ submission: ChapterSubmission, device: UUID) -> URL {
        outboxDirectory.appendingPathComponent(submission.request.accountPartition).appendingPathComponent(device.uuidString.lowercased()).appendingPathComponent("journal.json")
    }
}
@Suite(.serialized) struct LocalRenderPlanTests {
    @Test func exactPublishedPlanReopensUnderFreshWorkerEpoch() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let first = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory)
        let second = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory)
        #expect(first.reference == second.reference)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.planDirectory.path).count == 1)
        let own = try await f.workerSubmission(submission.request, source: source.reference)
        #expect(own.session.epoch != submission.session.epoch)
        let received = try await ChatterboxLocalRenderPlan.receive(first.reference, submission: own, gate: f.worker, directory: f.planDirectory)
        #expect(received.encoded() == plan.encoded())
        let options = try received.restore(source: own.originalText)
        #expect(options.seed == .max)
        #expect(options.performanceDirections?.annotations.first?.controls?.guidance.bitPattern == 0x80000000)
        let attrs = try FileManager.default.attributesOfItem(atPath: f.path(first.reference).path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    }
    @Test func intentSourcePlanTripleSurvivesAmbiguousCommitCancelAndReopen() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values(), device = UUID()
        let published = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory)
        let store = try ChapterDemandOutbox(directory: f.outboxDirectory, accountPartition: submission.request.accountPartition, deviceID: device)
        let old = try await store.setDemand(true, for: submission.request, source: source)
        let oldJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal(submission, device: device))) as? [String: Any])
        #expect(oldJSON["version"] as? Int == 3)
        await store.failAfterNextRenameForTesting()
        await #expect(throws: ChapterOutboxError.ambiguousWrite) {
            try await store.setDemand(true, for: submission.request, source: source, renderPlan: published)
        }
        await store.close()
        let reopened = try ChapterDemandOutbox(directory: f.outboxDirectory, accountPartition: submission.request.accountPartition, deviceID: device)
        let saved = try await #require(reopened.storedSubmission(for: submission.request))
        #expect(saved.intent.revision == old.revision + 1)
        #expect(saved.sourceReference == source.reference && saved.renderPlanReference == published.reference)
        #expect(try await !reopened.acknowledge(old))
        #expect(try await reopened.setDemand(true, for: submission.request, source: source, renderPlan: published) == saved.intent)
        let cancelled = try await reopened.setDemand(false, for: submission.request)
        let retained = try await #require(reopened.storedSubmission(for: submission.request))
        #expect(retained.intent == cancelled && retained.renderPlanReference == published.reference)
        #expect(try await reopened.confirmation(for: submission.request) == nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal(submission, device: device))) as? [String: Any])
        #expect(json["version"] as? Int == 4)
        await reopened.close()
    }
    @Test func validChecksumCannotHidePlanWithoutSourceOrUnknownJournalVersion() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values(), device = UUID()
        let published = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory)
        let store = try ChapterDemandOutbox(directory: f.outboxDirectory, accountPartition: submission.request.accountPartition, deviceID: device)
        _ = try await store.setDemand(true, for: submission.request, source: source, renderPlan: published)
        await store.close()
        let path = f.journal(submission, device: device)
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        func canonical(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
        func hash(_ value: Any) throws -> String { SHA256.hash(data: try canonical(value)).map { String(format: "%02x", $0) }.joined() }
        let entries = try #require(original["entries"] as? [String: Any])
        #expect(try hash(entries) == original["checksum"] as? String)
        for missingSource in [true, false] {
            var altered = original
            if missingSource {
                var changed = entries
                let key = try submission.request.renderKey()
                var entry = try #require(changed[key] as? [String: Any])
                entry.removeValue(forKey: "sourceReference"); changed[key] = entry
                altered["entries"] = changed; altered["checksum"] = try hash(changed)
                #expect(try hash(changed) == altered["checksum"] as? String)
            } else { altered["version"] = 5 }
            try canonical(altered).write(to: path)
            #expect(throws: ChapterOutboxError.corrupt) {
                try ChapterDemandOutbox(directory: f.outboxDirectory, accountPartition: submission.request.accountPartition, deviceID: device)
            }
        }
    }
    @Test func wrongRecipeAndCrossRequestPublicationCannotAttach() async throws {
        let f = try PlanStorageFixture(), (original, plan, source) = try await f.values()
        let publication = try await ChatterboxLocalRenderPlan.publish(plan, submission: original, source: source, gate: f.reader, directory: f.planDirectory)
        let (other, _, otherSource) = try await f.values(seed: 7)
        await #expect(throws: ChatterboxChapterRenderPlanError.recipeMismatch) {
            try await ChatterboxLocalRenderPlan.publish(plan, submission: other, source: otherSource, gate: f.reader, directory: f.planDirectory)
        }
        let store = try ChapterDemandOutbox(directory: f.outboxDirectory, accountPartition: other.request.accountPartition, deviceID: UUID())
        await #expect(throws: ChapterWorkerError.invalidIdentity) {
            try await store.setDemand(true, for: other.request, source: otherSource, renderPlan: publication)
        }
        #expect(try await store.pending().isEmpty)
        let own = try await f.workerSubmission(other.request, source: otherSource.reference)
        await #expect(throws: ChatterboxChapterRenderPlanError.invalidPlan) {
            try await ChatterboxLocalRenderPlan.receive(publication.reference, submission: own, gate: f.worker, directory: f.planDirectory)
        }
        await store.close()
    }
    @Test func cancellationBeforeCommitJoinsAndPreservesUnknownFiles() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values(), pause = PlanPause()
        let sentinel = f.planDirectory.appendingPathComponent("keep"); try Data("keep".utf8).write(to: sentinel)
        let task = Task {
            try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory) { event in
                if case .beforeCommit = event { await pause.pause() }
            }
        }
        await pause.wait(); task.cancel(); await pause.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.planDirectory.path) == ["keep"])
    }
    @Test func revocationAfterCommitRetainsFileButReturnsNoPublication() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory) { event in
                if case .afterCommit = event { await f.reader.close() }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.planDirectory.path).count == 1)
    }
    @Test func corruptAndSymlinkPlanNeverYieldOptions() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let publication = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory)
        let own = try await f.workerSubmission(submission.request, source: source.reference)
        let path = f.path(publication.reference)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        try Data("bad".utf8).write(to: path)
        await #expect(throws: (any Error).self) { try await ChatterboxLocalRenderPlan.receive(publication.reference, submission: own, gate: f.worker, directory: f.planDirectory) }
        let original = f.root.appendingPathComponent("original"); try Data("do not touch".utf8).write(to: original)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
        await #expect(throws: (any Error).self) { try await ChatterboxLocalRenderPlan.receive(publication.reference, submission: own, gate: f.worker, directory: f.planDirectory) }
        #expect(try String(contentsOf: original, encoding: .utf8) == "do not touch")
    }
    @Test func receiveRevocationAfterReadRejectsAndLeavesPublishedPlan() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let publication = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission, source: source, gate: f.reader, directory: f.planDirectory)
        let own = try await f.workerSubmission(submission.request, source: source.reference)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChatterboxLocalRenderPlan.receive(publication.reference, submission: own, gate: f.worker, directory: f.planDirectory) { event in
                if case .afterRead = event { await f.worker.close() }
            }
        }
        #expect(FileManager.default.fileExists(atPath: f.path(publication.reference).path))
    }
    @Test func preparedPairRecoversExactAuthoredBitsAfterReaderReopen() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let store = try await f.durableStore(submission, plan: plan, source: source)
        let descriptor = try await store.durableIntentDescriptor()
        await store.close()
        let reopened = try await ChapterDemandOutbox.openWithDurableAuthority(directory: f.outboxDirectory,
            authorityDirectory: f.authorityDirectory, accountPartition: submission.request.accountPartition, deviceID: descriptor.deviceID)
        let session = try await f.reader.open(accountPartition: submission.request.accountPartition)
        let before = try await reopened.storedSubmission(for: submission.request)
        let recovered = try await #require(ChatterboxLocalPreparedSubmission.recover(for: submission.request,
            session: session, gate: f.reader, outbox: reopened, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory))
        #expect(recovered.submission.session == session && session.epoch != submission.session.epoch)
        #expect(Data(recovered.submission.originalText.utf8) == Data(f.text.utf8))
        #expect(recovered.plan.encoded() == plan.encoded())
        let options = try recovered.plan.restore(source: recovered.submission.originalText)
        #expect(options.seed == .max && options.delivery == .smaller)
        #expect(options.performanceDirections?.annotations.first?.controls?.guidance.bitPattern == 0x80000000)
        #expect(try await reopened.storedSubmission(for: submission.request) == before)
        #expect(try await reopened.confirmation(for: submission.request) == nil)
        await reopened.close()
    }
    @Test func cancelledPairRecoveryDoesNotRestoreDemandOrAcknowledgement() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let store = try await f.durableStore(submission, plan: plan, source: source)
        let cancelled = try await store.setDemand(false, for: submission.request)
        let before = try await store.pending()
        #expect(try await ChatterboxLocalPreparedSubmission.recover(for: submission.request,
            session: submission.session, gate: f.reader, outbox: store, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory) != nil)
        #expect(try await store.storedSubmission(for: submission.request)?.intent == cancelled)
        #expect(try await store.pending() == before)
        #expect(try await store.wantedReadSet(for: submission.request) == nil)
        #expect(try await store.retainedHandoff(for: submission.request) == nil)
        await store.close()
    }
    @Test func absentAndIncompletePairsReturnNilButPlainWriterRejects() async throws {
        let f = try PlanStorageFixture(), (submission, _, source) = try await f.values()
        let plain = try ChapterDemandOutbox(directory: f.outboxDirectory, accountPartition: submission.request.accountPartition, deviceID: UUID())
        await #expect(throws: ChapterDurableAuthorityError.configurationRequired) {
            try await ChatterboxLocalPreparedSubmission.recover(for: submission.request, session: submission.session,
                gate: f.reader, outbox: plain, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory)
        }
        await plain.close()
        let store = try await ChapterDemandOutbox.openWithDurableAuthority(directory: f.outboxDirectory,
            authorityDirectory: f.authorityDirectory, accountPartition: submission.request.accountPartition, deviceID: UUID())
        #expect(try await ChatterboxLocalPreparedSubmission.recover(for: submission.request,
            session: submission.session, gate: f.reader, outbox: store, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory) == nil)
        _ = try await store.setDemand(true, for: submission.request, source: source)
        #expect(try await ChatterboxLocalPreparedSubmission.recover(for: submission.request,
            session: submission.session, gate: f.reader, outbox: store, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory) == nil)
        await store.close()
    }
    @Test func intentChangeDuringPairRecoveryRejectsWithoutRewritingFiles() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let store = try await f.durableStore(submission, plan: plan, source: source)
        let paths = try FileManager.default.contentsOfDirectory(atPath: f.planDirectory.path)
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await ChatterboxLocalPreparedSubmission.recover(for: submission.request, session: submission.session,
                gate: f.reader, outbox: store, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory) {
                    if case .afterSource = $0 { _ = try await store.setDemand(false, for: submission.request) }
                }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.planDirectory.path) == paths)
        #expect(try await store.wantedReadSet(for: submission.request) == nil)
        await store.close()
    }
    @Test(arguments: [false, true]) func recoveryRejectsEpochRevocationOrJournalCloseAfterPlan(closeJournal: Bool) async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let store = try await f.durableStore(submission, plan: plan, source: source)
        await #expect(throws: (any Error).self) {
            try await ChatterboxLocalPreparedSubmission.recover(for: submission.request, session: submission.session,
                gate: f.reader, outbox: store, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory) {
                    if case .afterPlan = $0 {
                        if closeJournal { await store.close() } else { _ = try await f.reader.open(accountPartition: submission.request.accountPartition) }
                    }
                }
        }
        await store.close()
    }
    @Test func pairRecoveryCancellationJoinsOwnedReadsAndPreservesUnknownFiles() async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values(), pause = PlanPause()
        let store = try await f.durableStore(submission, plan: plan, source: source)
        let keep = f.planDirectory.appendingPathComponent("keep"); try Data("keep".utf8).write(to: keep)
        let task = Task {
            try await ChatterboxLocalPreparedSubmission.recover(for: submission.request, session: submission.session,
                gate: f.reader, outbox: store, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory) {
                    if case .afterSource = $0 { await pause.pause() }
                }
        }
        await pause.wait(); task.cancel()
        await pause.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try String(contentsOf: keep, encoding: .utf8) == "keep")
        #expect(try await store.wantedReadSet(for: submission.request) != nil)
        await store.close()
    }
    @Test(arguments: [false, true]) func missingOrCorruptReferencedPlanThrowsRatherThanReturningNil(corrupt: Bool) async throws {
        let f = try PlanStorageFixture(), (submission, plan, source) = try await f.values()
        let store = try await f.durableStore(submission, plan: plan, source: source)
        let stored = try await #require(store.storedSubmission(for: submission.request))
        let path = f.path(try #require(stored.renderPlanReference))
        if corrupt {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            try Data("corrupt".utf8).write(to: path)
        } else { try FileManager.default.removeItem(at: path) }
        await #expect(throws: (any Error).self) {
            try await ChatterboxLocalPreparedSubmission.recover(for: submission.request, session: submission.session,
                gate: f.reader, outbox: store, sourceDirectory: f.sourceDirectory, planDirectory: f.planDirectory)
        }
        #expect(try await store.storedSubmission(for: submission.request) == stored)
        await store.close()
    }
}
#endif
