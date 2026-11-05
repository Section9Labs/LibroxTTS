import Foundation
import CloudKit
import CryptoKit
import Synchronization
import LibroxChapterWorker

/// Read-only projection of Librox's existing SwiftData mirror. It never creates
/// a second ModelContainer or writes Core Data's managed CloudKit records.
public struct ChatterboxCloudLibraryBook: Identifiable, Sendable {
    public let id: String
    public let libraryID: String
    public let title: String
    public let author: String?
    public let format: String
    public let contentSHA256: String?
    public let lastOpened: Date?
    public let dateAdded: Date
    public let isFinished: Bool
    public let progress: Double
    let recordID: CKRecord.ID
    public var canPrepare: Bool { ["epub", "txt"].contains(format) }
    init?(_ record: CKRecord) {
        guard record.recordType == "CD_StoredBook", let title = record["CD_title"] as? String,
              let format = record["CD_formatRaw"] as? String else { return nil }
        recordID = record.recordID
        id = record.recordID.zoneID.zoneName + "/" + record.recordID.recordName
        libraryID = record["CD_id"] as? String ?? record.recordID.recordName
        self.title = title.isEmpty ? "Untitled Book" : title
        author = record["CD_author"] as? String
        self.format = format.lowercased()
        contentSHA256 = (record["CD_contentHash"] as? String)?.lowercased()
        lastOpened = record["CD_lastOpened"] as? Date
        dateAdded = record["CD_dateAdded"] as? Date ?? .distantPast
        isFinished = (record["CD_isFinished"] as? NSNumber)?.boolValue ?? false
        let value = (record["CD_progressPercent"] as? NSNumber)?.doubleValue ?? 0
        progress = value.isFinite ? min(1, max(0, value)) : 0
    }
}

public enum ChatterboxCloudLibraryError: LocalizedError {
    case missingFile, changedFile, tooLarge, invalidRecord
    public var errorDescription: String? {
        switch self {
        case .missingFile: "This book's file has not reached iCloud yet. Open Librox on the device that imported it and let it sync."
        case .changedFile: "This book changed during download. Refresh your library and select it again."
        case .tooLarge: "This book exceeds the companion's 100 MB file limit."
        case .invalidRecord: "This library record could not be verified. Refresh your library and try again."
        }
    }
}

public actor ChatterboxCloudLibrary {
    private let database: CKDatabase
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let directory: ChapterCloudDirectory
    private nonisolated let operations = ChatterboxCloudOperations()
    private var tokens: [CKRecordZone.ID: CKServerChangeToken] = [:]
    private var rows: [String: ChatterboxCloudLibraryBook] = [:]
    private var refreshing = false
    private static let keys = ["CD_title", "CD_id", "CD_author", "CD_formatRaw", "CD_contentHash",
                               "CD_lastOpened", "CD_dateAdded", "CD_isFinished", "CD_progressPercent"]

    public init(container: CKContainer, account: ChapterCloudAccountIdentity,
                session: ChapterAccountSession, gate: ChapterAccountSessionGate) throws {
        guard container.containerIdentifier == account.containerIdentifier,
              account.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        database = container.privateCloudDatabase; self.session = session; self.gate = gate
        directory = try ChapterCloudDirectory(container: container, account: account, session: session,
            gate: gate, authorize: { try await gate.validate(session) })
    }
    public func preparationRequests() async throws -> [ChatterboxCloudBookSummary] {
        try await check()
        return try await operations.run { [directory] in
            var result: [ChatterboxCloudBookSummary] = []
            for book in try await directory.books() {
                let sets = try await directory.readSets(scopeID: book.scopeID)
                result.append(.init(scopeID: book.scopeID, title: book.title, requested: !sets.isEmpty))
            }
            return result
        }
    }
    private func check() async throws { try operations.check(); try await gate.validate(session) }
    public func queueSchemaAvailable() async throws -> Bool {
        try await check()
        return try await operations.run { [database] in
            let op = CKQueryOperation(query: CKQuery(recordType: "LibroxStockCatalogV1", predicate: NSPredicate(value: true)))
            op.resultsLimit = 1; op.desiredKeys = []
            do {
                let _: Void = try await ChapterCloudOperation.run(op, database: database) { done in
                    op.queryResultBlock = { done($0.map { _ in () }) }
                }
                return true
            } catch let error as CKError {
                if error.code == .unknownItem { return false }
                // No query index is needed by the ID-based narration protocol.
                if error.code == .invalidArguments, error.localizedDescription.contains("not marked queryable") { return true }
                throw error
            }
        }
    }
    public func refresh() async throws -> [ChatterboxCloudLibraryBook] {
        try await check()
        guard !refreshing else { return sortedBooks() }
        refreshing = true; defer { refreshing = false }
        return try await operations.run { try await self.refreshOwned() }
    }
    private func sortedBooks() -> [ChatterboxCloudLibraryBook] {
        rows.values.sorted {
            let a = $0.lastOpened ?? .distantPast, b = $1.lastOpened ?? .distantPast
            if a != b { return a > b }
            return $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded > $1.dateAdded
        }
    }
    private func refreshOwned() async throws -> [ChatterboxCloudLibraryBook] {
        let op = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        let found = Mutex<[CKRecordZone.ID]>([])
        let zones: [CKRecordZone.ID] = try await ChapterCloudOperation.run(op, database: database) { done in
            op.perRecordZoneResultBlock = { id, result in
                if case .success = result { found.withLock { $0.append(id) } }
            }
            op.fetchRecordZonesResultBlock = { result in done(result.map { _ in found.withLock { $0 } }) }
        }
        try await check()
        let libraryZones = zones.filter { $0.zoneName.hasPrefix("com.apple.coredata.cloudkit.zone") }
        let live = Set(libraryZones)
        rows = rows.filter { live.contains($0.value.recordID.zoneID) }
        tokens = tokens.filter { live.contains($0.key) }
        for zone in libraryZones {
            do { try await fetchChanges(zone) }
            catch let error as CKError where error.code == .changeTokenExpired {
                tokens[zone] = nil
                rows = rows.filter { $0.value.recordID.zoneID != zone }
                try await fetchChanges(zone)
            }
        }
        try await check(); return sortedBooks()
    }
    private struct Changes: Sendable {
        var records: [ChatterboxCloudLibraryBook] = []
        var deleted: [CKRecord.ID] = []
        var token: CKServerChangeToken?
        var error: (any Error)?
    }
    private func fetchChanges(_ zone: CKRecordZone.ID) async throws {
        let state = Mutex(Changes())
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = tokens[zone]; config.desiredKeys = Self.keys
        let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zone], configurationsByRecordZoneID: [zone: config])
        op.fetchAllChanges = true
        let change: Changes = try await ChapterCloudOperation.run(op, database: database) { done in
            op.recordWasChangedBlock = { _, result in
                state.withLock { value in
                    switch result {
                    case .success(let record):
                        if let book = ChatterboxCloudLibraryBook(record) {
                            if value.records.count < 10_000 { value.records.append(book) }
                            else { value.error = ChatterboxCloudLibraryError.tooLarge }
                        }
                    case .failure(let error): value.error = error
                    }
                }
            }
            op.recordWithIDWasDeletedBlock = { id, _ in state.withLock { $0.deleted.append(id) } }
            op.recordZoneFetchResultBlock = { _, result in
                state.withLock { value in
                    switch result {
                    case .success(let result): value.token = result.serverChangeToken
                    case .failure(let error): value.error = error
                    }
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                done(result.flatMap { _ in state.withLock { $0.error.map(Result.failure) ?? .success($0) } })
            }
        }
        try await check()
        for id in change.deleted { rows.removeValue(forKey: id.zoneID.zoneName + "/" + id.recordName) }
        for book in change.records { rows[book.id] = book }
        tokens[zone] = change.token
    }
    /// Copies the selected CKAsset while its callback owns the staging file,
    /// then verifies the original book hash before returning a private URL.
    public func download(_ book: ChatterboxCloudLibraryBook, to directory: URL) async throws -> URL {
        try await check()
        guard book.canPrepare, rows[book.id]?.contentSHA256 == book.contentSHA256 else {
            throw ChatterboxCloudLibraryError.changedFile
        }
        return try await operations.run { [database, session, gate] in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(book.format)
            do {
                let op = CKFetchRecordsOperation(recordIDs: [book.recordID])
                op.desiredKeys = ["CD_fileData", "CD_fileData_ckAsset", "CD_contentHash"]
                let state = Mutex<Result<URL, Error>?>(nil)
                let captured: URL = try await ChapterCloudOperation.run(op, database: database) { done in
                    op.perRecordResultBlock = { _, result in
                        let captured = Result<URL, Error> {
                            let record = try result.get()
                            guard (record["CD_contentHash"] as? String)?.lowercased() == book.contentSHA256 else {
                                throw ChatterboxCloudLibraryError.changedFile
                            }
                            let limit = 100 * 1024 * 1024
                            if let asset = (record["CD_fileData"] as? CKAsset) ?? (record["CD_fileData_ckAsset"] as? CKAsset),
                               let url = asset.fileURL {
                                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= limit else { throw ChatterboxCloudLibraryError.tooLarge }
                                try FileManager.default.copyItem(at: url, to: file)
                            } else if let bytes = record["CD_fileData"] as? Data {
                                guard bytes.count <= limit else { throw ChatterboxCloudLibraryError.tooLarge }
                                try bytes.write(to: file, options: .withoutOverwriting)
                            } else { throw ChatterboxCloudLibraryError.missingFile }
                            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
                            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                            if let expected = book.contentSHA256, digest != expected { throw ChatterboxCloudLibraryError.changedFile }
                            return file
                        }
                        state.withLock { $0 = captured }
                    }
                    op.fetchRecordsResultBlock = { result in
                        done(result.flatMap { _ in state.withLock { $0 ?? .failure(ChatterboxCloudLibraryError.missingFile) } })
                    }
                }
                try Task.checkCancellation(); try await gate.validate(session); return captured
            } catch { try? FileManager.default.removeItem(at: file); throw error }
        }
    }
    public nonisolated func stopRequests() { operations.stop() }
    public func close() async { await operations.join(); rows.removeAll(); tokens.removeAll() }
}
