import Foundation
import CryptoKit
import CloudKit
import Synchronization

/// Demand-only V1 schema for a pre-provisioned PRIVATE custom zone. Constructor
/// performs no network work; this class never creates zones/deploys schemas.
/// Every transaction saves the device demand AND authoritative intent atomically
/// with ifServerRecordUnchanged. No assets, private voices or source text here.
/// Live signed-host/account/network/cancellation qualification is still required;
/// this is not a complete ChapterService or background worker implementation.
public actor ChapterCloudDemandTransport: ChapterDemandTransport {
    public nonisolated static let zoneName = "LibroxProChaptersV1"
    public nonisolated static let demandRecordType = "LibroxChapterDemandV1"
    public nonisolated static let queueRecordType = "LibroxChapterIntentV1"
    public nonisolated static let payloadField = "payloadV1"
    private let database: CKDatabase
    private let zone: CKRecordZone.ID
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private struct Held {
        let intent: ChapterDemandIntent
        let snapshot: ChapterDemandSnapshot
        let demand: CKRecord?
        let queue: CKRecord?
    }
    private var held: [UUID: Held] = [:]
    private var reading = false
    private var committing = false

    /// Host derives accountPartition from container/environment/privateDB/account
    /// identity and supplies a fresh gate epoch. Host must verify the actual
    /// signed environment and current user account before deriving identity.
    /// Uses only this container's private database and the fixed custom zone.
    public init(container: CKContainer, account: ChapterCloudAccountIdentity, session: ChapterAccountSession,
                gate: ChapterAccountSessionGate) throws {
        guard container.containerIdentifier == account.containerIdentifier,
              session.accountPartition == account.accountPartition, isDigest(session.accountPartition)
        else { throw ChapterWorkerError.invalidIdentity }
        database = container.privateCloudDatabase
        zone = .init(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        self.session = session; self.gate = gate
    }
    private func valid(_ value: ChapterAccountSession) async throws {
        try Task.checkCancellation()
        guard value == session else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(value); try Task.checkCancellation()
    }
    private func ids(_ intent: ChapterDemandIntent) throws -> (CKRecord.ID, CKRecord.ID) {
        guard intent.request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let key = try intent.request.renderKey()
        return (.init(recordName: "d-" + key + "-" + intent.deviceID.uuidString.lowercased(), zoneID: zone),
                .init(recordName: "q-" + key, zoneID: zone))
    }
    func read(_ intent: ChapterDemandIntent, session: ChapterAccountSession) async throws -> ChapterDemandSnapshot {
        try await valid(session)
        // One in-flight transaction per bound adapter. Reentrant clients cannot
        // evict another client's read set or accumulate retained CKRecords.
        guard !reading, !committing, held.isEmpty else { throw ChapterDemandTransportError.busy }
        reading = true; defer { reading = false }
        let (demandID, queueID) = try ids(intent)
        let records: [CKRecord.ID: Result<CKRecord, Error>]
        do { records = try await fetch([demandID, queueID]) }
        catch { try await valid(session); throw Self.classify(error) }
        try await valid(session)
        func record(_ id: CKRecord.ID, type: String) throws -> CKRecord? {
            guard let value = records[id] else { throw ChapterDemandTransportError.uncertain }
            switch value {
            case .success(let record):
                guard record.recordID == id, record.recordType == type, record.recordChangeTag != nil
                else { throw ChapterDemandTransportError.invalidRecord }
                return record
            case .failure(let error):
                if (error as? CKError)?.code == .unknownItem { return nil }
                throw Self.classify(error)
            }
        }
        let d = try record(demandID, type: Self.demandRecordType), q = try record(queueID, type: Self.queueRecordType)
        let snapshot = ChapterDemandSnapshot(token: UUID(), demand: try d.map { try Self.decode(ChapterRemoteDemand.self, record: $0) },
            queue: try q.map { try Self.decode(ChapterRemoteQueueIntent.self, record: $0) })
        held[snapshot.token] = .init(intent: intent, snapshot: snapshot, demand: d, queue: q)
        return snapshot
    }
    func discard(_ snapshot: ChapterDemandSnapshot) { held.removeValue(forKey: snapshot.token) }
    func commit(_ proposal: ChapterDemandProposal, snapshot: ChapterDemandSnapshot,
                session: ChapterAccountSession) async throws -> ChapterServerRevision {
        try await valid(session)
        guard !committing else { throw ChapterDemandTransportError.busy }
        guard let original = held.removeValue(forKey: snapshot.token),
              original.snapshot.demand == snapshot.demand, original.snapshot.queue == snapshot.queue,
              try ChapterDemandTransition.proposal(original.intent, from: snapshot).demand == proposal.demand,
              try ChapterDemandTransition.proposal(original.intent, from: snapshot).queue == proposal.queue
        else { throw ChapterDemandTransportError.conflict }
        committing = true; defer { committing = false }
        let (demandID, queueID) = try ids(original.intent)
        let d = original.demand ?? CKRecord(recordType: Self.demandRecordType, recordID: demandID)
        let q = original.queue ?? CKRecord(recordType: Self.queueRecordType, recordID: queueID)
        let demandBytes = try Self.encode(proposal.demand), queueBytes = try Self.encode(proposal.queue)
        let expectedDemand = (demandBytes.count, SHA256.hash(data: demandBytes))
        let expectedQueue = (queueBytes.count, SHA256.hash(data: queueBytes))
        d[Self.payloadField] = demandBytes as NSData
        q[Self.payloadField] = queueBytes as NSData
        let saved: [CKRecord.ID: Result<CKRecord, Error>]
        do { saved = try await save([d, q]) }
        catch { try await valid(session); throw Self.classify(error) }
        try await valid(session)
        guard Set(saved.keys) == Set([demandID, queueID])
        else { throw ChapterDemandTransportError.uncertain }
        var tags: [String] = []
        for (id, type, expected) in [(demandID, Self.demandRecordType, expectedDemand), (queueID, Self.queueRecordType, expectedQueue)] {
            guard let result = saved[id] else { throw ChapterDemandTransportError.uncertain }
            switch result {
            case .failure(let error): throw Self.classify(error)
            case .success(let record):
                guard record.recordID == id, record.recordType == type,
                      let tag = record.recordChangeTag, !tag.isEmpty,
                      let payload = record[Self.payloadField] as? Data, payload.count == expected.0,
                      SHA256.hash(data: payload) == expected.1
                else { throw ChapterDemandTransportError.uncertain }
                tags.append(tag)
            }
        }
        // Scope/version identity, not a clock, lease or raw record exposed to UI.
        let bytes = try JSONEncoder().encode([session.accountPartition, demandID.recordName, queueID.recordName] + tags)
        return try .init(opaqueValue: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    /// Own each native operation through its completion callback, including
    /// cancellation. No detached fire-and-forget network operation is created.
    /// Framework request/resource deadlines are explicit; real offline/sleep/
    /// account/cancel completion behavior still requires signed-host validation.
    private func perform<Value: Sendable>(_ operation: CKDatabaseOperation,
        configure: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        operation.qualityOfService = .utility
        let db = database
        let outcome = Mutex<Result<Value, Error>?>(nil)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                configure { result in
                    outcome.withLock { slot in if case .none = slot { slot = result } }
                }
                // Results are processed by the result blocks, then handed off
                // only after Foundation marks the owned operation finished.
                // Also covers cancellation before the operation starts.
                operation.completionBlock = { [weak operation] in
                    let result = outcome.withLock { stored in
                        stored ?? .failure(operation?.isCancelled == true ? CancellationError() : ChapterDemandTransportError.uncertain)
                    }
                    continuation.resume(with: result)
                }
                db.add(operation)
                if Task.isCancelled { operation.cancel() }
            }
        } onCancel: { operation.cancel() }
    }
    private func fetch(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let operation = CKFetchRecordsOperation(recordIDs: ids)
        let values = Mutex<[CKRecord.ID: Result<CKRecord, Error>]>([:])
        return try await perform(operation) { complete in
            operation.perRecordResultBlock = { id, result in values.withLock { $0[id] = result } }
            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success: complete(.success(values.withLock { $0 }))
                case .failure(let error):
                    // unknownItem is per-record absence; preserve successes and
                    // errors for exact classification, never invent empty rows.
                    if (error as? CKError)?.code == .partialFailure {
                        complete(.success(values.withLock { $0 }))
                    } else { complete(.failure(error)) }
                }
            }
        }
    }
    private func save(_ records: [CKRecord]) async throws -> [CKRecord.ID: Result<CKRecord, Error>] {
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: [])
        operation.savePolicy = .ifServerRecordUnchanged; operation.isAtomic = true
        let values = Mutex<[CKRecord.ID: Result<CKRecord, Error>]>([:])
        return try await perform(operation) { complete in
            operation.perRecordSaveBlock = { id, result in values.withLock { $0[id] = result } }
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success: complete(.success(values.withLock { $0 }))
                case .failure(let error): complete(.failure(error))
                }
            }
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 128 * 1024 else { throw ChapterDemandTransportError.invalidRecord }
        return data
    }
    private static func decode<T: Decodable>(_ type: T.Type, record: CKRecord) throws -> T {
        guard let data = record[payloadField] as? Data, data.count <= 128 * 1024 else { throw ChapterDemandTransportError.invalidRecord }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ChapterDemandTransportError.invalidRecord }
    }
    static func classify(_ error: Error) -> ChapterDemandTransportError {
        if let value = error as? CKError, value.code == .partialFailure,
           let failures = value.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
            guard !failures.isEmpty, failures.count <= 2 else { return .invalidRecord }
            let codes = failures.values.map(classifySingle)
            // A sibling batchRequestFailed must not hide account/configuration
            // failure or a server-requested delay on the actual failed record.
            for code in codes {
                switch code {
                case .accountUnavailable, .configurationUnavailable, .quotaExceeded, .offline, .operationCancelled: return code
                default: break
                }
            }
            let delays = codes.compactMap { code -> TimeInterval? in
                if case .retryAfter(let seconds) = code { return seconds }; return nil
            }
            if let delay = delays.max() { return .retryAfter(seconds: delay) }
            return codes.contains(.conflict) ? .conflict : .uncertain
        }
        return classifySingle(error)
    }
    private static func classifySingle(_ error: Error) -> ChapterDemandTransportError {
        if let value = error as? CKError {
            switch value.code {
            case .serverRecordChanged: return .conflict
            case .notAuthenticated, .permissionFailure: return .accountUnavailable
            case .operationCancelled: return .operationCancelled
            case .networkUnavailable: return .offline
            case .requestRateLimited, .serviceUnavailable, .zoneBusy:
                let requested = (value.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue ?? 60
                guard requested.isFinite, requested >= 0, requested <= 7 * 24 * 3600 else { return .configurationUnavailable }
                return .retryAfter(seconds: max(1, requested))
            case .badContainer, .badDatabase, .missingEntitlement, .zoneNotFound, .serverRejectedRequest, .invalidArguments:
                return .configurationUnavailable
            case .quotaExceeded, .limitExceeded: return .quotaExceeded
            default: break
            }
        }
        // Lost acknowledgement, partial results, network errors and cancelled
        // server operations may have committed. Re-read/CAS; never assume failure
        // means nothing happened or acknowledge a local demand from an exception.
        return .uncertain
    }
}
