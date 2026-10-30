import Foundation
import CryptoKit
import Darwin

public enum ChapterOutboxError: Error, Equatable {
    case closed, alreadyOpen, corrupt, budgetExceeded, storage, ambiguousWrite, unsupportedPolicy
}

/// A per-device local demand, not a CloudKit claim or acknowledgement.
public struct ChapterDemandIntent: Codable, Sendable, Equatable {
    public let request: ChapterRenderRequest
    public let deviceID: UUID
    public let revision: UInt64
    public let wanted: Bool
}
public struct ChapterConfirmedDemand: Sendable, Equatable {
    public let intent: ChapterDemandIntent
    public let serverRevision: ChapterServerRevision
}

/// Crash-safe local intent journal. It never renders, uploads, claims work or
/// marks an audio asset ready. A transport must reconcile a pending revision
/// with conditional server state before acknowledging that exact revision.
/// Open off the UI actor; one process/actor owns each account/device journal.
public actor ChapterDemandOutbox {
    public static let maximumEntries = 8192
    public static let maximumJournalBytes = 32 * 1024 * 1024
    private struct Entry: Codable, Equatable {
        let intent: ChapterDemandIntent
        var pending: Bool
        var serverRevision: String? = nil
    }
    private struct Journal: Codable {
        let version: Int
        let partition: String
        let deviceID: UUID
        let entries: [String: Entry]
        let checksum: String
    }
    private final class Ownership: Sendable {
        let directory: Int32
        let lock: Int32
        init(directory: Int32, lock: Int32) { self.directory = directory; self.lock = lock }
        deinit { Darwin.close(lock); Darwin.close(directory) }
    }
    public let accountPartition: String
    public let deviceID: UUID
    private var ownership: Ownership?
    private var entries: [String: Entry]
    private var uncertain = false
    // Exact crash boundary exercised by tests; no production injection API.
    private var afterRenameForTesting: (@Sendable () throws -> Void)?

    public init(directory: URL, accountPartition: String, deviceID: UUID) throws {
        try self.init(directory: directory, accountPartition: accountPartition, deviceID: deviceID,
                      afterAccountOpenForTesting: nil)
    }

    init(directory: URL, accountPartition: String, deviceID: UUID,
         afterAccountOpenForTesting: (@Sendable () throws -> Void)?) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0), isDigest(accountPartition)
        else { throw ChapterWorkerError.invalidIdentity }
        // The caller supplies an existing app-owned base. All descendants are
        // resolved relative to retained FDs, never re-resolved through ancestors.
        let base = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw ChapterOutboxError.storage }
        defer { Darwin.close(base) }
        let account = try Self.childDirectory(parent: base, name: accountPartition)
        defer { Darwin.close(account) }
        try afterAccountOpenForTesting?()
        let dir = try Self.childDirectory(parent: account, name: deviceID.uuidString.lowercased())
        let lock = openat(dir, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard lock >= 0 else { Darwin.close(dir); throw ChapterOutboxError.storage }
        let owner = Ownership(directory: dir, lock: lock)
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ChapterOutboxError.alreadyOpen }
        self.accountPartition = accountPartition; self.deviceID = deviceID
        entries = try Self.load(directory: dir, partition: accountPartition, deviceID: deviceID)
        ownership = owner
    }

    /// Same wanted value is idempotent, including after acknowledgement. Keep
    /// acknowledged tombstones so future cancel/re-request revisions never reset.
    @discardableResult
    public func setDemand(_ wanted: Bool, for request: ChapterRenderRequest) throws -> ChapterDemandIntent {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard request.recipe.watermarkRevision == "disabled-1" else { throw ChapterOutboxError.unsupportedPolicy }
        let key = try request.renderKey()
        if let old = entries[key], old.intent.wanted == wanted { return old.intent }
        guard entries[key] != nil || entries.count < Self.maximumEntries,
              (entries[key]?.intent.revision ?? 0) < .max else { throw ChapterOutboxError.budgetExceeded }
        let intent = ChapterDemandIntent(request: request, deviceID: deviceID,
            revision: (entries[key]?.intent.revision ?? 0) + 1, wanted: wanted)
        var next = entries; next[key] = Entry(intent: intent, pending: true)
        try persist(next); entries = next; return intent
    }

    public func pending() throws -> [ChapterDemandIntent] {
        try writable()
        return entries.sorted(by: { $0.key < $1.key }).compactMap { $0.value.pending ? $0.value.intent : nil }
    }

    /// Lost/late acknowledgements cannot remove a newer local cancellation or
    /// re-request. No remote delivery is inferred from this local operation.
    @discardableResult
    public func acknowledge(_ intent: ChapterDemandIntent) throws -> Bool {
        try writable(); try Task.checkCancellation()
        guard intent.deviceID == deviceID, intent.request.accountPartition == accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        let key = try intent.request.renderKey()
        guard var old = entries[key], old.intent == intent else { return false }
        guard old.pending else { return true }
        old.pending = false; var next = entries; next[key] = old
        try persist(next); entries = next; return true
    }

    /// Persist the server version and cleared pending bit in ONE journal save.
    /// Later batch failure/cancellation cannot lose an already accepted receipt.
    @discardableResult
    public func confirm(_ intent: ChapterDemandIntent, serverRevision: ChapterServerRevision) throws -> Bool {
        try writable(); try Task.checkCancellation()
        guard intent.deviceID == deviceID, intent.request.accountPartition == accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        let key = try intent.request.renderKey()
        guard var old = entries[key], old.intent == intent else { return false }
        if !old.pending, old.serverRevision == serverRevision.opaqueValue { return true }
        old.pending = false; old.serverRevision = serverRevision.opaqueValue
        var next = entries; next[key] = old
        try persist(next); entries = next; return true
    }

    /// Latest exact intent confirmation, replayable across batch errors and
    /// process/account-epoch reopen. Caller rebinds it to a freshly validated
    /// matching session; this version is not a new observation of server state.
    public func confirmation(for request: ChapterRenderRequest) throws -> ChapterConfirmedDemand? {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard let entry = entries[try request.renderKey()], !entry.pending, let version = entry.serverRevision else { return nil }
        return .init(intent: entry.intent, serverRevision: try .init(opaqueValue: version))
    }

    public func close() { ownership = nil }
    func failAfterNextRenameForTesting() { afterRenameForTesting = { throw ChapterOutboxError.storage } }
    func cancelAfterNextRenameForTesting() { afterRenameForTesting = { withUnsafeCurrentTask { $0?.cancel() } } }

    private func writable() throws {
        guard ownership != nil else { throw ChapterOutboxError.closed }
        guard !uncertain else { throw ChapterOutboxError.ambiguousWrite }
    }
    private static func childDirectory(parent: Int32, name: String) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST { throw ChapterOutboxError.storage }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChapterOutboxError.storage }
        guard fsync(parent) == 0 else { Darwin.close(fd); throw ChapterOutboxError.storage }
        return fd
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func load(directory: Int32, partition: String, deviceID: UUID) throws -> [String: Entry] {
        let descriptor = openat(directory, "journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw ChapterOutboxError.corrupt }
            return [:]
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= maximumJournalBytes else { throw ChapterOutboxError.corrupt }
        let bytes = try file.read(upToCount: maximumJournalBytes + 1) ?? Data()
        guard bytes.count == info.st_size else { throw ChapterOutboxError.corrupt }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: bytes) }
        catch { throw ChapterOutboxError.corrupt }
        guard journal.version == 1, journal.partition == partition, journal.deviceID == deviceID,
              journal.entries.count <= maximumEntries, digest(try encoded(journal.entries)) == journal.checksum
        else { throw ChapterOutboxError.corrupt }
        for (key, entry) in journal.entries {
            guard entry.intent.revision > 0, entry.intent.deviceID == deviceID,
                  entry.intent.request.accountPartition == partition,
                  entry.intent.request.recipe.watermarkRevision == "disabled-1",
                  try entry.intent.request.renderKey() == key else { throw ChapterOutboxError.corrupt }
            if let version = entry.serverRevision {
                guard !entry.pending else { throw ChapterOutboxError.corrupt }
                do { _ = try ChapterServerRevision(opaqueValue: version) }
                catch { throw ChapterOutboxError.corrupt }
            }
        }
        return journal.entries
    }

    private func persist(_ next: [String: Entry]) throws {
        guard let ownership else { throw ChapterOutboxError.closed }
        let data = try Self.encoded(Journal(version: 1, partition: accountPartition, deviceID: deviceID,
                                           entries: next, checksum: Self.digest(try Self.encoded(next))))
        guard data.count <= Self.maximumJournalBytes else { throw ChapterOutboxError.budgetExceeded }
        let name = ".pending-" + UUID().uuidString
        let fd = openat(ownership.directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ChapterOutboxError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(ownership.directory, name, 0) }
        try file.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw ChapterOutboxError.storage }
        try Task.checkCancellation()
        guard renameat(ownership.directory, name, ownership.directory, "journal.json") == 0
        else { throw ChapterOutboxError.storage }
        do {
            let hook = afterRenameForTesting; afterRenameForTesting = nil; try hook?()
            guard fsync(ownership.directory) == 0 else { throw ChapterOutboxError.storage }
        } catch {
            // Rename may have committed. Never accept another write based on
            // stale memory: close/reopen and reconcile the journal first.
            uncertain = true; throw ChapterOutboxError.ambiguousWrite
        }
    }
}
