import Foundation
import CloudKit
import CryptoKit
import Darwin
import Synchronization

/// Exact immutable CONTENT identity. Current book control/claim authority must
/// admit this identity separately; self-consistent bytes authorize no work.
package struct ChapterBookEntryContentIdentity: Codable, Sendable, Equatable {
    package enum Kind: String, Codable, Sendable { case chapter = "source-plan-1", silent = "literal-silent-1" }
    package static let maximumBytes: Int64 = 8 * 1024 * 1024
    package let version: Int
    package let accountPartition, scopeID: String
    package let chapterIndex: Int
    package let kind: Kind
    package let byteCount: Int64
    package let payloadSHA256: String
    package init(accountPartition: String, scopeID: String, chapterIndex: Int, kind: Kind, payload: Data) throws {
        guard !payload.isEmpty, payload.count <= Self.maximumBytes else { throw ChapterWorkerError.invalidIdentity }
        version = 1; self.accountPartition = accountPartition; self.scopeID = scopeID
        self.chapterIndex = chapterIndex; self.kind = kind; byteCount = Int64(payload.count)
        payloadSHA256 = ChapterCloudFileCapture.digest(payload); try validate()
    }
    package func validate() throws {
        guard version == 1, isDigest(accountPartition), isDigest(scopeID), (0..<4096).contains(chapterIndex),
              (1...Self.maximumBytes).contains(byteCount), isDigest(payloadSHA256) else { throw ChapterWorkerError.invalidIdentity }
    }
    package func verify(_ payload: Data) throws {
        try validate()
        guard payload.count == byteCount, ChapterCloudFileCapture.digest(payload) == payloadSHA256 else {
            throw ChapterCloudBookEntryError.invalidRecord
        }
    }
    package func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 4096 else { throw ChapterCloudBookEntryError.invalidRecord }; return data
    }
    package static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw ChapterCloudBookEntryError.invalidRecord }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard try value.encoded() == data else { throw ChapterCloudBookEntryError.invalidRecord }; return value
    }
    package func key() throws -> String { "be-" + ChapterCloudFileCapture.digest(try encoded()) }
}
enum ChapterCloudBookEntryError: Error, Equatable { case busy, absent, invalidRecord, conflict }
/// PAST immutable-content acknowledgement only, never a current book/lease grant.
package struct ChapterBookContentServerReceipt: Sendable {
    package enum Evidence: Sendable { case acknowledgedUpload, verifiedExistingBytes }
    package let identity: ChapterBookEntryContentIdentity
    package let session: ChapterAccountSession
    package let revision: ChapterServerRevision
    package let evidence: Evidence
    fileprivate init(identity: ChapterBookEntryContentIdentity, session: ChapterAccountSession,
                     revision: ChapterServerRevision, evidence: Evidence) {
        self.identity = identity; self.session = session; self.revision = revision; self.evidence = evidence
    }
}
struct ChapterCloudBookEntrySnapshot: Sendable {
    let key, tag: String
    let metadata: Data
    let file: ChapterCloudFileCapture?
}
struct ChapterCloudBookEntryCapture: Sendable {
    let expected: ChapterCloudBookEntrySnapshot
    let identity: ChapterBookEntryContentIdentity
    let session: ChapterAccountSession
    let storage: URL
}
protocol ChapterCloudBookEntryStore: Sendable {
    func fetch(key: String, capture: ChapterCloudBookEntryCapture?) async throws -> ChapterCloudBookEntrySnapshot?
    func insert(key: String, metadata: Data, content: URL) async throws -> ChapterCloudBookEntrySnapshot
}

/// Internal exact source/portable-plan/literal-silent CONTENT transport. No
/// intent acknowledgement, head, claim, catalog, playable asset or factory.
/// Host must provide an authenticated expected identity from current controls.
package actor ChapterCloudBookEntryTransport {
    static let recordType = "LibroxBookEntryV1", metadataField = "manifestV1", contentField = "contentV1"
    private let store: any ChapterCloudBookEntryStore
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let captureStorage: URL
    private let authorize: @Sendable () async throws -> Void
    private var occupied = false
    package var boundSession: ChapterAccountSession { session }
    package var captureDirectory: URL { captureStorage }
    package init(container: CKContainer, account: ChapterCloudAccountIdentity, session: ChapterAccountSession,
                 gate: ChapterAccountSessionGate, captureStorage: URL,
                 authorizeAssetTransfer: @escaping @Sendable () async throws -> Void) throws {
        guard container.containerIdentifier == account.containerIdentifier, account.accountPartition == session.accountPartition,
              captureStorage.isFileURL else { throw ChapterWorkerError.invalidIdentity }
        store = NativeChapterCloudBookEntryStore(database: container.privateCloudDatabase)
        self.session = session; self.gate = gate; self.captureStorage = captureStorage; authorize = authorizeAssetTransfer
    }
    init(store: any ChapterCloudBookEntryStore, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
         captureStorage: URL, authorize: @escaping @Sendable () async throws -> Void = {}) {
        self.store = store; self.session = session; self.gate = gate; self.captureStorage = captureStorage; self.authorize = authorize
    }
    private func valid(_ identity: ChapterBookEntryContentIdentity) async throws {
        try identity.validate(); try Task.checkCancellation()
        guard identity.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session); try Task.checkCancellation()
    }
    private func authorized(_ identity: ChapterBookEntryContentIdentity) async throws {
        try await valid(identity); try await authorize(); try await valid(identity)
    }
    private static func validate(_ found: ChapterCloudBookEntrySnapshot, identity: ChapterBookEntryContentIdentity) throws {
        guard found.key == (try identity.key()), !found.tag.isEmpty, found.tag.utf8.count <= 1024,
              try ChapterBookEntryContentIdentity.decode(found.metadata) == identity else { throw ChapterCloudBookEntryError.invalidRecord }
    }
    private func receipt(_ snapshot: ChapterCloudBookEntrySnapshot, identity: ChapterBookEntryContentIdentity,
                         evidence: ChapterBookContentServerReceipt.Evidence) throws -> ChapterBookContentServerReceipt {
        try Self.validate(snapshot, identity: identity)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode([session.accountPartition, snapshot.key, snapshot.tag,
            ChapterCloudFileCapture.digest(snapshot.metadata)])
        return .init(identity: identity, session: session,
            revision: try .init(opaqueValue: ChapterCloudFileCapture.digest(data)), evidence: evidence)
    }
    private func fetch(_ identity: ChapterBookEntryContentIdentity, capture: ChapterCloudBookEntryCapture? = nil) async throws -> ChapterCloudBookEntrySnapshot? {
        try await authorized(identity)
        do {
            let value = try await store.fetch(key: identity.key(), capture: capture)
            try await valid(identity); return value
        } catch { try await valid(identity); throw error }
    }
    private func verifiedBytes(_ metadata: ChapterCloudBookEntrySnapshot, identity: ChapterBookEntryContentIdentity) async throws -> Data {
        try Self.validate(metadata, identity: identity)
        let capture = ChapterCloudBookEntryCapture(expected: metadata, identity: identity, session: session, storage: captureStorage)
        guard let found = try await fetch(identity, capture: capture), found.tag == metadata.tag,
              found.metadata == metadata.metadata, let file = found.file else { throw ChapterCloudBookEntryError.conflict }
        try Self.validate(found, identity: identity)
        let session = session, gate = gate
        let bytes = try await file.withFileAccess(session: session, gate: gate) { url in
            try Self.read(url, identity: identity)
        }
        try await valid(identity); return bytes
    }
    package func download(_ identity: ChapterBookEntryContentIdentity) async throws -> Data {
        try await valid(identity)
        guard !occupied else { throw ChapterCloudBookEntryError.busy }; occupied = true; defer { occupied = false }
        guard let metadata = try await fetch(identity) else { throw ChapterCloudBookEntryError.absent }
        return try await verifiedBytes(metadata, identity: identity)
    }
    /// Byte acceptance only. Caller retains its exact source/plan durably until
    /// authoritative cloud control acknowledgement, and revalidates typed bytes
    /// under the receiver epoch. No public arbitrary-file/voice upload seam.
    @discardableResult package func upload(_ payload: Data, identity: ChapterBookEntryContentIdentity) async throws -> ChapterBookContentServerReceipt {
        try await valid(identity); try identity.verify(payload)
        guard !occupied else { throw ChapterCloudBookEntryError.busy }; occupied = true; defer { occupied = false }
        if let metadata = try await fetch(identity) {
            _ = try await verifiedBytes(metadata, identity: identity)
            return try receipt(metadata, identity: identity, evidence: .verifiedExistingBytes)
        }
        do {
            let session = session, gate = gate, storage = captureStorage
            let producer = Task.detached(priority: .utility) {
                try ChapterCloudFileCapture.create(payload, maximum: ChapterBookEntryContentIdentity.maximumBytes,
                    session: session, storageDirectory: storage, check: { try Task.checkCancellation() })
            }
            let file = try await withTaskCancellationHandler { try await producer.value } onCancel: { producer.cancel() }
            let saved = try await file.withFileAccess(session: session, gate: gate) { url in
                try await self.authorized(identity)
                return try await self.store.insert(key: identity.key(), metadata: identity.encoded(), content: url)
            }
            try await valid(identity); try Self.validate(saved, identity: identity)
            return try receipt(saved, identity: identity, evidence: .acknowledgedUpload)
        } catch {
            try await valid(identity)
            // Only native conflict/uncertain acknowledgement reconciles ONCE.
            // Local copy/hash/typed decode/cancel errors are never network retry.
            guard let errorKind = error as? ChapterDemandTransportError,
                  errorKind == .conflict || errorKind == .uncertain,
                  let metadata = try await fetch(identity) else { throw error }
            _ = try await verifiedBytes(metadata, identity: identity)
            return try receipt(metadata, identity: identity, evidence: .verifiedExistingBytes)
        }
    }
    private static func read(_ url: URL, identity: ChapterBookEntryContentIdentity) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ChapterCloudBookEntryError.invalidRecord }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var before = stat(), after = stat(), path = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size == identity.byteCount else {
            throw ChapterCloudBookEntryError.invalidRecord
        }
        var data = Data(); data.reserveCapacity(Int(identity.byteCount))
        while data.count < identity.byteCount {
            try autoreleasepool {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: Int(min(65536, identity.byteCount - Int64(data.count)))) ?? Data()
                guard !chunk.isEmpty else { throw ChapterCloudBookEntryError.invalidRecord }; data.append(chunk)
            }
        }
        guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_dev == path.st_dev, before.st_ino == path.st_ino else { throw ChapterCloudBookEntryError.invalidRecord }
        try Task.checkCancellation(); try identity.verify(data); return data
    }
}

private actor NativeChapterCloudBookEntryStore: ChapterCloudBookEntryStore {
    let database: CKDatabase
    let zone = CKRecordZone.ID(zoneName: ChapterCloudDemandTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    init(database: CKDatabase) { self.database = database }
    private func id(_ key: String) -> CKRecord.ID { .init(recordName: key, zoneID: zone) }
    private static func snapshot(_ record: CKRecord, expected: CKRecord.ID) throws -> ChapterCloudBookEntrySnapshot {
        guard record.recordID == expected, record.recordType == ChapterCloudBookEntryTransport.recordType,
              let tag = record.recordChangeTag, !tag.isEmpty, tag.utf8.count <= 1024,
              let metadata = record[ChapterCloudBookEntryTransport.metadataField] as? Data,
              !metadata.isEmpty, metadata.count <= 4096 else { throw ChapterCloudBookEntryError.invalidRecord }
        let identity = try ChapterBookEntryContentIdentity.decode(metadata)
        guard try identity.key() == expected.recordName else { throw ChapterCloudBookEntryError.invalidRecord }
        return .init(key: expected.recordName, tag: tag, metadata: metadata, file: nil)
    }
    func fetch(key: String, capture: ChapterCloudBookEntryCapture?) async throws -> ChapterCloudBookEntrySnapshot? {
        let recordID = id(key), operation = CKFetchRecordsOperation(recordIDs: [id(key)])
        operation.desiredKeys = [ChapterCloudBookEntryTransport.metadataField] + (capture == nil ? [] : [ChapterCloudBookEntryTransport.contentField])
        let outcome = Mutex<Result<ChapterCloudBookEntrySnapshot?, Error>?>(nil)
        do {
            return try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordResultBlock = { [weak operation] foundID, result in
                    let found: Result<ChapterCloudBookEntrySnapshot?, Error>
                    do {
                        guard foundID == recordID else { throw ChapterCloudBookEntryError.invalidRecord }
                        switch result {
                        case .failure(let error):
                            if (error as? CKError)?.code == .unknownItem { found = .success(nil) } else { throw error }
                        case .success(let record):
                            let metadata = try Self.snapshot(record, expected: recordID)
                            if let capture {
                                guard metadata.tag == capture.expected.tag, metadata.metadata == capture.expected.metadata,
                                      try ChapterBookEntryContentIdentity.decode(metadata.metadata) == capture.identity,
                                      let url = (record[ChapterCloudBookEntryTransport.contentField] as? CKAsset)?.fileURL else {
                                    throw ChapterCloudBookEntryError.conflict
                                }
                                // Capture inside callback BEFORE CloudKit may
                                // discard staging; retain through completion.
                                let file = try ChapterCloudFileCapture.capture(download: url,
                                    expectedBytes: capture.identity.byteCount, expectedSHA256: capture.identity.payloadSHA256,
                                    maximum: ChapterBookEntryContentIdentity.maximumBytes, session: capture.session,
                                    storageDirectory: capture.storage, check: {
                                        guard let operation, !operation.isCancelled else { throw CancellationError() }
                                    })
                                found = .success(.init(key: key, tag: metadata.tag, metadata: metadata.metadata, file: file))
                            } else { found = .success(metadata) }
                        }
                    } catch { found = .failure(error) }
                    outcome.withLock { $0 = found }
                }
                operation.fetchRecordsResultBlock = { result in
                    let saved = outcome.withLock { value in let saved = value; value = nil; return saved }
                    switch result {
                    case .success: complete(saved ?? .failure(ChapterCloudBookEntryError.invalidRecord))
                    case .failure(let error):
                        if case .failure(let local)? = saved, !(local is CKError) { complete(.failure(local)); return }
                        if (error as? CKError)?.code == .partialFailure, case .success(.none)? = saved { complete(.success(nil)) }
                        else { complete(.failure(error)) }
                    }
                }
            }
        } catch { throw Self.convert(error) }
    }
    func insert(key: String, metadata: Data, content: URL) async throws -> ChapterCloudBookEntrySnapshot {
        let record = CKRecord(recordType: ChapterCloudBookEntryTransport.recordType, recordID: id(key))
        record[ChapterCloudBookEntryTransport.metadataField] = metadata as NSData
        record[ChapterCloudBookEntryTransport.contentField] = CKAsset(fileURL: content)
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        operation.isAtomic = true; operation.savePolicy = .ifServerRecordUnchanged
        let outcome = Mutex<Result<CKRecord, Error>?>(nil)
        do {
            let saved: CKRecord = try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordSaveBlock = { foundID, result in
                    outcome.withLock { $0 = foundID == record.recordID ? result : .failure(ChapterCloudBookEntryError.invalidRecord) }
                }
                operation.modifyRecordsResultBlock = { result in
                    let saved = outcome.withLock { value in let saved = value; value = nil; return saved }
                    switch result {
                    case .success: complete(saved ?? .failure(ChapterCloudBookEntryError.invalidRecord))
                    case .failure(let error):
                        if case .failure(let local)? = saved, !(local is CKError) { complete(.failure(local)) }
                        else { complete(.failure(error)) }
                    }
                }
            }
            return try Self.snapshot(saved, expected: id(key))
        } catch { throw Self.convert(error) }
    }
    private static func convert(_ error: Error) -> Error {
        if error is CKError { return ChapterCloudDemandTransport.classify(error) }; return error
    }
}
