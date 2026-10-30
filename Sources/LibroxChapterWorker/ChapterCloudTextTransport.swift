import Foundation
import CryptoKit
import CloudKit
import Synchronization

public enum ChapterSourceTransportError: Error, Equatable {
    case busy, absent, invalidRecord, conflict, localIO
    case localFile(ChapterTextAssetError)
    case cloud(ChapterDemandTransportError)
}

/// Source acceptance only, never a render, job acknowledgement or playable asset.
public struct ChapterSourceServerReceipt: Sendable {
    public enum Evidence: Sendable { case acknowledgedUpload, verifiedDownload }
    public let manifest: ChapterTextAssetManifest
    public let session: ChapterAccountSession
    public let revision: ChapterServerRevision
    public let evidence: Evidence
}

public struct ChapterDownloadedSource: Sendable {
    public let asset: ChapterTextAsset
    public let receipt: ChapterSourceServerReceipt
}

/// Record lifetime retains metadata only; native downloads are copied while
/// still inside their CloudKit result callback, before operation completion.
/// Internal value/store seams are for deterministic offline contract tests only.
struct ChapterSourceSnapshot: Sendable {
    let key, type, tag: String
    let payload: Data
    let file: URL?
    let lifetime: CKRecord?
    var captured: ChapterTextAsset? = nil
}
struct ChapterSourceCapture: Sendable {
    let metadata: ChapterSourceSnapshot
    let manifest: ChapterTextAssetManifest
    let request: ChapterRenderRequest
    let session: ChapterAccountSession
    let storage: URL
}
protocol ChapterSourceRecordStore: Sendable {
    func fetch(key: String, asset: Bool, capture: ChapterSourceCapture?) async throws -> ChapterSourceSnapshot?
    func insert(key: String, payload: Data, file: URL) async throws -> ChapterSourceSnapshot
}

/// Stock-voice chapter source transport in a pre-provisioned private custom zone.
/// Does not create zones/deploy schema, enqueue work or upload voice recordings.
/// No production service factory or live CloudKit qualification is implied.
public actor ChapterCloudTextTransport {
    public nonisolated static let recordType = "LibroxChapterSourceV1"
    public nonisolated static let payloadField = "manifestV1"
    public nonisolated static let assetField = "sourceV1"
    private let store: any ChapterSourceRecordStore
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let storage: URL
    private let authorizeAssetTransfer: @Sendable () async throws -> Void
    private var occupied = false

    /// Host supplies actual signed container/environment/current-user identity.
    /// The live authorization closure is called before EVERY native operation,
    /// including reconciliation. It must not capture a stale network preference.
    public init(container: CKContainer, account: ChapterCloudAccountIdentity,
                session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                storageDirectory: URL,
                authorizeAssetTransfer: @escaping @Sendable () async throws -> Void) throws {
        guard container.containerIdentifier == account.containerIdentifier,
              session.accountPartition == account.accountPartition, isDigest(session.accountPartition),
              storageDirectory.isFileURL else { throw ChapterWorkerError.invalidIdentity }
        store = NativeChapterSourceStore(database: container.privateCloudDatabase)
        self.session = session; self.gate = gate; storage = storageDirectory
        self.authorizeAssetTransfer = authorizeAssetTransfer
    }
    init(store: any ChapterSourceRecordStore, session: ChapterAccountSession,
         gate: ChapterAccountSessionGate, storageDirectory: URL,
         authorize: @escaping @Sendable () async throws -> Void = {}) {
        self.store = store; self.session = session; self.gate = gate
        storage = storageDirectory; authorizeAssetTransfer = authorize
    }
    private func valid(_ request: ChapterRenderRequest, _ value: ChapterAccountSession) async throws {
        try Task.checkCancellation(); try validateServiceRequest(request, session: value)
        guard value == session else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(value); try Task.checkCancellation()
    }
    private func authorized(_ request: ChapterRenderRequest, _ value: ChapterAccountSession) async throws {
        try await valid(request, value); try await authorizeAssetTransfer(); try await valid(request, value)
    }
    private func fetch(_ key: String, asset: Bool, request: ChapterRenderRequest,
                       session: ChapterAccountSession, capture: ChapterSourceCapture? = nil) async throws -> ChapterSourceSnapshot? {
        try await authorized(request, session)
        do {
            let result = try await store.fetch(key: key, asset: asset, capture: capture)
            try await valid(request, session); return result
        } catch { try await valid(request, session); throw error }
    }
    private static func encode(_ manifest: ChapterTextAssetManifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= 128 * 1024 else { throw ChapterSourceTransportError.invalidRecord }
        return data
    }
    fileprivate static func validate(_ snapshot: ChapterSourceSnapshot, key: String,
                                 request: ChapterRenderRequest) throws -> ChapterTextAssetManifest {
        guard snapshot.key == key, snapshot.type == recordType,
              !snapshot.tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, snapshot.tag.utf8.count <= 1024, !snapshot.payload.isEmpty,
              snapshot.payload.count <= 128 * 1024 else { throw ChapterSourceTransportError.invalidRecord }
        let manifest: ChapterTextAssetManifest
        do {
            manifest = try JSONDecoder().decode(ChapterTextAssetManifest.self, from: snapshot.payload)
            try manifest.validate(for: request)
        } catch { throw ChapterSourceTransportError.invalidRecord }
        guard try manifest.sourceKey() == key, try Self.encode(manifest) == snapshot.payload else { throw ChapterSourceTransportError.invalidRecord }
        return manifest
    }
    /// Only actual CK transport ambiguity is retryable as uncertain. Never turn
    /// a rejected source or local I/O failure into a network retry loop.
    static func classify(_ error: Error) -> Error {
        if let value = error as? ChapterSourceTransportError { return value }
        if error is CancellationError { return error }
        if let value = error as? ChapterTextAssetError { return ChapterSourceTransportError.localFile(value) }
        if error is ChapterWorkerError { return error }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain || value.domain == NSPOSIXErrorDomain { return ChapterSourceTransportError.localIO }
        if error is CKError { return ChapterSourceTransportError.cloud(ChapterCloudDemandTransport.classify(error)) }
        if value.domain == NSURLErrorDomain { return ChapterSourceTransportError.cloud(.offline) }
        return ChapterSourceTransportError.invalidRecord
    }
    private func receipt(_ snapshot: ChapterSourceSnapshot, manifest: ChapterTextAssetManifest,
                         evidence: ChapterSourceServerReceipt.Evidence) throws -> ChapterSourceServerReceipt {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode([session.accountPartition, snapshot.key,
            snapshot.type, snapshot.tag, SHA256.hash(data: snapshot.payload).map { String(format: "%02x", $0) }.joined()]))
        return .init(manifest: manifest, session: session,
            revision: try .init(opaqueValue: digest.map { String(format: "%02x", $0) }.joined()), evidence: evidence)
    }
    private func verifiedDownload(_ metadata: ChapterSourceSnapshot, manifest: ChapterTextAssetManifest,
                                  request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChapterDownloadedSource {
        // Metadata is admitted before requesting the asset. This bounds private
        // copying/decoding, not CloudKit's opaque wire/temp-file download size.
        guard let downloaded = try await fetch(metadata.key, asset: true, request: request, session: session,
            capture: .init(metadata: metadata, manifest: manifest, request: request, session: session, storage: storage))
        else { throw ChapterSourceTransportError.absent }
        defer { withExtendedLifetime(downloaded) {} }
        let actual = try Self.validate(downloaded, key: metadata.key, request: request)
        guard downloaded.tag == metadata.tag, actual == manifest,
              downloaded.payload == metadata.payload
        else { throw ChapterSourceTransportError.conflict }
        let privateCopy: ChapterTextAsset
        if let captured = downloaded.captured {
            guard captured.manifest == manifest, captured.session == session else { throw ChapterSourceTransportError.invalidRecord }
            _ = try await captured.text(session: session, gate: gate)
            privateCopy = captured
        } else {
            // Offline store seam only. The native adapter always captures during
            // its callback and never relies on the later staging URL lifetime.
            guard let url = downloaded.file else { throw ChapterSourceTransportError.invalidRecord }
            privateCopy = try await ChapterTextAsset.adopt(download: url, manifest: manifest, request: request,
                session: session, gate: gate, storageDirectory: storage)
        }
        try await valid(request, session)
        return .init(asset: privateCopy, receipt: try receipt(downloaded, manifest: manifest, evidence: .verifiedDownload))
    }

    public func download(request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChapterDownloadedSource {
        try await valid(request, session)
        guard !occupied else { throw ChapterSourceTransportError.busy }
        occupied = true; defer { occupied = false }
        let key = try ChapterTextAssetManifest.sourceKey(for: request.source)
        guard let metadata = try await fetch(key, asset: false, request: request, session: session)
        else { throw ChapterSourceTransportError.absent }
        let manifest = try Self.validate(metadata, key: key, request: request)
        return try await verifiedDownload(metadata, manifest: manifest, request: request, session: session)
    }

    public func publish(_ asset: ChapterTextAsset, request: ChapterRenderRequest,
                        session: ChapterAccountSession) async throws -> ChapterSourceServerReceipt {
        try await valid(request, session)
        guard asset.session == session else { throw ChapterWorkerError.accountMismatch }
        try asset.manifest.validate(for: request)
        guard !occupied else { throw ChapterSourceTransportError.busy }
        occupied = true; defer { occupied = false }
        let manifest = asset.manifest, key = try manifest.sourceKey(), payload = try Self.encode(manifest)
        return try await asset.withFileAccess(session: session, gate: gate) { url in
            if let existing = try await self.fetch(key, asset: false, request: request, session: session) {
                let found = try Self.validate(existing, key: key, request: request)
                guard found == manifest else { throw ChapterSourceTransportError.invalidRecord }
                return try await self.verifiedDownload(existing, manifest: manifest, request: request, session: session).receipt
            }
            try await self.authorized(request, session)
            do {
                let saved = try await self.store.insert(key: key, payload: payload, file: url)
                try await self.valid(request, session)
                let found = try Self.validate(saved, key: key, request: request)
                guard found == manifest, saved.payload == payload else { throw ChapterSourceTransportError.invalidRecord }
                return try await self.receipt(saved, manifest: manifest, evidence: .acknowledgedUpload)
            } catch {
                try await self.valid(request, session)
                // One finite lost-ack/conflict reconciliation only. Permanent
                // errors/backoff are retained for the outer durable service.
                guard let value = error as? ChapterSourceTransportError,
                      value == .conflict || value == .cloud(.uncertain) || value == .cloud(.conflict)
                else { throw error }
                guard let confirmed = try await self.fetch(key, asset: false, request: request, session: session)
                else { throw error }
                let found = try Self.validate(confirmed, key: key, request: request)
                guard found == manifest else { throw ChapterSourceTransportError.invalidRecord }
                return try await self.verifiedDownload(confirmed, manifest: manifest, request: request, session: session).receipt
            }
        }
    }
}

/// All CK operations remain owned through Foundation completion, including cancel.
/// This adapter cannot be instantiated in an unsigned test host; offline tests use
/// the internal store seam and do not establish live CloudKit behavior.
private actor NativeChapterSourceStore: ChapterSourceRecordStore {
    let database: CKDatabase
    let zone = CKRecordZone.ID(zoneName: ChapterCloudDemandTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    init(database: CKDatabase) { self.database = database }
    private func id(_ key: String) -> CKRecord.ID { .init(recordName: "s-" + key, zoneID: zone) }
    private nonisolated static func snapshot(_ record: CKRecord, key: String, expectedID: CKRecord.ID, requireAsset: Bool) throws -> ChapterSourceSnapshot {
        guard record.recordID == expectedID, record.recordType == ChapterCloudTextTransport.recordType,
              let tag = record.recordChangeTag,
              let payload = record[ChapterCloudTextTransport.payloadField] as? Data,
              !payload.isEmpty, payload.count <= 128 * 1024
        else { throw ChapterSourceTransportError.invalidRecord }
        let url = (record[ChapterCloudTextTransport.assetField] as? CKAsset)?.fileURL
        guard !requireAsset || url != nil else { throw ChapterSourceTransportError.invalidRecord }
        return .init(key: key, type: record.recordType, tag: tag, payload: payload, file: url, lifetime: record)
    }
    func fetch(key: String, asset: Bool, capture: ChapterSourceCapture?) async throws -> ChapterSourceSnapshot? {
        guard asset == (capture != nil) else { throw ChapterSourceTransportError.invalidRecord }
        let recordID = id(key), operation = CKFetchRecordsOperation(recordIDs: [id(key)])
        operation.desiredKeys = [ChapterCloudTextTransport.payloadField] + (asset ? [ChapterCloudTextTransport.assetField] : [])
        let outcome = Mutex<Result<ChapterSourceSnapshot?, Error>?>(nil)
        do {
            return try await perform(operation) { complete in
                operation.perRecordResultBlock = { [weak operation] foundID, result in
                    let saved: Result<ChapterSourceSnapshot?, Error>
                    do {
                        guard foundID == recordID else { throw ChapterSourceTransportError.invalidRecord }
                        switch result {
                        case .failure(let error):
                            if (error as? CKError)?.code == .unknownItem { saved = .success(nil) }
                            else { throw error }
                        case .success(let record):
                            var value = try Self.snapshot(record, key: key, expectedID: recordID, requireAsset: asset)
                            if let capture {
                                let manifest = try ChapterCloudTextTransport.validate(value, key: key, request: capture.request)
                                guard value.tag == capture.metadata.tag, value.payload == capture.metadata.payload,
                                      manifest == capture.manifest, let url = value.file
                                else { throw ChapterSourceTransportError.conflict }
                                value.captured = try ChapterTextAsset.captureDownloadedFile(download: url,
                                    manifest: manifest, request: capture.request, session: capture.session,
                                    storageDirectory: capture.storage, check: {
                                        guard let operation, !operation.isCancelled else { throw CancellationError() }
                                    })
                            }
                            saved = .success(value)
                        }
                    } catch { saved = .failure(error) }
                    outcome.withLock { $0 = saved }
                }
                operation.fetchRecordsResultBlock = { result in
                    let found = outcome.withLock { slot in let value = slot; slot = nil; return value }
                    switch result {
                    case .success: complete(found ?? .failure(ChapterSourceTransportError.invalidRecord))
                    case .failure(let error):
                        // Only per-record unknownItem under partialFailure is a
                        // legitimate absent source; other overall failures stay failures.
                        if (error as? CKError)?.code == .partialFailure, case .success(.none)? = found {
                            complete(.success(nil))
                        } else { complete(.failure(error)) }
                    }
                }
            }
        } catch { throw Self.convert(error) }
    }
    func insert(key: String, payload: Data, file: URL) async throws -> ChapterSourceSnapshot {
        let record = CKRecord(recordType: ChapterCloudTextTransport.recordType, recordID: id(key))
        record[ChapterCloudTextTransport.payloadField] = payload as NSData
        record[ChapterCloudTextTransport.assetField] = CKAsset(fileURL: file)
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        operation.savePolicy = .ifServerRecordUnchanged; operation.isAtomic = true
        let outcome = Mutex<Result<CKRecord, Error>?>(nil)
        let saved: CKRecord
        do {
            saved = try await perform(operation) { complete in
                operation.perRecordSaveBlock = { recordID, result in
                    outcome.withLock { $0 = recordID == record.recordID ? result : .failure(ChapterSourceTransportError.invalidRecord) }
                }
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success: complete(outcome.withLock { $0 } ?? .failure(ChapterSourceTransportError.invalidRecord))
                    case .failure(let error): complete(.failure(error))
                    }
                }
            }
        } catch { throw Self.convert(error) }
        return try Self.snapshot(saved, key: key, expectedID: id(key), requireAsset: false)
    }
    private static func convert(_ error: Error) -> Error { ChapterCloudTextTransport.classify(error) }
    private func perform<Value: Sendable>(_ operation: CKDatabaseOperation,
        configure: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        operation.qualityOfService = .utility
        let outcome = Mutex<Result<Value, Error>?>(nil), db = database
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                configure { result in outcome.withLock { if case .none = $0 { $0 = result } } }
                operation.completionBlock = { [weak operation] in
                    let result = outcome.withLock { value in
                        let saved = value; value = nil
                        return saved ?? .failure(operation?.isCancelled == true ? CancellationError() : ChapterSourceTransportError.cloud(.uncertain))
                    }
                    continuation.resume(with: result)
                }
                db.add(operation)
                if Task.isCancelled { operation.cancel() }
            }
        } onCancel: { operation.cancel() }
    }
}
