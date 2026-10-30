import Foundation
import Testing
import CryptoKit
@testable import LibroxChapterWorker

private actor DurableDescriptorCapture {
    var value: ChapterDurableIntentDescriptor?
    func save(_ descriptor: ChapterDurableIntentDescriptor) { value = descriptor }
}
private final class DurableFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("durable-intent-" + UUID().uuidString)
    let outbox: URL, published: URL, sources: URL
    let partition = String(repeating: "a", count: 64), device = UUID()
    let gate = ChapterAccountSessionGate()
    init() throws {
        outbox = root.appendingPathComponent("Reader-Outbox"); published = root.appendingPathComponent("Reader-Authority")
        sources = root.appendingPathComponent("Reader-Sources")
        for url in [root, outbox, published, sources] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func open() async throws -> ChapterDemandOutbox {
        try await .openWithDurableAuthority(directory: outbox, authorityDirectory: published, accountPartition: partition, deviceID: device)
    }
    func request(key: String = "chapter:1") throws -> ChapterRenderRequest {
        let text = " A\r\ne\u{301}🙂\u{FFFC}終\n"
        return try .init(accountPartition: partition, source: .init(bookSHA256: String(repeating: "b", count: 64), chapterKey: key,
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), extractionRevision: "synthetic-1", utf16Length: text.utf16.count),
            recipe: .init(language: "en", stockVoiceID: "synthetic", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-inference", plannerRevision: "p",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-per-unit-1:42", watermarkRevision: "disabled-1"), delivery: .smaller)
    }
    func complete(_ store: ChapterDemandOutbox) async throws -> ChapterIntentReadSet {
        let request = try request(), session = try await gate.open(accountPartition: partition)
        let submission = try ChapterSubmission(request: request, originalText: " A\r\ne\u{301}🙂\u{FFFC}終\n", session: session)
        let source = try await ChapterLocalSource.publish(submission, gate: gate, directory: sources)
        let plan = ChapterLocalRenderPlanPublication(reference: try .init(identifier: String(repeating: "1", count: 64)),
            sourceReference: source.reference, accountPartition: partition, renderKey: try request.renderKey())
        _ = try await store.setDemand(true, for: request, source: source, renderPlan: plan)
        return try await #require(store.wantedReadSet(for: request))
    }
    func authority(_ store: ChapterDemandOutbox) async throws -> ChapterDurableIntentAuthority {
        try await .init(directory: published, descriptor: store.durableIntentDescriptor())
    }
    var journal: URL { outbox.appendingPathComponent(partition).appendingPathComponent(device.uuidString.lowercased()).appendingPathComponent("journal.json") }
    func head() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: published.appendingPathComponent("current.json"))) as? [String: Any])
    }
}
@Suite(.serialized) struct ChapterDurableIntentAuthorityTests {
    @Test func currentWantedSurvivesReaderCloseAndRecoveryWithSamePinnedIdentity() async throws {
        let f = try DurableFixture(), store = try await f.open(), readSet = try await f.complete(store), authority = try await f.authority(store)
        #expect(try await authority.validateCurrent(readSet))
        await store.close(); await f.gate.close()
        #expect(try await authority.validateCurrent(readSet)) // Reader process/gate not borrowed.
        let reopened = try await f.open()
        #expect(try await reopened.durableIntentDescriptor() == authority.descriptor)
        #expect(try await authority.validateCurrent(readSet))
        _ = try await reopened.setDemand(false, for: readSet.intent.request)
        #expect(try await !authority.validateCurrent(readSet))
        _ = try await reopened.setDemand(true, for: readSet.intent.request)
        #expect(try await !authority.validateCurrent(readSet))
        let fresh = try await #require(reopened.wantedReadSet(for: readSet.intent.request))
        #expect(try await authority.validateCurrent(fresh))
        await reopened.close()
    }
    @Test func emptyEnabledJournalPermanentlyRejectsPlainWriterAndKeepsV5() async throws {
        let f = try DurableFixture(), store = try await f.open(), descriptor = try await store.durableIntentDescriptor()
        await store.close()
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as? [String: Any])
        #expect(json["version"] as? Int == 5)
        #expect((json["entries"] as? [String: Any])?.isEmpty == true)
        #expect(throws: ChapterDurableAuthorityError.configurationRequired) {
            try ChapterDemandOutbox(directory: f.outbox, accountPartition: f.partition, deviceID: f.device)
        }
        let reopened = try await f.open()
        #expect(try await reopened.durableIntentDescriptor() == descriptor)
        _ = try await reopened.setDemand(false, for: f.request())
        await reopened.close()
        let later = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as? [String: Any])
        #expect(later["version"] as? Int == 5)
    }
    @Test(arguments: [0, 1, 2, 3]) func failureAtEveryPublicationBoundaryBlocksAndReconcilesJournal(_ stage: Int) async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        await store.failAuthorityForTesting { event in
            let position: Int
            switch event { case .afterBlocked: position = 0; case .afterJournal: position = 1; case .afterArchive: position = 2; case .afterReady: position = 3 }
            if position == stage { throw ChapterDurableAuthorityError.storage }
        }
        await #expect(throws: ChapterOutboxError.ambiguousWrite) { try await store.setDemand(false, for: value.intent.request) }
        #expect(try f.head()["ready"] as? Bool == false)
        #expect(try await !authority.validateCurrent(value))
        await #expect(throws: ChapterOutboxError.ambiguousWrite) { try await store.setDemand(true, for: value.intent.request) }
        await store.close()
        let recovered = try await f.open()
        if stage == 0 { #expect(try await authority.validateCurrent(value)) }
        else { #expect(try await recovered.wantedReadSet(for: value.intent.request) == nil); #expect(try await !authority.validateCurrent(value)) }
        await recovered.close()
    }
    @Test(arguments: [0, 1, 2, 3]) func cancellationDoesNotPreventBlockedFailureCleanup(_ stage: Int) async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        await store.failAuthorityForTesting { event in
            let position: Int
            switch event { case .afterBlocked: position = 0; case .afterJournal: position = 1; case .afterArchive: position = 2; case .afterReady: position = 3 }
            if position == stage { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let task = Task { try await store.setDemand(false, for: value.intent.request) }
        await #expect(throws: ChapterOutboxError.ambiguousWrite) { try await task.value }
        #expect(try f.head()["ready"] as? Bool == false)
        #expect(try await !authority.validateCurrent(value))
        await store.close()
        let recovered = try await f.open()
        #expect(try await authority.validateCurrent(value) == (stage == 0))
        await recovered.close()
    }
    @Test(arguments: [false, true]) func missingOrCorruptJournalBlocksInsteadOfInventingEmptyState(_ missing: Bool) async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        await store.close()
        if missing { try FileManager.default.removeItem(at: f.journal) }
        else { try Data("corrupt".utf8).write(to: f.journal) }
        await #expect(throws: ChapterOutboxError.corrupt) { try await f.open() }
        #expect(try f.head()["ready"] as? Bool == false)
        #expect(try await !authority.validateCurrent(value))
    }
    @Test func checkedLegacyJournalCannotDowngradeAnEnabledAuthority() async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        await store.close()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as? [String: Any])
        let entries = try #require(json["entries"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys, .withoutEscapingSlashes])
        json["version"] = 4; json.removeValue(forKey: "authority")
        json["checksum"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: f.journal)
        await #expect(throws: ChapterOutboxError.corrupt) { try await f.open() }
        #expect(try await !authority.validateCurrent(value))
        #expect(try f.head()["ready"] as? Bool == false)
    }
    @Test func bothLocksAndPinnedDirectoryProtectOtherPublishedChannels() async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        let before = try Data(contentsOf: f.published.appendingPathComponent("current.json"))
        await #expect(throws: ChapterOutboxError.alreadyOpen) { try await f.open() }
        let otherOutbox = f.root.appendingPathComponent("Other-Outbox"); try FileManager.default.createDirectory(at: otherOutbox, withIntermediateDirectories: false)
        await #expect(throws: ChapterDurableAuthorityError.busy) {
            try await ChapterDemandOutbox.openWithDurableAuthority(directory: otherOutbox, authorityDirectory: f.published, accountPartition: f.partition, deviceID: f.device)
        }
        #expect(try Data(contentsOf: f.published.appendingPathComponent("current.json")) == before)
        await store.close()
        let wrong = f.root.appendingPathComponent("Wrong"); try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: false)
        await #expect(throws: ChapterDurableAuthorityError.wrongDirectory) {
            try await ChapterDemandOutbox.openWithDurableAuthority(directory: f.outbox, authorityDirectory: wrong, accountPartition: f.partition, deviceID: f.device)
        }
        #expect(try await authority.validateCurrent(value))
        await #expect(throws: ChapterDurableAuthorityError.wrongDirectory) {
            try await ChapterDemandOutbox.openWithDurableAuthority(directory: otherOutbox, authorityDirectory: f.published, accountPartition: f.partition, deviceID: f.device)
        }
        #expect(try Data(contentsOf: f.published.appendingPathComponent("current.json")) == before)
    }
    @Test func sameArchiveWithNewBarrierNonceCannotPassAnInterleavedObservation() async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        let before = try f.head(), other = try f.request(key: "chapter:2")
        let result = try await authority.validateCurrent(value) { _ = try await store.setDemand(true, for: other) }
        #expect(!result)
        let after = try f.head()
        #expect(before["archive"] as? String == after["archive"] as? String)
        #expect(before["generation"] as? String != after["generation"] as? String)
        #expect(try await authority.validateCurrent(value))
        await store.close()
    }
    @Test func cancelledFactoryAfterRecoveryReturnsNoHandleAndBlocksTheHead() async throws {
        let f = try DurableFixture(), capture = DurableDescriptorCapture()
        let task = Task {
            try await ChapterDemandOutbox.openWithDurableAuthority(directory: f.outbox, authorityDirectory: f.published,
                accountPartition: f.partition, deviceID: f.device) { value in
                    await capture.save(try await value.durableIntentDescriptor())
                    withUnsafeCurrentTask { $0?.cancel() }
                }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try f.head()["ready"] as? Bool == false)
        let descriptor = try await #require(capture.value)
        let reopened = try await f.open()
        #expect(try await reopened.durableIntentDescriptor() == descriptor)
        #expect(try f.head()["ready"] as? Bool == true)
        await reopened.close()
    }
    @Test func replacedPublisherLockStopsMutationWithoutTouchingUnknownLock() async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store)
        let head = try Data(contentsOf: f.published.appendingPathComponent("current.json"))
        let path = f.published.appendingPathComponent("publisher.lock")
        try FileManager.default.removeItem(at: path)
        try Data("unknown".utf8).write(to: path)
        await #expect(throws: ChapterOutboxError.ambiguousWrite) { try await store.setDemand(false, for: value.intent.request) }
        #expect(try Data(contentsOf: f.published.appendingPathComponent("current.json")) == head)
        #expect(try Data(contentsOf: path) == Data("unknown".utf8))
        await store.close()
    }
    @Test func acknowledgementOnlySavePreservesHeadAndV5Binding() async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        let before = try Data(contentsOf: f.published.appendingPathComponent("current.json"))
        #expect(try await store.acknowledge(value.intent))
        #expect(try await store.rememberHandoff(.init(identifier: String(repeating: "2", count: 64)), for: value.intent))
        #expect(try Data(contentsOf: f.published.appendingPathComponent("current.json")) == before)
        #expect(try await authority.validateCurrent(value))
        await store.close()
        let reopened = try await f.open()
        #expect(try await authority.validateCurrent(value))
        await reopened.close()
    }
    @Test func malformedArchivePathAndDirectoryReplacementFailBeforeAuthority() async throws {
        let f = try DurableFixture(), store = try await f.open(), value = try await f.complete(store), authority = try await f.authority(store)
        await store.close()
        let path = f.published.appendingPathComponent("current.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        var json = try f.head(); json["archive"] = "../outside"
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: path)
        await #expect(throws: ChapterDurableAuthorityError.invalidRecord) { try await authority.validateCurrent(value) }
        let old = f.root.appendingPathComponent("Old-Authority"); try FileManager.default.moveItem(at: f.published, to: old)
        try FileManager.default.createDirectory(at: f.published, withIntermediateDirectories: false)
        await #expect(throws: ChapterDurableAuthorityError.wrongDirectory) { try await authority.validateCurrent(value) }
    }
}
