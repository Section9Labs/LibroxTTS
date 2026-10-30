import Foundation
import Testing
@testable import LibroxChapterWorker

private actor CurrentBookIntent {
    var value: ChapterBookDemandIntent
    init(_ value: ChapterBookDemandIntent) { self.value = value }
    func set(_ value: ChapterBookDemandIntent) { self.value = value }
    func require(_ value: ChapterBookDemandIntent) throws {
        guard self.value == value else { throw ChapterBookJournalError.staleAdmission }
    }
}
private actor ReadSetReceiptStore: ChapterCloudAssetStore {
    let root: URL
    var values: [String: (Data, Data)] = [:]
    init(root: URL) { self.root = root }
    func fetch(key: String, capture: ChapterCloudAssetCapture?) async throws -> ChapterCloudAssetSnapshot? {
        guard let data = values[key] else { return nil }
        guard let capture else { return .init(key: key, tag: "asset-tag", metadata: data.0, file: nil) }
        let path = root.appendingPathComponent(UUID().uuidString)
        try data.1.write(to: path); defer { try? FileManager.default.removeItem(at: path) }
        let file = try ChapterCloudFileCapture.capture(download: path, expectedBytes: capture.bytes, expectedSHA256: capture.sha256,
            maximum: capture.maximum, session: capture.session, storageDirectory: capture.storage, check: { try Task.checkCancellation() })
        return .init(key: key, tag: "asset-tag", metadata: data.0, file: file)
    }
    func insert(key: String, metadata: Data, asset: URL) async throws -> ChapterCloudAssetSnapshot {
        guard values[key] == nil else { throw ChapterDemandTransportError.conflict }
        values[key] = (metadata, try Data(contentsOf: asset)); return .init(key: key, tag: "asset-tag", metadata: metadata, file: nil)
    }
}
private actor AtomicBookControlStore: ChapterBookControlStore {
    var records: [String: ChapterBookControlRecord] = [:]
    var attempts = 0, commits = 0, reads = 0
    var loseAck = false, pause = false, entered = false
    var waiter: CheckedContinuation<Void, Never>?
    var inject: ChapterBookCloudDevice?
    func configure(lost: Bool = false, pause: Bool = false, inject: ChapterBookCloudDevice? = nil) {
        loseAck = lost; self.pause = pause; self.inject = inject
    }
    func release() { pause = false; waiter?.resume(); waiter = nil }
    func read(scopeID: String, deviceID: UUID) -> ChapterBookControlSnapshot {
        reads += 1
        return .init(root: records[ChapterCloudBookControlTransport.rootKey(scopeID)],
            device: records[ChapterCloudBookControlTransport.deviceKey(scopeID, deviceID)])
    }
    private func install(_ proposal: ChapterBookCloudProposal) throws -> ChapterBookControlSnapshot {
        commits += 1
        let rootKey = ChapterCloudBookControlTransport.rootKey(proposal.root.scopeID)
        let deviceKey = ChapterCloudBookControlTransport.deviceKey(proposal.device.intent.scopeID, proposal.device.intent.deviceID)
        let a = ChapterBookControlRecord(key: rootKey, type: ChapterCloudBookControlTransport.rootType, tag: "root-\(commits)",
            payload: try ChapterBookCloudControl.encode(proposal.root), lifetime: nil)
        let b = ChapterBookControlRecord(key: deviceKey, type: ChapterCloudBookControlTransport.deviceType, tag: "device-\(commits)",
            payload: try ChapterBookCloudControl.encode(proposal.device), lifetime: nil)
        records[rootKey] = a; records[deviceKey] = b; return .init(root: a, device: b)
    }
    func commit(root: Data, device: Data, snapshot: ChapterBookControlSnapshot,
                scopeID: String, deviceID: UUID, accountPartition: String) async throws -> ChapterBookControlSnapshot {
        attempts += 1; entered = true
        if pause { await withCheckedContinuation { waiter = $0 } }
        if let other = inject {
            inject = nil
            _ = try install(ChapterBookCloudControl.proposal(other, root: nil, device: nil))
        }
        let current = read(scopeID: scopeID, deviceID: deviceID)
        guard current.root?.tag == snapshot.root?.tag, current.device?.tag == snapshot.device?.tag else { throw ChapterDemandTransportError.conflict }
        let a = try ChapterBookCloudControl.decode(ChapterBookCloudRoot.self, root), b = try ChapterBookCloudControl.decode(ChapterBookCloudDevice.self, device)
        let saved = try install(.init(root: a, device: b, changed: true))
        if loseAck { loseAck = false; throw ChapterDemandTransportError.uncertain }
        return saved
    }
}
private final class BookControlFixture: Sendable {
    let root, capture: URL
    let assets: ReadSetReceiptStore
    let controls = AtomicBookControlStore()
    let partition = String(repeating: "a", count: 64)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); capture = root.appendingPathComponent("Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true); assets = ReadSetReceiptStore(root: root)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func readSet(device: UUID) throws -> ChapterBookReadSet {
        let scope = try ChapterBookPreparationScope(book: .init(bookSHA256: String(repeating: "b", count: 64), extractionRevision: "reader-1",
            chapterKeys: ["spine:0", "spine:1"]), accountPartition: partition, configuration: Data("explicit-test-policy-no-work-grant".utf8))
        return try .init(.init(scope: scope, intent: .init(scopeID: scope.identifier, accountPartition: partition, deviceID: device,
            revision: 1, wantedRevision: 1, wanted: true, priority: .init(chapterIndex: 1, sourceUTF16Offset: 0)),
            chapters: [], pending: true, confirmedServerRevision: nil))
    }
    func receipt(_ value: ChapterBookReadSet, session: ChapterAccountSession, gate: ChapterAccountSessionGate) async throws -> ChapterBookReadSetServerReceipt {
        try await ChapterCloudBookReadSetTransport(store: assets, session: session, gate: gate, captureStorage: capture).upload(value)
    }
    func transport(session: ChapterAccountSession, gate: ChapterAccountSessionGate, current: CurrentBookIntent) -> ChapterCloudBookControlTransport {
        .init(store: controls, session: session, gate: gate, requireCurrent: { try await current.require($0) })
    }
}
@Suite struct ChapterBookCloudControlTests {
    @Test func atomicMembershipPreservesOtherDevicesAndCancellationNeedsNoNewAsset() async throws {
        let f = try BookControlFixture(), gateA = ChapterAccountSessionGate(), gateB = ChapterAccountSessionGate()
        let sessionA = try await gateA.open(accountPartition: f.partition), sessionB = try await gateB.open(accountPartition: f.partition)
        let a = try f.readSet(device: UUID()), b = try f.readSet(device: UUID()), currentA = CurrentBookIntent(a.intent), currentB = CurrentBookIntent(b.intent)
        let transportA = f.transport(session: sessionA, gate: gateA, current: currentA), transportB = f.transport(session: sessionB, gate: gateB, current: currentB)
        let receiptA = try await f.receipt(a, session: sessionA, gate: gateA), receiptB = try await f.receipt(b, session: sessionB, gate: gateB)
        _ = try await transportA.publish(a, contentReceipt: receiptA)
        _ = try await transportB.publish(b, contentReceipt: receiptB)
        let cancel = ChapterBookDemandIntent(scopeID: a.intent.scopeID, accountPartition: f.partition, deviceID: a.intent.deviceID,
            revision: 2, wantedRevision: 2, wanted: false, priority: a.intent.priority)
        await currentA.set(cancel)
        let confirmed = try await transportA.cancel(cancel)
        #expect(confirmed.intent == cancel)
        let snapshot = await f.controls.read(scopeID: a.intent.scopeID, deviceID: b.intent.deviceID)
        let root = try ChapterBookCloudControl.decode(ChapterBookCloudRoot.self, #require(snapshot.root).payload)
        let memberB = try ChapterBookCloudControl.decode(ChapterBookCloudDevice.self, #require(snapshot.device).payload)
        #expect(root.members.count == 2); #expect(memberB.intent == b.intent); #expect(memberB.intent.wanted)
        let before = await f.controls.commits; _ = try await transportA.cancel(cancel)
        #expect(await f.controls.commits == before)
    }
    @Test func newMemberRacingCreationCannotBeClobberedByStaleRootSnapshot() async throws {
        let f = try BookControlFixture(), gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: f.partition)
        let a = try f.readSet(device: UUID()), b = try f.readSet(device: UUID()), current = CurrentBookIntent(a.intent)
        let receiptA = try await f.receipt(a, session: session, gate: gate), receiptB = try await f.receipt(b, session: session, gate: gate)
        await f.controls.configure(inject: .init(version: 1, intent: b.intent, readSet: receiptB.identity))
        let transport = f.transport(session: session, gate: gate, current: current)
        await #expect(throws: ChapterDemandTransportError.conflict) { try await transport.publish(a, contentReceipt: receiptA) }
        let after = await f.controls.read(scopeID: a.intent.scopeID, deviceID: b.intent.deviceID)
        #expect(try ChapterBookCloudControl.decode(ChapterBookCloudRoot.self, #require(after.root).payload).members.count == 1)
        _ = try await transport.publish(a, contentReceipt: receiptA)
        let final = await f.controls.read(scopeID: a.intent.scopeID, deviceID: b.intent.deviceID)
        #expect(try ChapterBookCloudControl.decode(ChapterBookCloudRoot.self, #require(final.root).payload).members.count == 2)
    }
    @Test func lostAtomicAckReconcilesOnceAndStaleLocalIntentGetsNoSuccessfulReceipt() async throws {
        let f = try BookControlFixture(), gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: f.partition)
        let value = try f.readSet(device: UUID()), current = CurrentBookIntent(value.intent)
        let receipt = try await f.receipt(value, session: session, gate: gate), transport = f.transport(session: session, gate: gate, current: current)
        await f.controls.configure(lost: true)
        let confirmed = try await transport.publish(value, contentReceipt: receipt)
        #expect(confirmed.intent == value.intent); #expect(await f.controls.commits == 1)
        let cancel = ChapterBookDemandIntent(scopeID: value.intent.scopeID, accountPartition: f.partition, deviceID: value.intent.deviceID,
            revision: 2, wantedRevision: 2, wanted: false, priority: value.intent.priority)
        await current.set(cancel)
        await #expect(throws: ChapterBookJournalError.staleAdmission) { try await transport.publish(value, contentReceipt: receipt) }
        #expect(await f.controls.commits == 1)
        _ = try await transport.cancel(cancel)
        #expect(await f.controls.commits == 2)
    }
    @Test func cancellationJoinsBlockedOriginalNativeStoreAndReturnsNoReceipt() async throws {
        let f = try BookControlFixture(), gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: f.partition)
        let value = try f.readSet(device: UUID()), current = CurrentBookIntent(value.intent), receipt = try await f.receipt(value, session: session, gate: gate)
        await f.controls.configure(pause: true)
        let producer = Task { try await f.transport(session: session, gate: gate, current: current).publish(value, contentReceipt: receipt) }
        for _ in 0..<1000 { if await f.controls.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await f.controls.entered); producer.cancel(); await f.controls.release()
        await #expect(throws: CancellationError.self) { try await producer.value }
    }
    @Test func newerLocalCancellationDuringCommitPreventsOldCurrentReceiptAndFencesNextWrite() async throws {
        let f = try BookControlFixture(), gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: f.partition)
        let value = try f.readSet(device: UUID()), current = CurrentBookIntent(value.intent), receipt = try await f.receipt(value, session: session, gate: gate)
        let transport = f.transport(session: session, gate: gate, current: current)
        await f.controls.configure(pause: true)
        let producer = Task { try await transport.publish(value, contentReceipt: receipt) }
        for _ in 0..<1000 { if await f.controls.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await f.controls.entered)
        let cancel = ChapterBookDemandIntent(scopeID: value.intent.scopeID, accountPartition: f.partition, deviceID: value.intent.deviceID,
            revision: 2, wantedRevision: 2, wanted: false, priority: value.intent.priority)
        await current.set(cancel); await f.controls.release()
        await #expect(throws: ChapterBookJournalError.staleAdmission) { try await producer.value }
        #expect(await f.controls.commits == 1)
        let final = try await transport.cancel(cancel)
        #expect(final.intent == cancel); #expect(await f.controls.commits == 2)
    }
    @Test func transitionRejectsRevisionRollbackParityMismatchAndInconsistentMembership() throws {
        let f = try BookControlFixture(), value = try f.readSet(device: UUID()), identity = try ChapterBookReadSetIdentity(value)
        let desired = ChapterBookCloudDevice(version: 1, intent: value.intent, readSet: identity)
        let initial = try ChapterBookCloudControl.proposal(desired, root: nil, device: nil)
        var badRoot = initial.root; badRoot.members[value.intent.deviceID.uuidString.lowercased()] = String(repeating: "0", count: 64)
        #expect(throws: ChapterDemandTransportError.inconsistentSnapshot) { try ChapterBookCloudControl.proposal(desired, root: badRoot, device: desired) }
        let badCancel = ChapterBookCloudDevice(version: 1, intent: .init(scopeID: value.intent.scopeID, accountPartition: f.partition,
            deviceID: value.intent.deviceID, revision: 2, wantedRevision: 1, wanted: false, priority: value.intent.priority), readSet: nil)
        #expect(throws: ChapterDemandTransportError.invalidRecord) { try ChapterBookCloudControl.proposal(badCancel, root: initial.root, device: desired) }
        #expect(throws: ChapterDemandTransportError.inconsistentSnapshot) { try ChapterBookCloudControl.proposal(desired, root: nil, device: desired) }
        let cancel = ChapterBookCloudDevice(version: 1, intent: .init(scopeID: value.intent.scopeID, accountPartition: f.partition,
            deviceID: value.intent.deviceID, revision: 2, wantedRevision: 2, wanted: false, priority: value.intent.priority), readSet: nil)
        let newer = try ChapterBookCloudControl.proposal(cancel, root: initial.root, device: desired)
        #expect(throws: ChapterDemandTransportError.remoteRevisionAhead) { try ChapterBookCloudControl.proposal(desired, root: newer.root, device: cancel) }
    }
    @Test func boundedMembershipNeverEvictsOtherDeviceTombstonesOrAcceptsNoncanonicalPayload() throws {
        let f = try BookControlFixture(), value = try f.readSet(device: UUID()), desired = try ChapterBookCloudDevice(version: 1,
            intent: value.intent, readSet: ChapterBookReadSetIdentity(value))
        var members: [String: String] = [:]
        for _ in 0..<ChapterBookCloudRoot.maximumDevices { members[UUID().uuidString.lowercased()] = String(repeating: "e", count: 64) }
        let root = ChapterBookCloudRoot(version: 1, accountPartition: f.partition, scopeID: value.intent.scopeID, revision: 32, members: members)
        #expect(throws: ChapterDemandTransportError.quotaExceeded) { try ChapterBookCloudControl.proposal(desired, root: root, device: nil) }
        #expect(root.members == members)
        let bytes = try ChapterBookCloudControl.encode(desired)
        #expect(throws: ChapterDemandTransportError.invalidRecord) { try ChapterBookCloudControl.decode(ChapterBookCloudDevice.self, bytes + Data([32])) }
    }
}
