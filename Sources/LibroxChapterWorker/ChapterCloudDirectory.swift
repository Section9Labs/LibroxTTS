import Foundation
import CloudKit

/// Discovery is a hint only. Work and publication still compare the complete
/// current membership transaction in ChapterCloudBookWorkTransport.
package struct ChapterCloudBookListing: Codable, Sendable, Equatable {
    package let scopeID: String
    package let title: String
    package init(scopeID: String, title: String) throws {
        guard isDigest(scopeID), !title.isEmpty, title.utf8.count <= 1024 else {
            throw ChapterWorkerError.invalidIdentity
        }
        self.scopeID = scopeID; self.title = title
    }
}

package actor ChapterCloudDirectory {
    private struct Failure: Codable { let version: Int; let account, scope: String; let message: String? }
    private struct Directory: Codable { var version = 1; var books: [ChapterCloudBookListing] = [] }
    private let database: CKDatabase
    private let store: NativeChapterCloudMetadataStore
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let authorize: @Sendable () async throws -> Void
    private let directoryKey = ChapterCloudMetadataKey(key: "book-directory-1", type: "LibroxBookDirectoryV1")
    private let catalogKey = ChapterCloudMetadataKey(key: "stock-catalog-1", type: "LibroxStockCatalogV1")

    package init(container: CKContainer, account: ChapterCloudAccountIdentity,
                 session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                 authorize: @escaping @Sendable () async throws -> Void) throws {
        guard container.containerIdentifier == account.containerIdentifier,
              session.accountPartition == account.accountPartition else { throw ChapterWorkerError.accountMismatch }
        database = container.privateCloudDatabase
        store = NativeChapterCloudMetadataStore(database: container.privateCloudDatabase)
        self.session = session; self.gate = gate; self.authorize = authorize
    }
    private func check() async throws {
        try Task.checkCancellation(); try await gate.validate(session)
        try await authorize(); try await gate.validate(session); try Task.checkCancellation()
    }
    /// Explicit connection setup, called only after the user enables iCloud.
    package func prepareZone() async throws {
        try await check()
        let zone = CKRecordZone(zoneName: ChapterCloudDemandTransport.zoneName)
        let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: [])
        let _: Void = try await ChapterCloudOperation.run(operation, database: database) { complete in
            operation.modifyRecordZonesResultBlock = { complete($0) }
        }
        try await check()
    }
    package func books() async throws -> [ChapterCloudBookListing] {
        try await check()
        guard let record = try await store.fetch([directoryKey])[directoryKey.key] else { return [] }
        let value = try ChapterBookWorkWire.decode(Directory.self, record.payload)
        guard value.version == 1, value.books.count <= 64,
              Set(value.books.map(\.scopeID)).count == value.books.count else { throw ChapterWorkerError.invalidManifest }
        for book in value.books { _ = try ChapterCloudBookListing(scopeID: book.scopeID, title: book.title) }
        try await check(); return value.books
    }
    package func list(_ book: ChapterCloudBookListing) async throws {
        for attempt in 0..<4 {
            try await check()
            let old = try await store.fetch([directoryKey])[directoryKey.key]
            var value = try old.map { try ChapterBookWorkWire.decode(Directory.self, $0.payload) } ?? Directory()
            guard value.version == 1, value.books.count <= 64 else { throw ChapterWorkerError.invalidManifest }
            if value.books.contains(where: { $0.scopeID == book.scopeID }) { return }
            guard value.books.count < 64 else { throw ChapterBookJournalError.budget }
            value.books.append(book)
            do {
                _ = try await store.save([.init(key: directoryKey, expected: old, payload: ChapterBookWorkWire.encode(value))])
                try await check(); return
            } catch ChapterDemandTransportError.conflict where attempt < 3 { continue }
        }
        throw ChapterDemandTransportError.conflict
    }
    package func catalog() async throws -> Data? {
        try await check()
        let bytes = try await store.fetch([catalogKey])[catalogKey.key]?.payload
        try await check(); return bytes
    }
    package func publishCatalog(_ bytes: Data) async throws {
        try await check()
        let old = try await store.fetch([catalogKey])[catalogKey.key]
        if old?.payload == bytes { return }
        _ = try await store.save([.init(key: catalogKey, expected: old, payload: bytes)])
        try await check()
    }
    package func failure(scopeID: String) async throws -> String? {
        guard isDigest(scopeID) else { throw ChapterWorkerError.invalidIdentity }
        try await check()
        let key = ChapterCloudMetadataKey(key: "book-failure-" + scopeID, type: "LibroxBookFailureV1")
        guard let record = try await store.fetch([key])[key.key] else { return nil }
        let value = try ChapterBookWorkWire.decode(Failure.self, record.payload)
        guard value.version == 1, value.account == session.accountPartition, value.scope == scopeID,
              (value.message?.utf8.count ?? 0) <= 4096 else { throw ChapterWorkerError.invalidManifest }
        try await check(); return value.message
    }
    package func reportFailure(_ message: String?, scopeID: String) async throws {
        guard isDigest(scopeID), (message?.utf8.count ?? 0) <= 4096 else { throw ChapterWorkerError.invalidIdentity }
        try await check()
        let key = ChapterCloudMetadataKey(key: "book-failure-" + scopeID, type: "LibroxBookFailureV1")
        let old = try await store.fetch([key])[key.key]
        let bytes = try ChapterBookWorkWire.encode(Failure(version: 1, account: session.accountPartition, scope: scopeID, message: message))
        if old?.payload == bytes { return }
        _ = try await store.save([.init(key: key, expected: old, payload: bytes)])
        try await check()
    }
    /// Read authoritative current member pointers, never directory metadata.
    package func readSets(scopeID: String) async throws -> [ChapterBookReadSetIdentity] {
        guard isDigest(scopeID) else { throw ChapterWorkerError.invalidIdentity }
        try await check()
        let rootKey = ChapterCloudBookWorkTransport.root(scopeID)
        guard let first = try await store.fetch([rootKey])[rootKey.key] else { return [] }
        let root = try ChapterBookCloudControl.decode(ChapterBookCloudRoot.self, first.payload)
        try root.validate(account: session.accountPartition, scope: scopeID)
        let keys = root.members.keys.sorted().map { ChapterCloudBookWorkTransport.member(scopeID, UUID(uuidString: $0)!) }
        let records = try await store.fetch([rootKey] + keys)
        guard records[rootKey.key]?.tag == first.tag else { throw ChapterDemandTransportError.conflict }
        var identities: [ChapterBookReadSetIdentity] = []
        for key in keys {
            guard let record = records[key.key] else { throw ChapterDemandTransportError.inconsistentSnapshot }
            let member = try ChapterBookCloudControl.decode(ChapterBookCloudDevice.self, record.payload)
            try member.validate(account: session.accountPartition, scope: scopeID, device: member.intent.deviceID)
            guard key == ChapterCloudBookWorkTransport.member(scopeID, member.intent.deviceID),
                  root.members[member.intent.deviceID.uuidString.lowercased()] == (try ChapterBookCloudControl.digest(member)) else {
                throw ChapterDemandTransportError.inconsistentSnapshot
            }
            if member.intent.wanted, let identity = member.readSet { identities.append(identity) }
        }
        try await check(); return identities
    }
}
