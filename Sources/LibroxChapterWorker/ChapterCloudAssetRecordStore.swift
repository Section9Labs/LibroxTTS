import Foundation
import CloudKit
import Synchronization

/// Private native wire primitive. Typed callers admit exact canonical metadata
/// BEFORE asking for capture. No public arbitrary-file upload or work grant.
struct ChapterCloudAssetSnapshot: Sendable {
    let key, tag: String
    let metadata: Data
    let file: ChapterCloudFileCapture?
}
struct ChapterCloudAssetCapture: Sendable {
    let expected: ChapterCloudAssetSnapshot
    let bytes: Int64
    let sha256: String
    let maximum: Int64
    let session: ChapterAccountSession
    let storage: URL
}
protocol ChapterCloudAssetStore: Sendable {
    func fetch(key: String, capture: ChapterCloudAssetCapture?) async throws -> ChapterCloudAssetSnapshot?
    func insert(key: String, metadata: Data, asset: URL) async throws -> ChapterCloudAssetSnapshot
}
actor NativeChapterCloudAssetStore: ChapterCloudAssetStore {
    private let database: CKDatabase
    private let recordType, prefix, metadataField, assetField: String
    private let zone = CKRecordZone.ID(zoneName: ChapterCloudDemandTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    init(database: CKDatabase, recordType: String, prefix: String, metadataField: String = "manifestV1", assetField: String = "contentV1") {
        self.database = database; self.recordType = recordType; self.prefix = prefix
        self.metadataField = metadataField; self.assetField = assetField
    }
    private func id(_ key: String) throws -> CKRecord.ID {
        guard key.hasPrefix(prefix), isDigest(String(key.dropFirst(prefix.count))) else { throw ChapterWorkerError.invalidIdentity }
        return .init(recordName: key, zoneID: zone)
    }
    private nonisolated static func snapshot(_ record: CKRecord, expected: CKRecord.ID,
                                             type: String, field: String) throws -> ChapterCloudAssetSnapshot {
        guard record.recordID == expected, record.recordType == type,
              let tag = record.recordChangeTag, !tag.isEmpty, tag.utf8.count <= 1024,
              let bytes = record[field] as? Data, !bytes.isEmpty, bytes.count <= 4096 else { throw ChapterDemandTransportError.invalidRecord }
        return .init(key: expected.recordName, tag: tag, metadata: bytes, file: nil)
    }
    func fetch(key: String, capture: ChapterCloudAssetCapture?) async throws -> ChapterCloudAssetSnapshot? {
        let recordID = try id(key), type = recordType, field = metadataField, assetField = assetField
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        operation.desiredKeys = [field] + (capture == nil ? [] : [assetField])
        let outcome = Mutex<Result<ChapterCloudAssetSnapshot?, Error>?>(nil)
        do {
            return try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordResultBlock = { [weak operation] foundID, result in
                    let value: Result<ChapterCloudAssetSnapshot?, Error>
                    do {
                        guard foundID == recordID else { throw ChapterDemandTransportError.invalidRecord }
                        switch result {
                        case .failure(let error):
                            if (error as? CKError)?.code == .unknownItem { value = .success(nil) } else { throw error }
                        case .success(let record):
                            let metadata = try Self.snapshot(record, expected: recordID, type: type, field: field)
                            if let capture {
                                guard capture.expected.key == key, metadata.tag == capture.expected.tag,
                                      metadata.metadata == capture.expected.metadata,
                                      let url = (record[assetField] as? CKAsset)?.fileURL else { throw ChapterDemandTransportError.conflict }
                                let file = try ChapterCloudFileCapture.capture(download: url,
                                    expectedBytes: capture.bytes, expectedSHA256: capture.sha256, maximum: capture.maximum,
                                    session: capture.session, storageDirectory: capture.storage, check: {
                                        guard let operation, !operation.isCancelled else { throw CancellationError() }
                                    })
                                value = .success(.init(key: key, tag: metadata.tag, metadata: metadata.metadata, file: file))
                            } else { value = .success(metadata) }
                        }
                    } catch { value = .failure(error) }
                    outcome.withLock { $0 = value }
                }
                operation.fetchRecordsResultBlock = { result in
                    let saved = outcome.withLock { value in let old = value; value = nil; return old }
                    switch result {
                    case .success: complete(saved ?? .failure(ChapterDemandTransportError.invalidRecord))
                    case .failure(let error):
                        if case .failure(let local)? = saved, !(local is CKError) { complete(.failure(local)); return }
                        if (error as? CKError)?.code == .partialFailure, case .success(.none)? = saved { complete(.success(nil)) }
                        else { complete(.failure(error)) }
                    }
                }
            }
        } catch { throw Self.convert(error) }
    }
    func insert(key: String, metadata: Data, asset: URL) async throws -> ChapterCloudAssetSnapshot {
        let recordID = try id(key)
        guard !metadata.isEmpty, metadata.count <= 4096 else { throw ChapterDemandTransportError.invalidRecord }
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record[metadataField] = metadata as NSData; record[assetField] = CKAsset(fileURL: asset)
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        operation.isAtomic = true; operation.savePolicy = .ifServerRecordUnchanged
        let outcome = Mutex<Result<CKRecord, Error>?>(nil)
        do {
            let saved: CKRecord = try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordSaveBlock = { foundID, result in
                    outcome.withLock { $0 = foundID == recordID ? result : .failure(ChapterDemandTransportError.invalidRecord) }
                }
                operation.modifyRecordsResultBlock = { result in
                    let saved = outcome.withLock { value in let old = value; value = nil; return old }
                    switch result {
                    case .success: complete(saved ?? .failure(ChapterDemandTransportError.invalidRecord))
                    case .failure(let error):
                        if case .failure(let local)? = saved, !(local is CKError) { complete(.failure(local)) }
                        else { complete(.failure(error)) }
                    }
                }
            }
            return try Self.snapshot(saved, expected: recordID, type: recordType, field: metadataField)
        } catch { throw Self.convert(error) }
    }
    private static func convert(_ error: Error) -> Error {
        if error is CKError { return ChapterCloudDemandTransport.classify(error) }; return error
    }
}
