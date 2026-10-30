import Foundation
import CloudKit
import Synchronization

enum ChapterCloudSegmentError: Error, Equatable { case busy, absent, invalidRecord, conflict }
struct ChapterCloudSegmentSnapshot: Sendable {
    let key, tag: String
    let manifest: Data
    let file: ChapterCloudFileCapture?
}
struct ChapterCloudSegmentCapture: Sendable {
    let expected: ChapterCloudSegmentSnapshot
    let manifest: ChapterSegmentManifest
    let session: ChapterAccountSession
    let storage: URL
}
protocol ChapterCloudSegmentStore: Sendable {
    func fetch(key: String, capture: ChapterCloudSegmentCapture?) async throws -> ChapterCloudSegmentSnapshot?
    func insert(key: String, manifest: Data, audio: URL) async throws -> ChapterCloudSegmentSnapshot
}

/// Immutable CONTENT transport only. It cannot publish a book/chapter head,
/// acknowledge intent or grant a lease. The eventual service must authenticate
/// the expected manifest from its current fenced ordered head BEFORE calling it.
/// No zone creation/schema deployment or production factory activation.
actor ChapterCloudSegmentTransport {
    static let recordType = "LibroxChapterSegmentV1"
    static let manifestField = "manifestV1", audioField = "audioV1"
    private let store: any ChapterCloudSegmentStore
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let captureStorage, custodyStorage: URL
    private let authorize: @Sendable () async throws -> Void
    private var occupied = false
    init(container: CKContainer, account: ChapterCloudAccountIdentity, session: ChapterAccountSession,
         gate: ChapterAccountSessionGate, captureStorage: URL, custodyStorage: URL,
         authorizeAssetTransfer: @escaping @Sendable () async throws -> Void) throws {
        let capturePath = captureStorage.resolvingSymlinksInPath().standardizedFileURL.path
        let custodyPath = custodyStorage.resolvingSymlinksInPath().standardizedFileURL.path
        guard container.containerIdentifier == account.containerIdentifier, account.accountPartition == session.accountPartition,
              captureStorage.isFileURL, custodyStorage.isFileURL, capturePath != "/", custodyPath != "/",
              capturePath != custodyPath, !capturePath.hasPrefix(custodyPath + "/"), !custodyPath.hasPrefix(capturePath + "/")
        else { throw ChapterWorkerError.invalidIdentity }
        self.store = NativeChapterCloudSegmentStore(database: container.privateCloudDatabase)
        self.session = session; self.gate = gate; self.captureStorage = captureStorage; self.custodyStorage = custodyStorage
        authorize = authorizeAssetTransfer
    }
    init(store: any ChapterCloudSegmentStore, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
         captureStorage: URL, custodyStorage: URL, authorize: @escaping @Sendable () async throws -> Void = {}) {
        self.store = store; self.session = session; self.gate = gate; self.captureStorage = captureStorage
        self.custodyStorage = custodyStorage; self.authorize = authorize
    }
    private func valid(_ request: ChapterRenderRequest) async throws {
        try request.validate(); try Task.checkCancellation()
        guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session); try Task.checkCancellation()
    }
    private func authorized(_ request: ChapterRenderRequest) async throws {
        try await valid(request); try await authorize(); try await valid(request)
    }
    private func fetch(_ key: String, request: ChapterRenderRequest, capture: ChapterCloudSegmentCapture? = nil) async throws -> ChapterCloudSegmentSnapshot? {
        try await authorized(request)
        do {
            let result = try await store.fetch(key: key, capture: capture)
            try await valid(request); return result
        } catch { try await valid(request); throw error }
    }
    private func validate(_ found: ChapterCloudSegmentSnapshot, expected: ChapterSegmentManifest,
                          request: ChapterRenderRequest, text: String) throws {
        guard found.key == "s-" + (try expected.sha256()), !found.tag.isEmpty, found.tag.utf8.count <= 1024,
              try ChapterSegmentManifest.decode(found.manifest, request: request, originalText: text) == expected else {
            throw ChapterCloudSegmentError.invalidRecord
        }
    }
    private func copy(_ metadata: ChapterCloudSegmentSnapshot, manifest: ChapterSegmentManifest,
                      request: ChapterRenderRequest, text: String) async throws -> ChapterLocalSegmentArtifact {
        try validate(metadata, expected: manifest, request: request, text: text)
        let capture = ChapterCloudSegmentCapture(expected: metadata, manifest: manifest, session: session, storage: captureStorage)
        guard let found = try await fetch(metadata.key, request: request, capture: capture),
              found.tag == metadata.tag, found.manifest == metadata.manifest, let file = found.file else { throw ChapterCloudSegmentError.conflict }
        try validate(found, expected: manifest, request: request, text: text)
        let session = session, gate = gate, storage = custodyStorage
        let artifact = try await file.withFileAccess(session: session, gate: gate) { url in
            try await ChapterLocalSegmentArtifact.adopt(download: url, manifest: manifest, request: request,
                originalText: text, session: session, gate: gate, storageDirectory: storage)
        }
        try await valid(request)
        return artifact
    }
    /// Expected metadata must already belong to the exact current ordered head;
    /// this method does not infer currentness from immutable content existence.
    func download(manifest: ChapterSegmentManifest, request: ChapterRenderRequest, originalText: String) async throws -> ChapterLocalSegmentArtifact {
        guard !occupied else { throw ChapterCloudSegmentError.busy }; occupied = true; defer { occupied = false }
        try await valid(request); try manifest.validate(for: request, originalText: originalText)
        guard let metadata = try await fetch("s-" + manifest.sha256(), request: request) else { throw ChapterCloudSegmentError.absent }
        return try await copy(metadata, manifest: manifest, request: request, text: originalText)
    }
    /// Successful return means immutable content is confirmed, NOT ordered-head
    /// publication, Reader acceptance, demand acknowledgement or book completion.
    func upload(_ artifact: ChapterLocalSegmentArtifact, originalText: String) async throws -> ChapterCloudSegmentSnapshot {
        guard !occupied else { throw ChapterCloudSegmentError.busy }; occupied = true; defer { occupied = false }
        let request = artifact.request, manifest = artifact.manifest
        guard artifact.session == session else { throw ChapterWorkerError.accountMismatch }
        try await valid(request); try manifest.validate(for: request, originalText: originalText)
        let key = "s-" + (try manifest.sha256()), payload = try manifest.encoded()
        if let existing = try await fetch(key, request: request) {
            _ = try await copy(existing, manifest: manifest, request: request, text: originalText)
            return existing
        }
        do {
            let session = session, gate = gate, captureStorage = captureStorage
            let saved = try await artifact.withFileAccess(session: session, gate: gate) { url in
                let producer = Task.detached(priority: .utility) {
                    try ChapterCloudFileCapture.capture(download: url, expectedBytes: manifest.audio.audioByteCount,
                        expectedSHA256: manifest.audio.audioSHA256, maximum: ChapterSegmentManifest.maximumBytes,
                        session: session, storageDirectory: captureStorage, check: { try Task.checkCancellation() })
                }
                let file = try await withTaskCancellationHandler { try await producer.value } onCancel: { producer.cancel() }
                return try await file.withFileAccess(session: session, gate: gate) { captured in
                    try await self.authorized(request)
                    return try await self.store.insert(key: key, manifest: payload, audio: captured)
                }
            }
            try await valid(request); try validate(saved, expected: manifest, request: request, text: originalText)
            return saved
        } catch {
            try await valid(request)
            // Only native uncertain/conflict acknowledgements reconcile, once.
            // Local copy/decode/hash/storage/cancel failures never become retry.
            guard let failure = error as? ChapterDemandTransportError, failure == .uncertain || failure == .conflict,
                  let existing = try await fetch(key, request: request) else { throw error }
            _ = try await copy(existing, manifest: manifest, request: request, text: originalText)
            return existing
        }
    }
}

private actor NativeChapterCloudSegmentStore: ChapterCloudSegmentStore {
    let database: CKDatabase
    let zone = CKRecordZone.ID(zoneName: ChapterCloudDemandTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    init(database: CKDatabase) { self.database = database }
    private func id(_ key: String) -> CKRecord.ID { .init(recordName: key, zoneID: zone) }
    private static func snapshot(_ record: CKRecord, expected: CKRecord.ID) throws -> ChapterCloudSegmentSnapshot {
        guard record.recordType == ChapterCloudSegmentTransport.recordType, record.recordID == expected,
              let tag = record.recordChangeTag, !tag.isEmpty, tag.utf8.count <= 1024,
              let data = record[ChapterCloudSegmentTransport.manifestField] as? Data,
              !data.isEmpty, data.count <= 128 * 1024 else { throw ChapterCloudSegmentError.invalidRecord }
        return .init(key: expected.recordName, tag: tag, manifest: data, file: nil)
    }
    func fetch(key: String, capture: ChapterCloudSegmentCapture?) async throws -> ChapterCloudSegmentSnapshot? {
        let expected = id(key), operation = CKFetchRecordsOperation(recordIDs: [id(key)])
        operation.desiredKeys = [ChapterCloudSegmentTransport.manifestField] + (capture == nil ? [] : [ChapterCloudSegmentTransport.audioField])
        let outcome = Mutex<Result<ChapterCloudSegmentSnapshot?, Error>?>(nil)
        do {
            return try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordResultBlock = { [weak operation] foundID, result in
                    let found: Result<ChapterCloudSegmentSnapshot?, Error>
                    do {
                        guard foundID == expected else { throw ChapterCloudSegmentError.invalidRecord }
                        switch result {
                        case .failure(let error):
                            if (error as? CKError)?.code == .unknownItem { found = .success(nil) } else { throw error }
                        case .success(let record):
                            let metadata = try Self.snapshot(record, expected: expected)
                            if let capture {
                                guard metadata.key == capture.expected.key, metadata.tag == capture.expected.tag,
                                      metadata.manifest == capture.expected.manifest,
                                      let url = (record[ChapterCloudSegmentTransport.audioField] as? CKAsset)?.fileURL else {
                                    throw ChapterCloudSegmentError.conflict
                                }
                                // Capture INSIDE this callback, while CloudKit's
                                // downloaded staging URL is still guaranteed.
                                let file = try ChapterCloudFileCapture.capture(download: url,
                                    expectedBytes: capture.manifest.audio.audioByteCount, expectedSHA256: capture.manifest.audio.audioSHA256,
                                    maximum: ChapterSegmentManifest.maximumBytes, session: capture.session,
                                    storageDirectory: capture.storage, check: {
                                        guard let operation, !operation.isCancelled else { throw CancellationError() }
                                    })
                                found = .success(.init(key: metadata.key, tag: metadata.tag, manifest: metadata.manifest, file: file))
                            } else { found = .success(metadata) }
                        }
                    } catch { found = .failure(error) }
                    outcome.withLock { $0 = found }
                }
                operation.fetchRecordsResultBlock = { result in
                    let saved = outcome.withLock { value in let saved = value; value = nil; return saved }
                    switch result {
                    case .success: complete(saved ?? .failure(ChapterCloudSegmentError.invalidRecord))
                    case .failure(let error):
                        if case .failure(let local)? = saved, !(local is CKError) {
                            complete(.failure(local)); return
                        }
                        if (error as? CKError)?.code == .partialFailure, case .success(.none)? = saved { complete(.success(nil)) }
                        else { complete(.failure(error)) }
                    }
                }
            }
        } catch { throw Self.convert(error) }
    }
    func insert(key: String, manifest: Data, audio: URL) async throws -> ChapterCloudSegmentSnapshot {
        let record = CKRecord(recordType: ChapterCloudSegmentTransport.recordType, recordID: id(key))
        record[ChapterCloudSegmentTransport.manifestField] = manifest as NSData
        record[ChapterCloudSegmentTransport.audioField] = CKAsset(fileURL: audio)
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        operation.savePolicy = .ifServerRecordUnchanged; operation.isAtomic = true
        let outcome = Mutex<Result<CKRecord, Error>?>(nil)
        do {
            let saved: CKRecord = try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordSaveBlock = { foundID, result in
                    outcome.withLock { $0 = foundID == record.recordID ? result : .failure(ChapterCloudSegmentError.invalidRecord) }
                }
                operation.modifyRecordsResultBlock = { result in
                    let saved = outcome.withLock { value in let saved = value; value = nil; return saved }
                    switch result {
                    case .success: complete(saved ?? .failure(ChapterCloudSegmentError.invalidRecord))
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
        if error is CKError { return ChapterCloudDemandTransport.classify(error) }
        return error
    }
}
