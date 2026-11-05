import Foundation
import CryptoKit
import Testing
@testable import LibroxChapterWorker

private actor WorkMetadataStore: ChapterCloudMetadataStore {
    var records: [String: ChapterBookControlRecord] = [:]
    var sequence = 0
    var loseAck = false
    func install(_ admission: ChapterBookWorkAdmission, wanted: Bool = true) throws {
        let old = admission.readSet.intent
        let intent = ChapterBookDemandIntent(scopeID: old.scopeID, accountPartition: old.accountPartition,
            deviceID: old.deviceID, revision: old.revision + (wanted ? 0 : 1),
            wantedRevision: old.wantedRevision + (wanted ? 0 : 1), wanted: wanted, priority: old.priority)
        let device = ChapterBookCloudDevice(version: 1, intent: intent,
            readSet: wanted ? try .init(admission.readSet) : nil)
        let root = ChapterBookCloudRoot(version: 1, accountPartition: intent.accountPartition,
            scopeID: intent.scopeID, revision: intent.revision,
            members: [intent.deviceID.uuidString.lowercased(): try ChapterBookCloudControl.digest(device)])
        sequence += 1
        for (key, payload) in [(ChapterCloudBookWorkTransport.root(intent.scopeID), try ChapterBookCloudControl.encode(root)),
                               (ChapterCloudBookWorkTransport.member(intent.scopeID, intent.deviceID), try ChapterBookCloudControl.encode(device))] {
            records[key.key] = .init(key: key.key, type: key.type, tag: "\(sequence)", payload: payload, lifetime: nil)
        }
    }
    func loseNextAck() { loseAck = true }
    func fetch(_ keys: [ChapterCloudMetadataKey]) -> [String: ChapterBookControlRecord] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in records[key.key].map { (key.key, $0) } })
    }
    func save(_ writes: [ChapterCloudMetadataWrite]) throws -> [String: ChapterBookControlRecord] {
        guard writes.allSatisfy({ records[$0.key.key]?.tag == $0.expected?.tag }) else { throw ChapterDemandTransportError.conflict }
        sequence += 1
        var saved: [String: ChapterBookControlRecord] = [:]
        for write in writes {
            let record = ChapterBookControlRecord(key: write.key.key, type: write.key.type,
                tag: "\(sequence)", payload: write.payload, lifetime: nil)
            records[write.key.key] = record; saved[write.key.key] = record
        }
        if loseAck { loseAck = false; throw ChapterDemandTransportError.uncertain }
        return saved
    }
}

private func workAdmission(deviceID: UUID = UUID()) throws -> ChapterBookWorkAdmission {
    let text = "A short chapter.", partition = String(repeating: "a", count: 64)
    let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:0",
        textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
        extractionRevision: "test-source-1", utf16Length: text.utf16.count)
    let request = try ChapterRenderRequest(accountPartition: partition, source: source,
        recipe: .init(language: "en", stockVoiceID: "stock", conditioningSHA256: String(repeating: "c", count: 64),
            modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-model",
            plannerRevision: "chapterV1", expressionSHA256: String(repeating: "e", count: 64),
            synthesisOptionsSHA256: String(repeating: "f", count: 64), seedPolicy: "fixed-42", watermarkRevision: "disabled-1"))
    let scope = try ChapterBookPreparationScope(book: .init(bookSHA256: source.bookSHA256,
        extractionRevision: source.extractionRevision, chapterKeys: [source.chapterKey]), accountPartition: partition,
        configuration: Data("test-no-model".utf8))
    var chapter = ChapterBookStoredChapter(chapterIndex: 0, request: request,
        sourceReference: try .init(identifier: String(repeating: "1", count: 64)),
        renderPlanReference: try .init(identifier: String(repeating: "2", count: 64)), silentTextSHA256: nil, silentUTF16Length: nil)
    chapter.contentIdentity = try .init(accountPartition: partition, scopeID: scope.identifier,
        chapterIndex: 0, kind: .chapter, payload: Data("immutable test content".utf8))
    let intent = ChapterBookDemandIntent(scopeID: scope.identifier, accountPartition: partition,
        deviceID: deviceID, revision: 1, wantedRevision: 1, wanted: true, priority: try .init(chapterIndex: 0, sourceUTF16Offset: 0))
    let set = try ChapterBookReadSet(.init(scope: scope, intent: intent, chapters: [chapter], pending: false,
        confirmedServerRevision: try .init(opaqueValue: "test-confirmed")))
    return try .init(readSet: set, request: request, chapterIndex: 0)
}

@Suite struct ChapterCloudBookWorkTests {
    @Test func sameInstallationRecoveryFencesOldTokenAndRefusesOtherMac() async throws {
        let store = WorkMetadataStore(), admission = try workAdmission(), gate = ChapterAccountSessionGate()
        let session = try await gate.open(accountPartition: admission.request.accountPartition), owner = UUID()
        try await store.install(admission)
        let work = ChapterCloudBookWorkTransport(store: store, session: session, gate: gate)
        let old = try await work.acquire(admission, workerID: owner, runID: UUID())
        await #expect(throws: ChapterWorkerError.busy) { try await work.acquire(admission, workerID: UUID(), runID: UUID()) }
        await #expect(throws: ChapterWorkerError.busy) { try await work.resumeAfterJoin(admission, workerID: UUID(), runID: UUID()) }
        let recovered = try await work.resumeAfterJoin(admission, workerID: owner, runID: UUID())
        await #expect(throws: ChapterWorkerError.staleClaim) { try await work.requireCurrent(old, admission: admission) }
        try await work.requireCurrent(recovered, admission: admission)
        await #expect(throws: ChapterWorkerError.staleClaim) { try await work.releaseAfterJoin(old) }
        try await work.releaseAfterJoin(recovered)
        try await work.releaseAfterJoin(recovered)
    }
    @Test func cancelledDemandRejectsWorkButAllowsJoinedClaimRelease() async throws {
        let store = WorkMetadataStore(), admission = try workAdmission(), gate = ChapterAccountSessionGate()
        let session = try await gate.open(accountPartition: admission.request.accountPartition)
        try await store.install(admission)
        let work = ChapterCloudBookWorkTransport(store: store, session: session, gate: gate)
        let token = try await work.acquire(admission, workerID: UUID(), runID: UUID())
        try await store.install(admission, wanted: false)
        await #expect(throws: ChapterWorkerError.staleClaim) { try await work.requireCurrent(token, admission: admission) }
        try await work.releaseAfterJoin(token)
    }
    @Test func uncertainCommitRequiresExactReadbackAndEpochRevocationWins() async throws {
        let store = WorkMetadataStore(), admission = try workAdmission(), gate = ChapterAccountSessionGate()
        let session = try await gate.open(accountPartition: admission.request.accountPartition)
        try await store.install(admission); await store.loseNextAck()
        let work = ChapterCloudBookWorkTransport(store: store, session: session, gate: gate)
        let token = try await work.acquire(admission, workerID: UUID(), runID: UUID())
        try await work.requireCurrent(token, admission: admission)
        await gate.close()
        _ = try await gate.open(accountPartition: admission.request.accountPartition)
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await work.requireCurrent(token, admission: admission) }
    }
}
