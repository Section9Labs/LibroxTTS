import Foundation
import CloudKit
import Synchronization

/// Bounded native conditional metadata transaction. EVERY supplied record is
/// saved, including unchanged fence records, under its exact server change tag.
/// A fresh fence field forces those preconditions into the atomic server write.
struct ChapterCloudMetadataKey: Hashable, Sendable {
    let key, type: String
}
struct ChapterCloudMetadataWrite: Sendable {
    let key: ChapterCloudMetadataKey
    let expected: ChapterBookControlRecord?
    let payload: Data
}
protocol ChapterCloudMetadataStore: Sendable {
    func fetch(_ keys: [ChapterCloudMetadataKey]) async throws -> [String: ChapterBookControlRecord]
    func save(_ writes: [ChapterCloudMetadataWrite]) async throws -> [String: ChapterBookControlRecord]
}

actor NativeChapterCloudMetadataStore: ChapterCloudMetadataStore {
    static let maximumRecords = 40, maximumBytes = 128 * 1024
    private let database: CKDatabase
    private let zone = CKRecordZone.ID(zoneName: ChapterCloudDemandTransport.zoneName, ownerName: CKCurrentUserDefaultName)
    init(database: CKDatabase) { self.database = database }
    private func id(_ key: String) -> CKRecord.ID { .init(recordName: key, zoneID: zone) }
    private func validate(_ keys: [ChapterCloudMetadataKey]) throws {
        guard (1...Self.maximumRecords).contains(keys.count), Set(keys.map(\.key)).count == keys.count,
              keys.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 255 && !$0.type.isEmpty && $0.type.utf8.count <= 128 }) else {
            throw ChapterDemandTransportError.invalidRecord
        }
    }
    private nonisolated static func snapshot(_ record: CKRecord, id: CKRecord.ID, type: String) throws -> ChapterBookControlRecord {
        guard record.recordID == id, record.recordType == type, let tag = record.recordChangeTag,
              !tag.isEmpty, tag.utf8.count <= 1024, let bytes = record["payloadV1"] as? Data,
              !bytes.isEmpty, bytes.count <= maximumBytes else { throw ChapterDemandTransportError.invalidRecord }
        return .init(key: id.recordName, type: type, tag: tag, payload: bytes, lifetime: record)
    }
    func fetch(_ keys: [ChapterCloudMetadataKey]) async throws -> [String: ChapterBookControlRecord] {
        try validate(keys)
        let expected = Dictionary(uniqueKeysWithValues: keys.map { (id($0.key), $0.type) })
        let operation = CKFetchRecordsOperation(recordIDs: Array(expected.keys)); operation.desiredKeys = ["payloadV1"]
        let results = Mutex<[CKRecord.ID: Result<ChapterBookControlRecord?, Error>]>([:])
        do {
            return try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordResultBlock = { id, result in
                    let value: Result<ChapterBookControlRecord?, Error>
                    do {
                        guard let type = expected[id] else { throw ChapterDemandTransportError.invalidRecord }
                        switch result {
                        case .success(let record): value = .success(try Self.snapshot(record, id: id, type: type))
                        case .failure(let error):
                            if (error as? CKError)?.code == .unknownItem { value = .success(nil) } else { throw error }
                        }
                    } catch { value = .failure(error) }
                    results.withLock { $0[id] = value }
                }
                operation.fetchRecordsResultBlock = { result in
                    let values = results.withLock { value in let old = value; value.removeAll(); return old }
                    do {
                        for case .failure(let error) in values.values where !(error is CKError) { throw error }
                        guard Set(values.keys) == Set(expected.keys) else { throw ChapterDemandTransportError.uncertain }
                        switch result {
                        case .success: break
                        case .failure(let error):
                            guard (error as? CKError)?.code == .partialFailure,
                                  values.values.allSatisfy({ if case .success = $0 { return true }; return false }) else { throw error }
                        }
                        var found: [String: ChapterBookControlRecord] = [:]
                        for (id, value) in values { if let record = try value.get() { found[id.recordName] = record } }
                        complete(.success(found))
                    } catch { complete(.failure(error)) }
                }
            }
        } catch { throw Self.convert(error) }
    }
    func save(_ writes: [ChapterCloudMetadataWrite]) async throws -> [String: ChapterBookControlRecord] {
        try validate(writes.map(\.key))
        let nonce = UUID().uuidString.lowercased()
        var records: [CKRecord] = []
        for write in writes {
            guard !write.payload.isEmpty, write.payload.count <= Self.maximumBytes else { throw ChapterDemandTransportError.invalidRecord }
            let expectedID = id(write.key.key), record: CKRecord
            if let old = write.expected {
                guard old.key == write.key.key, old.type == write.key.type, let raw = old.lifetime,
                      raw.recordID == expectedID, raw.recordType == old.type, raw.recordChangeTag == old.tag,
                      raw["payloadV1"] as? Data == old.payload else { throw ChapterDemandTransportError.conflict }
                record = raw
            } else { record = CKRecord(recordType: write.key.type, recordID: expectedID) }
            record["payloadV1"] = write.payload as NSData; record["fenceV1"] = nonce as NSString
            records.append(record)
        }
        let expected = Dictionary(uniqueKeysWithValues: writes.map { (id($0.key.key), $0) })
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: [])
        operation.isAtomic = true; operation.savePolicy = .ifServerRecordUnchanged
        let results = Mutex<[CKRecord.ID: Result<ChapterBookControlRecord, Error>]>([:])
        do {
            return try await ChapterCloudOperation.run(operation, database: database) { complete in
                operation.perRecordSaveBlock = { id, result in
                    let saved: Result<ChapterBookControlRecord, Error>
                    do {
                        guard let write = expected[id] else { throw ChapterDemandTransportError.invalidRecord }
                        let value = try Self.snapshot(result.get(), id: id, type: write.key.type)
                        guard value.payload == write.payload else { throw ChapterDemandTransportError.invalidRecord }
                        saved = .success(value)
                    } catch { saved = .failure(error) }
                    results.withLock { $0[id] = saved }
                }
                operation.modifyRecordsResultBlock = { result in
                    let values = results.withLock { value in let old = value; value.removeAll(); return old }
                    do {
                        for case .failure(let error) in values.values where !(error is CKError) { throw error }
                        try result.get()
                        guard Set(values.keys) == Set(expected.keys) else { throw ChapterDemandTransportError.uncertain }
                        var found: [String: ChapterBookControlRecord] = [:]
                        for (id, value) in values { found[id.recordName] = try value.get() }
                        complete(.success(found))
                    } catch { complete(.failure(error)) }
                }
            }
        } catch { throw Self.convert(error) }
    }
    private nonisolated static func convert(_ error: Error) -> Error {
        guard let cloud = error as? CKError else { return error }
        return ChapterCloudDemandTransport.classify(cloud)
    }
}
