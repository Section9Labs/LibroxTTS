import Foundation
import CloudKit
import CryptoKit
import Synchronization

struct ChapterBookControlRecord: Sendable {
    let key, type, tag: String
    let payload: Data
    let lifetime: CKRecord?
}
struct ChapterBookControlSnapshot: Sendable {
    let root: ChapterBookControlRecord?
    let device: ChapterBookControlRecord?
}
protocol ChapterBookControlStore: Sendable {
    func read(scopeID: String, deviceID: UUID) async throws -> ChapterBookControlSnapshot
    func commit(root: Data, device: Data, snapshot: ChapterBookControlSnapshot,
                scopeID: String, deviceID: UUID, accountPartition: String) async throws -> ChapterBookControlSnapshot
}
/// This device's actual current-control acknowledgement, NEVER ready/media.
package struct ChapterBookCloudDemandReceipt: Sendable {
    package let intent: ChapterBookDemandIntent
    package let session: ChapterAccountSession
    package let revision: ChapterServerRevision
    fileprivate init(intent: ChapterBookDemandIntent, session: ChapterAccountSession, revision: ChapterServerRevision) {
        self.intent = intent; self.session = session; self.revision = revision
    }
}

/// Actual native TWO-record current device+membership CAS. No claims, catalog,
/// discovery loop, ordered segment publication or shipping factory. No zones or
/// schema are created. Parent membership prevents cooperating-device phantoms
/// only when EVERY future claimant/publication also fences this exact root.
package actor ChapterCloudBookControlTransport {
    static let rootType = "LibroxBookDemandV1", deviceType = "LibroxBookDeviceV1", payloadField = "payloadV1"
    static func rootKey(_ scope: String) -> String { "bd-" + scope }
    static func deviceKey(_ scope: String, _ device: UUID) -> String { "bi-" + scope + "-" + device.uuidString.lowercased() }
    private let store: any ChapterBookControlStore
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let authorize: @Sendable () async throws -> Void
    private let requireCurrent: @Sendable (ChapterBookDemandIntent) async throws -> Void
    private var occupied = false
    package init(container: CKContainer, account: ChapterCloudAccountIdentity, session: ChapterAccountSession,
                 gate: ChapterAccountSessionGate,
                 authorizeControlTransfer: @escaping @Sendable () async throws -> Void,
                 requireCurrent: @escaping @Sendable (ChapterBookDemandIntent) async throws -> Void) throws {
        guard container.containerIdentifier == account.containerIdentifier, account.accountPartition == session.accountPartition else {
            throw ChapterWorkerError.accountMismatch
        }
        store = NativeChapterBookControlStore(database: container.privateCloudDatabase)
        self.session = session; self.gate = gate; authorize = authorizeControlTransfer; self.requireCurrent = requireCurrent
    }
    init(store: any ChapterBookControlStore, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
         authorize: @escaping @Sendable () async throws -> Void = {},
         requireCurrent: @escaping @Sendable (ChapterBookDemandIntent) async throws -> Void) {
        self.store = store; self.session = session; self.gate = gate; self.authorize = authorize; self.requireCurrent = requireCurrent
    }
    private func valid(_ intent: ChapterBookDemandIntent) async throws {
        try Task.checkCancellation()
        guard intent.accountPartition == session.accountPartition, isDigest(intent.scopeID) else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session); try Task.checkCancellation()
        try await requireCurrent(intent)
        try await gate.validate(session); try Task.checkCancellation()
    }
    private func authorized(_ intent: ChapterBookDemandIntent) async throws {
        try await valid(intent); try await authorize(); try await valid(intent)
    }
    private func read(_ intent: ChapterBookDemandIntent) async throws -> ChapterBookControlSnapshot {
        try await authorized(intent)
        do {
            let value = try await store.read(scopeID: intent.scopeID, deviceID: intent.deviceID)
            try await valid(intent); return value
        } catch { try await valid(intent); throw error }
    }
    private static func decoded(_ snapshot: ChapterBookControlSnapshot, desired: ChapterBookCloudDevice) throws -> (ChapterBookCloudRoot?, ChapterBookCloudDevice?) {
        func check(_ record: ChapterBookControlRecord?, type: String, key: String) throws -> Data? {
            guard let record else { return nil }
            guard record.type == type, record.key == key, !record.tag.isEmpty, record.tag.utf8.count <= 1024 else {
                throw ChapterDemandTransportError.invalidRecord
            }
            return record.payload
        }
        let intent = desired.intent
        let root = try check(snapshot.root, type: rootType, key: rootKey(intent.scopeID))
            .map { try ChapterBookCloudControl.decode(ChapterBookCloudRoot.self, $0) }
        let device = try check(snapshot.device, type: deviceType, key: deviceKey(intent.scopeID, intent.deviceID))
            .map { try ChapterBookCloudControl.decode(ChapterBookCloudDevice.self, $0) }
        return (root, device)
    }
    private func receipt(_ snapshot: ChapterBookControlSnapshot, desired: ChapterBookCloudDevice) throws -> ChapterBookCloudDemandReceipt {
        let (root, device) = try Self.decoded(snapshot, desired: desired)
        let proposal = try ChapterBookCloudControl.proposal(desired, root: root, device: device)
        guard !proposal.changed, let a = snapshot.root, let b = snapshot.device else { throw ChapterDemandTransportError.conflict }
        let bytes = try JSONEncoder().encode([session.accountPartition, a.key, a.tag,
            ChapterCloudFileCapture.digest(a.payload), b.key, b.tag, ChapterCloudFileCapture.digest(b.payload)])
        return .init(intent: desired.intent, session: session, revision: try .init(opaqueValue: ChapterCloudFileCapture.digest(bytes)))
    }
    package func publish(_ readSet: ChapterBookReadSet, contentReceipt: ChapterBookReadSetServerReceipt) async throws -> ChapterBookCloudDemandReceipt {
        guard readSet.intent.wanted, contentReceipt.session == session,
              try ChapterBookReadSetIdentity(readSet) == contentReceipt.identity else { throw ChapterDemandTransportError.invalidRecord }
        return try await transfer(.init(version: 1, intent: readSet.intent, readSet: contentReceipt.identity))
    }
    /// Fast metadata cancellation: never waits for a replacement read-set asset.
    package func cancel(_ intent: ChapterBookDemandIntent) async throws -> ChapterBookCloudDemandReceipt {
        guard !intent.wanted else { throw ChapterDemandTransportError.invalidRecord }
        return try await transfer(.init(version: 1, intent: intent, readSet: nil))
    }
    private func transfer(_ desired: ChapterBookCloudDevice) async throws -> ChapterBookCloudDemandReceipt {
        try await valid(desired.intent)
        try desired.validate(account: session.accountPartition, scope: desired.intent.scopeID, device: desired.intent.deviceID)
        guard !occupied else { throw ChapterDemandTransportError.busy }; occupied = true; defer { occupied = false }
        let before = try await read(desired.intent), decoded = try Self.decoded(before, desired: desired)
        let proposal = try ChapterBookCloudControl.proposal(desired, root: decoded.0, device: decoded.1)
        if !proposal.changed { return try receipt(before, desired: desired) }
        try await authorized(desired.intent)
        do {
            let saved = try await store.commit(root: ChapterBookCloudControl.encode(proposal.root), device: ChapterBookCloudControl.encode(proposal.device),
                snapshot: before, scopeID: desired.intent.scopeID, deviceID: desired.intent.deviceID, accountPartition: session.accountPartition)
            try await valid(desired.intent); return try receipt(saved, desired: desired)
        } catch {
            try await valid(desired.intent)
            guard let failure = error as? ChapterDemandTransportError, failure == .uncertain || failure == .conflict else { throw error }
            // ONE finite lost-ack readback. Never overwrite newer intent or
            // silently retry an old write after local cancellation/supersession.
            let actual = try await read(desired.intent)
            return try receipt(actual, desired: desired)
        }
    }
}

private actor NativeChapterBookControlStore: ChapterBookControlStore {
    let database: CKDatabase
    let zone = CKRecordZone.ID(zoneName: ChapterCloudDemandTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    init(database: CKDatabase) { self.database = database }
    private func ids(_ scope: String, _ device: UUID) throws -> (CKRecord.ID, CKRecord.ID) {
        guard isDigest(scope) else { throw ChapterWorkerError.invalidIdentity }
        return (.init(recordName: ChapterCloudBookControlTransport.rootKey(scope), zoneID: zone),
                .init(recordName: ChapterCloudBookControlTransport.deviceKey(scope, device), zoneID: zone))
    }
    private nonisolated static func value(_ record: CKRecord, expected: CKRecord.ID, type: String) throws -> ChapterBookControlRecord {
        guard record.recordID == expected, record.recordType == type, let tag = record.recordChangeTag,
              !tag.isEmpty, tag.utf8.count <= 1024, let payload = record[ChapterCloudBookControlTransport.payloadField] as? Data,
              !payload.isEmpty, payload.count <= ChapterBookCloudControl.maximumPayloadBytes else { throw ChapterDemandTransportError.invalidRecord }
        return .init(key: expected.recordName, type: type, tag: tag, payload: payload, lifetime: record)
    }
    func read(scopeID: String, deviceID: UUID) async throws -> ChapterBookControlSnapshot {
        let (rootID, deviceID) = try ids(scopeID, deviceID), expected = Set([rootID, deviceID])
        let operation = CKFetchRecordsOperation(recordIDs: [rootID, deviceID]); operation.desiredKeys = [ChapterCloudBookControlTransport.payloadField]
        let results = Mutex<[CKRecord.ID: Result<ChapterBookControlRecord?, Error>]>([:])
        do {
            return try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordResultBlock = { id, result in
                    let saved: Result<ChapterBookControlRecord?, Error>
                    do {
                        guard expected.contains(id) else { throw ChapterDemandTransportError.invalidRecord }
                        switch result {
                        case .success(let record): saved = .success(try Self.value(record, expected: id,
                            type: id == rootID ? ChapterCloudBookControlTransport.rootType : ChapterCloudBookControlTransport.deviceType))
                        case .failure(let error):
                            if (error as? CKError)?.code == .unknownItem { saved = .success(nil) } else { throw error }
                        }
                    } catch { saved = .failure(error) }
                    results.withLock { $0[id] = saved }
                }
                operation.fetchRecordsResultBlock = { result in
                    let saved = results.withLock { value in let old = value; value.removeAll(); return old }
                    do {
                        for item in saved.values {
                            if case .failure(let local) = item, !(local is CKError) { throw local }
                        }
                        guard Set(saved.keys) == expected, let root = saved[rootID], let device = saved[deviceID] else { throw ChapterDemandTransportError.uncertain }
                        switch result {
                        case .success: break
                        case .failure(let error):
                            guard (error as? CKError)?.code == .partialFailure,
                                  saved.values.allSatisfy({ if case .success = $0 { return true }; return false }) else { throw error }
                        }
                        complete(.success(.init(root: try root.get(), device: try device.get())))
                    } catch { complete(.failure(error)) }
                }
            }
        } catch { throw Self.convert(error) }
    }
    func commit(root: Data, device: Data, snapshot: ChapterBookControlSnapshot,
                scopeID: String, deviceID: UUID, accountPartition: String) async throws -> ChapterBookControlSnapshot {
        let (rootID, deviceID) = try ids(scopeID, deviceID)
        func record(_ old: ChapterBookControlRecord?, id: CKRecord.ID, type: String, bytes: Data) throws -> CKRecord {
            guard bytes.count <= ChapterBookCloudControl.maximumPayloadBytes else { throw ChapterDemandTransportError.invalidRecord }
            if let old {
                guard let raw = old.lifetime, raw.recordID == id, raw.recordType == type, raw.recordChangeTag == old.tag,
                      raw[ChapterCloudBookControlTransport.payloadField] as? Data == old.payload else { throw ChapterDemandTransportError.conflict }
                return raw
            }
            return CKRecord(recordType: type, recordID: id)
        }
        let a = try record(snapshot.root, id: rootID, type: ChapterCloudBookControlTransport.rootType, bytes: root)
        let b = try record(snapshot.device, id: deviceID, type: ChapterCloudBookControlTransport.deviceType, bytes: device)
        a[ChapterCloudBookControlTransport.payloadField] = root as NSData; b[ChapterCloudBookControlTransport.payloadField] = device as NSData
        a["accountV1"] = accountPartition as NSString; a["scopeV1"] = scopeID as NSString
        let operation = CKModifyRecordsOperation(recordsToSave: [a, b], recordIDsToDelete: [])
        operation.isAtomic = true; operation.savePolicy = .ifServerRecordUnchanged
        let results = Mutex<[CKRecord.ID: Result<ChapterBookControlRecord, Error>]>([:])
        do {
            return try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordSaveBlock = { id, result in
                    let value: Result<ChapterBookControlRecord, Error>
                    do {
                        guard id == rootID || id == deviceID else { throw ChapterDemandTransportError.invalidRecord }
                        let record = try Self.value(result.get(), expected: id,
                            type: id == rootID ? ChapterCloudBookControlTransport.rootType : ChapterCloudBookControlTransport.deviceType)
                        guard record.payload == (id == rootID ? root : device) else { throw ChapterDemandTransportError.invalidRecord }
                        value = .success(record)
                    } catch { value = .failure(error) }
                    results.withLock { $0[id] = value }
                }
                operation.modifyRecordsResultBlock = { result in
                    let saved = results.withLock { value in let old = value; value.removeAll(); return old }
                    do {
                        for item in saved.values {
                            if case .failure(let local) = item, !(local is CKError) { throw local }
                        }
                        try result.get()
                        guard Set(saved.keys) == Set([rootID, deviceID]), let a = saved[rootID], let b = saved[deviceID] else { throw ChapterDemandTransportError.uncertain }
                        let rootValue = try a.get(), deviceValue = try b.get()
                        guard rootValue.payload == root, deviceValue.payload == device else { throw ChapterDemandTransportError.uncertain }
                        complete(.success(.init(root: rootValue, device: deviceValue)))
                    } catch { complete(.failure(error)) }
                }
            }
        } catch { throw Self.convert(error) }
    }
    private static func convert(_ error: Error) -> Error {
        if error is CKError { return ChapterCloudDemandTransport.classify(error) }; return error
    }
}
