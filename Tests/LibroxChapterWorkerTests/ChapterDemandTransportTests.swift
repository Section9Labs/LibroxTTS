import Foundation
import Testing
import CloudKit
@testable import LibroxChapterWorker

private func transportRequest() throws -> ChapterRenderRequest {
    try .init(accountPartition: String(repeating: "a", count: 64),
        source: .init(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:7",
            textSHA256: String(repeating: "c", count: 64), extractionRevision: "epub-1", utf16Length: 40),
        recipe: .init(language: "es", stockVoiceID: "stock", conditioningSHA256: String(repeating: "d", count: 64),
            modelSHA256: String(repeating: "e", count: 64), rendererProfile: "native-standard",
            plannerRevision: "chapter-1", expressionSHA256: String(repeating: "f", count: 64),
            synthesisOptionsSHA256: String(repeating: "9", count: 64), seedPolicy: "fixed42", watermarkRevision: "disabled-1"))
}
private func transportDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

/// Explicit test-only atomic CAS store. This does not qualify CloudKit behavior.
private actor DemandCASFake: ChapterDemandTransport {
    private var queues: [String: ChapterRemoteQueueIntent] = [:]
    private var demands: [String: ChapterRemoteDemand] = [:]
    private var failingKey: String?
    private var version = 0
    private var snapshots: [UUID: Int] = [:]
    private var conflicts = 0, loseAck = false
    private var beforeCommit: (@Sendable () async throws -> Void)?
    private(set) var commits = 0
    func faults(conflicts: Int = 0, loseAck: Bool = false,
                beforeCommit: (@Sendable () async throws -> Void)? = nil) {
        self.conflicts = conflicts; self.loseAck = loseAck; self.beforeCommit = beforeCommit
    }
    func read(_ intent: ChapterDemandIntent, session: ChapterAccountSession) throws -> ChapterDemandSnapshot {
        let token = UUID(); snapshots[token] = version
        let key = try intent.request.renderKey()
        return .init(token: token, demand: demands[key + intent.deviceID.uuidString], queue: queues[key])
    }
    func commit(_ proposal: ChapterDemandProposal, snapshot: ChapterDemandSnapshot,
                session: ChapterAccountSession) async throws -> ChapterServerRevision {
        commits += 1
        let hook = beforeCommit; beforeCommit = nil; try await hook?()
        guard snapshots.removeValue(forKey: snapshot.token) == version else { throw ChapterDemandTransportError.conflict }
        if conflicts > 0 { conflicts -= 1; throw ChapterDemandTransportError.conflict }
        let key = try proposal.queue.request.renderKey()
        if key == failingKey { throw ChapterDemandTransportError.configurationUnavailable }
        demands[key + proposal.demand.intent.deviceID.uuidString] = proposal.demand; queues[key] = proposal.queue; version += 1
        if loseAck { loseAck = false; throw ChapterDemandTransportError.uncertain }
        return try .init(opaqueValue: "fake-version-\(version)")
    }
    func discard(_ snapshot: ChapterDemandSnapshot) { snapshots.removeValue(forKey: snapshot.token) }
    func state() -> ChapterRemoteQueueIntent? { queues.values.first }
    func failRequest(_ request: ChapterRenderRequest) throws { failingKey = try request.renderKey() }
    func seed(_ intent: ChapterDemandIntent) throws {
        let key = try intent.request.renderKey()
        queues[key] = .init(version: 1, request: intent.request, revision: 1,
            activeDevices: intent.wanted ? [intent.deviceID.uuidString.lowercased(): intent.revision] : [:])
        demands[key + intent.deviceID.uuidString] = .init(version: 1, intent: intent, acceptedQueueRevision: 1)
    }
}

@Test func demandLostAcknowledgementReconcilesWithoutDuplicateIntentRevision() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition)
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: UUID())
    _ = try await outbox.setDemand(true, for: request)
    let store = DemandCASFake(); await store.faults(loseAck: true)
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    let receipts = try await client.flush(session: session)
    #expect(receipts.count == 1)
    #expect(try await outbox.pending().isEmpty)
    #expect(await store.commits == 2)
    #expect(await store.state()?.revision == 1)
    await outbox.close()
}

@Test func demandConditionalRetryPreservesOtherDeviceWhenFirstCancels() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition), a = UUID(), b = UUID()
    let first = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: a)
    let second = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: b)
    let store = DemandCASFake(); await store.faults(conflicts: 1)
    let ca = ChapterDemandReconciler(outbox: first, transport: store, gate: gate)
    let cb = ChapterDemandReconciler(outbox: second, transport: store, gate: gate)
    _ = try await first.setDemand(true, for: request); _ = try await ca.flush(session: session)
    _ = try await second.setDemand(true, for: request); _ = try await cb.flush(session: session)
    _ = try await first.setDemand(false, for: request); _ = try await ca.flush(session: session)
    let state = await store.state()
    #expect(state?.activeDevices == [b.uuidString.lowercased(): 1])
    #expect(state?.revision == 3)
    await first.close(); await second.close()
}

@Test func demandLateCommitCannotAcknowledgeNewerLocalCancellation() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition)
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: UUID())
    _ = try await outbox.setDemand(true, for: request)
    let store = DemandCASFake(); await store.faults(beforeCommit: { _ = try await outbox.setDemand(false, for: request) })
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    #expect(try await client.flush(session: session).isEmpty)
    let pending = try await outbox.pending()
    #expect(pending.count == 1 && pending[0].revision == 2 && !pending[0].wanted)
    #expect(try await client.flush(session: session).count == 1)
    #expect(await store.state()?.activeDevices.isEmpty == true)
    await outbox.close()
}

@Test func demandAccountRevocationAndRetryLimitPreservePendingIntent() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition)
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: UUID())
    _ = try await outbox.setDemand(true, for: request)
    let store = DemandCASFake(); await store.faults(conflicts: 5)
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    do { _ = try await client.flush(session: session); Issue.record("Exceeded finite retries") }
    catch { #expect(error as? ChapterDemandTransportError == .retryLimit) }
    #expect(await store.commits == 3)
    #expect(try await outbox.pending().count == 1)
    await store.faults(beforeCommit: { await gate.close() })
    do { _ = try await client.flush(session: session); Issue.record("Accepted revoked callback") }
    catch { #expect(error as? ChapterWorkerError == .accountMismatch) }
    #expect(try await outbox.pending().count == 1)
    await outbox.close()
}

@Test func demandRemoteRevisionAheadNeverResetsLocalCounterOrOverwritesServer() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition), device = UUID()
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: device)
    _ = try await outbox.setDemand(true, for: request)
    let store = DemandCASFake()
    try await store.seed(.init(request: request, deviceID: device, revision: 3, wanted: false))
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    do { _ = try await client.flush(session: session); Issue.record("Accepted remote revision regression") }
    catch { #expect(error as? ChapterDemandTransportError == .remoteRevisionAhead) }
    #expect(await store.commits == 0)
    #expect(try await outbox.pending().first?.revision == 1)
    await outbox.close()
}

@Test func cloudAccountPartitionSeparatesContainerEnvironmentAndUser() throws {
    let a = try ChapterCloudAccountIdentity(containerIdentifier: "iCloud.example.reader", environment: .development, userRecordName: "test-user-a")
    #expect(a == (try .init(containerIdentifier: "iCloud.example.reader", environment: .development, userRecordName: "test-user-a")))
    let variants = [a,
        try .init(containerIdentifier: "iCloud.example.reader", environment: .production, userRecordName: "test-user-a"),
        try .init(containerIdentifier: "iCloud.example.other", environment: .development, userRecordName: "test-user-a"),
        try .init(containerIdentifier: "iCloud.example.reader", environment: .development, userRecordName: "test-user-b")]
    #expect(Set(variants.map(\.accountPartition)).count == 4)
    #expect(variants.allSatisfy { isDigest($0.accountPartition) })
    #expect(throws: ChapterWorkerError.invalidIdentity) {
        try ChapterCloudAccountIdentity(containerIdentifier: "not-a-container", environment: .development, userRecordName: "user")
    }
    #expect(throws: ChapterWorkerError.invalidIdentity) {
        try ChapterCloudAccountIdentity(containerIdentifier: "iCloud.example.reader", environment: .development, userRecordName: "user\nother")
    }
}

@Test func demandReceiptCanAcknowledgeCancellationWhileOtherDeviceJobRemainsQueued() throws {
    let request = try transportRequest(), session = ChapterAccountSession(accountPartition: request.accountPartition, epoch: UUID())
    let receipt = try ChapterDemandReceipt(request: request, session: session, deviceID: UUID(),
        intentRevision: 2, wanted: false, delivery: .acknowledged(serverRevision: .init(opaqueValue: "test-version")))
    let update = try ChapterServiceUpdate(request: request, session: session, sequence: 3, state: .queued, demandReceipt: receipt)
    #expect(update.demandReceipt == receipt)
    if case .queued = update.state {} else { Issue.record("Global state was inferred from device cancellation") }
    let later = try ChapterServiceUpdate(request: request, session: session, sequence: 4, state: .rendering(nil), demandReceipt: receipt)
    #expect(later.demandReceipt == receipt)
}

@Test func demandReceiptUpdateRejectsOtherRequestOrEpoch() throws {
    let request = try transportRequest(), session = ChapterAccountSession(accountPartition: request.accountPartition, epoch: UUID())
    let otherSession = ChapterAccountSession(accountPartition: request.accountPartition, epoch: UUID())
    let stale = try ChapterDemandReceipt(request: request, session: otherSession, deviceID: UUID(),
        intentRevision: 1, wanted: true, delivery: .localIntent)
    #expect(throws: ChapterServiceError.invalidUpdate) {
        try ChapterServiceUpdate(request: request, session: session, sequence: 1, state: .queued, demandReceipt: stale)
    }
    let other = try ChapterRenderRequest(accountPartition: request.accountPartition,
        source: .init(bookSHA256: request.source.bookSHA256, chapterKey: "different-spine",
            textSHA256: request.source.textSHA256, extractionRevision: "epub-1", utf16Length: 40), recipe: request.recipe)
    let foreign = try ChapterDemandReceipt(request: other, session: session, deviceID: UUID(),
        intentRevision: 1, wanted: true, delivery: .localIntent)
    #expect(throws: ChapterServiceError.invalidUpdate) {
        try ChapterServiceUpdate(request: request, session: session, sequence: 1, state: .queued, demandReceipt: foreign)
    }
}

@Test func demandCloudPermanentErrorsAreNotTreatedAsBlindRetryableConflicts() {
    func error(_ code: CKError.Code) -> NSError { .init(domain: CKErrorDomain, code: code.rawValue) }
    #expect(ChapterCloudDemandTransport.classify(error(.notAuthenticated)) == .accountUnavailable)
    #expect(ChapterCloudDemandTransport.classify(error(.permissionFailure)) == .accountUnavailable)
    #expect(ChapterCloudDemandTransport.classify(error(.missingEntitlement)) == .configurationUnavailable)
    #expect(ChapterCloudDemandTransport.classify(error(.zoneNotFound)) == .configurationUnavailable)
    #expect(ChapterCloudDemandTransport.classify(error(.quotaExceeded)) == .quotaExceeded)
    #expect(ChapterCloudDemandTransport.classify(error(.serverRecordChanged)) == .conflict)
    #expect(ChapterCloudDemandTransport.classify(error(.networkFailure)) == .uncertain)
    #expect(ChapterCloudDemandTransport.classify(error(.networkUnavailable)) == .offline)
    #expect(ChapterCloudDemandTransport.classify(error(.operationCancelled)) == .operationCancelled)
    #expect(ChapterCloudDemandTransport.classify(error(.requestRateLimited)) == .retryAfter(seconds: 60))
    let throttled = NSError(domain: CKErrorDomain, code: CKError.Code.requestRateLimited.rawValue,
                           userInfo: [CKErrorRetryAfterKey: NSNumber(value: 120)])
    #expect(ChapterCloudDemandTransport.classify(throttled) == .retryAfter(seconds: 120))
}

@Test func demandCancelledCallerCannotAdoptEvenIfServerCommitted() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition)
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: UUID())
    _ = try await outbox.setDemand(true, for: request)
    let store = DemandCASFake()
    await store.faults(beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    let task = Task { try await client.flush(session: session) }
    do { _ = try await task.value; Issue.record("Adopted cancelled result") }
    catch { #expect(error is CancellationError) }
    #expect(await store.state()?.revision == 1)
    #expect(try await outbox.pending().count == 1)
    #expect(try await client.flush(session: session).count == 1)
    #expect(await store.state()?.revision == 1)
    await outbox.close()
}

@Test func demandSameRevisionDifferentValueIsRejectedWithoutOverwrite() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition), device = UUID()
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: device)
    _ = try await outbox.setDemand(true, for: request)
    let store = DemandCASFake(); try await store.seed(.init(request: request, deviceID: device, revision: 1, wanted: false))
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    do { _ = try await client.flush(session: session); Issue.record("Overwrote equivocating revision") }
    catch { #expect(error as? ChapterDemandTransportError == .invalidRecord) }
    #expect(await store.commits == 0)
    #expect(try await outbox.pending().first?.wanted == true)
    await outbox.close()
}

@Test func demandEarlierConfirmationSurvivesLaterBatchFailureAndProcessReopen() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate(), device = UUID()
    defer { try? FileManager.default.removeItem(at: root) }
    let other = try ChapterRenderRequest(accountPartition: request.accountPartition,
        source: .init(bookSHA256: request.source.bookSHA256, chapterKey: "second-spine", textSHA256: request.source.textSHA256,
                      extractionRevision: "epub-1", utf16Length: 40), recipe: request.recipe)
    let ordered = try [request, other].sorted { try $0.renderKey() < $1.renderKey() }
    let a = ordered[0], b = ordered[1], session = try await gate.open(accountPartition: request.accountPartition)
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: device)
    _ = try await outbox.setDemand(false, for: a); _ = try await outbox.setDemand(true, for: b)
    let store = DemandCASFake(); try await store.failRequest(b)
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    do { _ = try await client.flush(session: session); Issue.record("Expected second intent failure") }
    catch { #expect(error as? ChapterDemandTransportError == .configurationUnavailable) }
    #expect(try await outbox.pending().map(\.request) == [b])
    let receipt = try #require(await client.confirmedReceipt(for: a, session: session))
    #expect(!receipt.wanted && receipt.deviceID == device)
    await outbox.close(); await gate.close()
    let freshSession = try await gate.open(accountPartition: request.accountPartition)
    let reopened = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: device)
    let fresh = ChapterDemandReconciler(outbox: reopened, transport: store, gate: gate)
    let replayed = try #require(await fresh.confirmedReceipt(for: a, session: freshSession))
    #expect(replayed.session == freshSession && replayed.delivery == receipt.delivery && !replayed.wanted)
    #expect(await store.commits == 2) // replay is local; no new remote write
    await reopened.close()
}

@Test func demandCancellationAfterDurableConfirmationDoesNotLoseReceipt() async throws {
    let root = try transportDirectory(), request = try transportRequest(), gate = ChapterAccountSessionGate()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await gate.open(accountPartition: request.accountPartition)
    let outbox = try ChapterDemandOutbox(directory: root, accountPartition: request.accountPartition, deviceID: UUID())
    _ = try await outbox.setDemand(false, for: request)
    await outbox.cancelAfterNextRenameForTesting()
    let store = DemandCASFake()
    let client = ChapterDemandReconciler(outbox: outbox, transport: store, gate: gate)
    let task = Task { try await client.flush(session: session) }
    do { _ = try await task.value; Issue.record("Expected cancellation after journal commit") }
    catch { #expect(error is CancellationError) }
    #expect(try await outbox.pending().isEmpty)
    let receipt = try #require(await client.confirmedReceipt(for: request, session: session))
    #expect(!receipt.wanted)
    await outbox.close()
}

@Test func demandNestedCloudFailureRetainsPermanentErrorsAndLongestRetryAfter() {
    func error(_ code: CKError.Code, after: Double? = nil) -> NSError {
        .init(domain: CKErrorDomain, code: code.rawValue, userInfo: after.map { [CKErrorRetryAfterKey: NSNumber(value: $0)] } ?? [:])
    }
    func batch(_ first: NSError, _ second: NSError) -> NSError {
        let zone = CKRecordZone.ID(zoneName: "offline-test-only", ownerName: CKCurrentUserDefaultName)
        let d = CKRecord.ID(recordName: "test-demand", zoneID: zone)
        let q = CKRecord.ID(recordName: "test-intent", zoneID: zone)
        return .init(domain: CKErrorDomain, code: CKError.Code.partialFailure.rawValue,
              userInfo: [CKPartialErrorsByItemIDKey: [d: first, q: second]])
    }
    #expect(ChapterCloudDemandTransport.classify(batch(error(.batchRequestFailed), error(.notAuthenticated))) == .accountUnavailable)
    #expect(ChapterCloudDemandTransport.classify(batch(error(.serverRecordChanged), error(.quotaExceeded))) == .quotaExceeded)
    #expect(ChapterCloudDemandTransport.classify(batch(error(.batchRequestFailed), error(.requestRateLimited, after: 7200))) == .retryAfter(seconds: 7200))
    #expect(ChapterCloudDemandTransport.classify(batch(error(.requestRateLimited, after: 120), error(.zoneBusy, after: 180))) == .retryAfter(seconds: 180))
}
