import Foundation
import CryptoKit
import Darwin

public enum ChapterWorkerJournalError: Error, Equatable {
    case closed, alreadyOpen, corrupt, storage, ambiguousWrite, budget, busy, disabled, staleGeneration, retryRequired
}
public enum ChapterWorkerFailure: String, Codable, Sendable { case source, renderer, output, storage }
public struct ChapterWorkerProgress: Codable, Sendable, Equatable {
    public let completedUnits, totalUnits: Int
    public init(completedUnits: Int, totalUnits: Int) throws {
        guard (1...4096).contains(totalUnits), (0...totalUnits).contains(completedUnits) else { throw ChapterWorkerJournalError.corrupt }
        self.completedUnits = completedUnits; self.totalUnits = totalUnits
    }
}
/// Live process token, never serialized or a distributed/time-based lease.
public struct ChapterWorkerGeneration: Sendable, Equatable {
    public let workerID, runID: UUID
    public let generation: UInt64
    public let renderKey: String
}
/// Metadata evidence, not playable audio, Reader acceptance or resumable model state.
public struct ChapterWorkerCheckpoint: Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case rendering, publishing, published, interrupted, failed }
    public let readSet: ChapterIntentReadSet
    public let generation: UInt64
    public let phase: Phase
    public let progress: ChapterWorkerProgress?
    public let plannedHandoff, completedHandoff: ChapterLocalHandoffReference?
    public let recoveryHandoff: ChapterLocalHandoffReference?
    public let failure: ChapterWorkerFailure?
}

/// Single local Worker process journal. Keep it owned until all producer tasks
/// join. It never opens Reader journals, expires leases by wall clock or accepts
/// audio into Reader playback. CloudKit/distributed claims are a separate protocol.
public actor ChapterWorkerJournal {
    public static let maximumEntries = 8192, maximumJournalBytes = 32 * 1024 * 1024
    private struct Entry: Codable {
        let readSet: ChapterIntentReadSet
        let generation: UInt64
        var phase: ChapterWorkerCheckpoint.Phase
        var progress: ChapterWorkerProgress?
        var plannedHandoff, completedHandoff: ChapterLocalHandoffReference?
        var recoveryHandoff: ChapterLocalHandoffReference?
        var failure: ChapterWorkerFailure?
        var checkpoint: ChapterWorkerCheckpoint { .init(readSet: readSet, generation: generation, phase: phase,
            progress: progress, plannedHandoff: plannedHandoff, completedHandoff: completedHandoff, recoveryHandoff: recoveryHandoff, failure: failure) }
    }
    private struct Body: Codable {
        let domain: String
        let version: Int
        let partition: String
        let workerID: UUID
        let lastGeneration: UInt64
        let entries: [String: Entry]
    }
    private struct Journal: Codable { let body: Body; let checksum: String }
    private struct MarkerBody: Codable { let domain: String; let version: Int; let partition: String; let workerID: UUID }
    private struct Marker: Codable { let body: MarkerBody; let checksum: String }
    private final class Ownership: Sendable {
        let directory, lock: Int32
        init(directory: Int32, lock: Int32) { self.directory = directory; self.lock = lock }
        deinit { Darwin.close(lock); Darwin.close(directory) }
        func validate() throws {
            var descriptor = stat(), path = stat()
            guard fstat(lock, &descriptor) == 0, fstatat(directory, "owner.lock", &path, AT_SYMLINK_NOFOLLOW) == 0,
                  descriptor.st_mode & S_IFMT == S_IFREG, descriptor.st_size == 0,
                  descriptor.st_dev == path.st_dev, descriptor.st_ino == path.st_ino else { throw ChapterWorkerJournalError.storage }
        }
    }
    public let accountPartition: String
    public let workerID: UUID
    public let runID = UUID()
    private var ownership: Ownership?
    private var entries: [String: Entry]
    private var lastGeneration: UInt64
    private var active: ChapterWorkerGeneration?
    private var activeSession: ChapterAccountSession?
    private var enabled = false, operationInFlight = false, uncertain = false
    private var afterRenameForTesting: (@Sendable () throws -> Void)?

    /// An existing app-owned Worker/State base, distinct from all Reader roots.
    /// File I/O runs on this actor; initialize off the UI actor.
    public init(directory: URL, accountPartition: String, workerID: UUID) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0), isDigest(accountPartition) else { throw ChapterWorkerError.invalidIdentity }
        let base = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw ChapterWorkerJournalError.storage }; defer { Darwin.close(base) }
        let account = try Self.child(base, accountPartition); defer { Darwin.close(account) }
        let dir = try Self.child(account, workerID.uuidString.lowercased())
        let lock = openat(dir, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { Darwin.close(dir); throw ChapterWorkerJournalError.storage }
        let owner = Ownership(directory: dir, lock: lock)
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == 0,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ChapterWorkerJournalError.alreadyOpen }
        // Never interpret a Reader's role-bound state as Worker state.
        var reader = stat()
        guard fstatat(dir, "authority-binding.json", &reader, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw ChapterWorkerJournalError.corrupt }
        let established = try Self.established(dir, partition: accountPartition, workerID: workerID)
        let loadedState = try Self.load(dir, partition: accountPartition, workerID: workerID, requireExisting: established)
        let loaded = loadedState.body
        if !established {
            if !loadedState.exists, try !Self.isFresh(dir) { throw ChapterWorkerJournalError.corrupt }
            let body = MarkerBody(domain: "librox-local-worker-binding-1", version: 1, partition: accountPartition, workerID: workerID)
            let marker = try Self.encode(Marker(body: body, checksum: Self.hash(Self.encode(body))))
            try Self.write(marker, directory: dir, leaf: "worker-established.json", immutable: true)
            if !loadedState.exists {
                try Self.write(Self.bytes(partition: accountPartition, worker: workerID, generation: 0, entries: [:]), directory: dir)
            }
        }
        var recovered = loaded.entries
        for (key, var entry) in recovered where entry.phase == .rendering || entry.phase == .publishing {
            entry.phase = .interrupted; recovered[key] = entry
        }
        if recovered.contains(where: { loaded.entries[$0.key]?.phase != $0.value.phase }) {
            try Self.write(Self.bytes(partition: accountPartition, worker: workerID, generation: loaded.lastGeneration, entries: recovered), directory: dir)
        }
        self.accountPartition = accountPartition; self.workerID = workerID
        ownership = owner; entries = recovered; lastGeneration = loaded.lastGeneration
    }
    public func setClaimsEnabled(_ value: Bool) throws { try writable(); enabled = value }
    public func checkpoint(for request: ChapterRenderRequest) throws -> ChapterWorkerCheckpoint? {
        try writable(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        return entries[try request.renderKey()]?.checkpoint
    }
    public func claim(_ readSet: ChapterIntentReadSet, authority: any ChapterIntentAuthority,
                      session: ChapterAccountSession, gate: ChapterAccountSessionGate) async throws -> ChapterWorkerGeneration {
        try enter(); defer { operationInFlight = false }
        guard enabled else { throw ChapterWorkerJournalError.disabled }
        guard active == nil else { throw ChapterWorkerJournalError.busy }
        guard session.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
        guard enabled else { throw ChapterWorkerJournalError.disabled }
        let key = try readSet.intent.request.renderKey(), old = entries[key]
        guard old?.phase != .failed || old?.readSet != readSet else { throw ChapterWorkerJournalError.retryRequired }
        guard lastGeneration < .max, old != nil || entries.count < Self.maximumEntries else { throw ChapterWorkerJournalError.budget }
        let token = ChapterWorkerGeneration(workerID: workerID, runID: runID, generation: lastGeneration + 1, renderKey: key)
        var next = entries
        next[key] = Entry(readSet: readSet, generation: token.generation, phase: .rendering,
            progress: nil, plannedHandoff: nil, completedHandoff: old?.completedHandoff,
            recoveryHandoff: old?.plannedHandoff ?? old?.recoveryHandoff, failure: nil)
        do {
            try persist(next, generation: token.generation); entries = next; lastGeneration = token.generation; active = token; activeSession = session
            try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
            guard enabled else { throw ChapterWorkerJournalError.disabled }
            try Task.checkCancellation(); return token
        } catch {
            // No producer could have started: this token has never been returned.
            if active == token {
                if !uncertain, var value = entries[key] {
                    value.phase = .interrupted; var stopped = entries; stopped[key] = value
                    do { try persist(stopped, generation: lastGeneration); entries = stopped } catch { uncertain = true }
                }
                active = nil; activeSession = nil
            }
            throw error
        }
    }
    public func validateBeforeWork(_ token: ChapterWorkerGeneration, authority: any ChapterIntentAuthority,
                                   session: ChapterAccountSession, gate: ChapterAccountSessionGate) async throws -> ChapterIntentReadSet {
        try enter(); defer { operationInFlight = false }
        let entry = try current(token, session: session)
        guard enabled else { throw ChapterWorkerJournalError.disabled }
        try await ChapterLocalIntentSnapshot.requireCurrent(entry.readSet, authority: authority, session: session, gate: gate)
        _ = try current(token); guard enabled else { throw ChapterWorkerJournalError.disabled }
        try Task.checkCancellation(); return entry.readSet
    }
    /// Counts are measured UI progress only. No partial audio/KV resume is inferred.
    public func recordProgress(_ progress: ChapterWorkerProgress, token: ChapterWorkerGeneration,
                               authority: any ChapterIntentAuthority, session: ChapterAccountSession,
                               gate: ChapterAccountSessionGate) async throws {
        try enter(); defer { operationInFlight = false }
        var entry = try current(token, session: session)
        guard entry.phase == .rendering, enabled else { throw ChapterWorkerJournalError.disabled }
        _ = try ChapterWorkerProgress(completedUnits: progress.completedUnits, totalUnits: progress.totalUnits)
        if let old = entry.progress {
            guard old.totalUnits == progress.totalUnits, old.completedUnits <= progress.completedUnits else { throw ChapterWorkerJournalError.corrupt }
        }
        try await ChapterLocalIntentSnapshot.requireCurrent(entry.readSet, authority: authority, session: session, gate: gate)
        _ = try current(token); guard enabled else { throw ChapterWorkerJournalError.disabled }
        entry.progress = progress; var next = entries; next[token.renderKey] = entry
        try persist(next, generation: lastGeneration); entries = next
        try await ChapterLocalIntentSnapshot.requireCurrent(entry.readSet, authority: authority, session: session, gate: gate)
        _ = try current(token); guard enabled else { throw ChapterWorkerJournalError.disabled }
    }
    public func beginPublication(_ token: ChapterWorkerGeneration, artifact: ChapterLocalArtifact,
                                 submission: ChapterSubmission, authority: any ChapterIntentAuthority,
                                 gate: ChapterAccountSessionGate) async throws -> ChapterLocalHandoffReference {
        try enter(); defer { operationInFlight = false }
        var entry = try current(token, session: submission.session)
        guard entry.phase == .rendering, enabled else { throw ChapterWorkerJournalError.disabled }
        guard try submission.request.renderKey() == token.renderKey,
              submission.request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        let reference = try ChapterLocalHandoff.contentReference(for: artifact, submission: submission)
        try await ChapterLocalIntentSnapshot.requireCurrent(entry.readSet, authority: authority, session: submission.session, gate: gate)
        _ = try current(token); guard enabled else { throw ChapterWorkerJournalError.disabled }
        entry.phase = .publishing; entry.plannedHandoff = reference
        var next = entries; next[token.renderKey] = entry
        try persist(next, generation: lastGeneration); entries = next
        try await ChapterLocalIntentSnapshot.requireCurrent(entry.readSet, authority: authority, session: submission.session, gate: gate)
        _ = try current(token); guard enabled else { throw ChapterWorkerJournalError.disabled }; return reference
    }
    /// Publication evidence remains separate from Reader intent acceptance/playback.
    public func recordPublished(_ publication: ChapterLocalHandoffPublication, token: ChapterWorkerGeneration,
                                authority: any ChapterIntentAuthority, gate: ChapterAccountSessionGate) async throws -> ChapterWorkerCheckpoint {
        try enter(); defer { operationInFlight = false }
        var entry = try current(token, session: publication.session)
        guard entry.phase == .publishing, entry.plannedHandoff == publication.reference,
              try publication.request.renderKey() == token.renderKey,
              publication.request.accountPartition == accountPartition else { throw ChapterWorkerJournalError.staleGeneration }
        try await ChapterLocalIntentSnapshot.requireCurrent(entry.readSet, authority: authority, session: publication.session, gate: gate)
        _ = try current(token)
        entry.phase = .published; entry.completedHandoff = publication.reference; entry.recoveryHandoff = nil
        var next = entries; next[token.renderKey] = entry
        try persist(next, generation: lastGeneration); entries = next
        // Physical publication never proves that every producer has joined.
        // Keep exclusive ownership until the explicit after-join operation.
        try await ChapterLocalIntentSnapshot.requireCurrent(entry.readSet, authority: authority, session: publication.session, gate: gate)
        try Task.checkCancellation(); return entry.checkpoint
    }
    /// Orchestrator MUST cancel and JOIN all producer tasks before this call.
    /// Revoked account gates do not prevent stopping the old private partition.
    public func relinquishAfterJoining(_ token: ChapterWorkerGeneration, failure: ChapterWorkerFailure? = nil) throws {
        try enter(); defer { operationInFlight = false }
        var entry = try current(token, allowPublished: true)
        if entry.phase == .published, failure == nil { active = nil; activeSession = nil; return }
        entry.phase = failure == nil ? .interrupted : .failed; entry.failure = failure
        var next = entries; next[token.renderKey] = entry
        try persist(next, generation: lastGeneration); entries = next; active = nil; activeSession = nil
    }
    /// Refuses to relinquish process ownership while work is still claimed.
    public func close() throws {
        guard !operationInFlight, active == nil else { throw ChapterWorkerJournalError.busy }
        ownership = nil
    }
    /// Error/restart path ONLY after all producers have joined. Does not guess
    /// an ambiguous on-disk outcome or rewrite old state; reopen reconciles it.
    public func closeAfterJoining(_ token: ChapterWorkerGeneration?) throws {
        guard !operationInFlight else { throw ChapterWorkerJournalError.busy }
        guard active == token else { throw ChapterWorkerJournalError.staleGeneration }
        active = nil; activeSession = nil; ownership = nil
    }
    func failAfterNextRenameForTesting() { afterRenameForTesting = { throw ChapterWorkerJournalError.storage } }
    private func writable() throws {
        guard let ownership else { throw ChapterWorkerJournalError.closed }
        try ownership.validate()
        guard !uncertain else { throw ChapterWorkerJournalError.ambiguousWrite }
    }
    private func enter() throws { try writable(); guard !operationInFlight else { throw ChapterWorkerJournalError.busy }; operationInFlight = true }
    private func current(_ token: ChapterWorkerGeneration, session: ChapterAccountSession? = nil, allowPublished: Bool = false) throws -> Entry {
        try writable()
        guard active == token, token.workerID == workerID, token.runID == runID,
              let entry = entries[token.renderKey], entry.generation == token.generation,
              entry.phase == .rendering || entry.phase == .publishing || (allowPublished && entry.phase == .published) else { throw ChapterWorkerJournalError.staleGeneration }
        if let session { guard activeSession == session else { throw ChapterWorkerError.accountMismatch } }
        return entry
    }
    private func persist(_ next: [String: Entry], generation: UInt64) throws {
        guard let ownership else { throw ChapterWorkerJournalError.closed }
        try ownership.validate()
        do {
            let bytes = try Self.bytes(partition: accountPartition, worker: workerID, generation: generation, entries: next)
            try Self.write(bytes, directory: ownership.directory) {
                let callback = self.afterRenameForTesting; self.afterRenameForTesting = nil; try callback?()
            }
        } catch ChapterWorkerJournalError.ambiguousWrite { uncertain = true; throw ChapterWorkerJournalError.ambiguousWrite }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func bytes(partition: String, worker: UUID, generation: UInt64, entries: [String: Entry]) throws -> Data {
        let body = Body(domain: "librox-local-worker-1", version: 1, partition: partition, workerID: worker, lastGeneration: generation, entries: entries)
        let bytes = try encode(Journal(body: body, checksum: hash(encode(body))))
        guard entries.count <= maximumEntries, bytes.count <= maximumJournalBytes else { throw ChapterWorkerJournalError.budget }; return bytes
    }
    private static func load(_ directory: Int32, partition: String, workerID: UUID, requireExisting: Bool) throws -> (body: Body, exists: Bool) {
        let fd = openat(directory, "journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT, !requireExisting else { throw ChapterWorkerJournalError.corrupt }
            return (.init(domain: "librox-local-worker-1", version: 1, partition: partition, workerID: workerID, lastGeneration: 0, entries: [:]), false)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_size > 0, initial.st_size <= maximumJournalBytes else { throw ChapterWorkerJournalError.corrupt }
        let bytes = try file.read(upToCount: maximumJournalBytes + 1) ?? Data()
        var after = stat(), path = stat()
        guard bytes.count == initial.st_size, fstat(fd, &after) == 0, fstatat(directory, "journal.json", &path, AT_SYMLINK_NOFOLLOW) == 0,
              same(initial, after), same(initial, path), initial.st_size == after.st_size,
              initial.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ChapterWorkerJournalError.corrupt }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: bytes) } catch { throw ChapterWorkerJournalError.corrupt }
        let b = journal.body
        guard b.domain == "librox-local-worker-1", b.version == 1, b.partition == partition, b.workerID == workerID,
              b.entries.count <= maximumEntries, try hash(encode(b)) == journal.checksum, try encode(journal) == bytes else { throw ChapterWorkerJournalError.corrupt }
        for (key, entry) in b.entries {
            guard entry.generation > 0, entry.generation <= b.lastGeneration,
                  entry.readSet.intent.request.accountPartition == partition, try entry.readSet.intent.request.renderKey() == key
            else { throw ChapterWorkerJournalError.corrupt }
            if let progress = entry.progress { _ = try ChapterWorkerProgress(completedUnits: progress.completedUnits, totalUnits: progress.totalUnits) }
            guard entry.phase != .rendering || entry.plannedHandoff == nil,
                  entry.phase != .publishing || entry.plannedHandoff != nil,
                  entry.phase != .published || (entry.completedHandoff != nil && entry.plannedHandoff == entry.completedHandoff),
                  (entry.phase == .failed) == (entry.failure != nil) else { throw ChapterWorkerJournalError.corrupt }
        }
        return (b, true)
    }
    private static func smallFile(_ directory: Int32, leaf: String) throws -> Data? {
        let fd = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { guard errno == ENOENT else { throw ChapterWorkerJournalError.corrupt }; return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var a = stat(), b = stat(), path = stat()
        guard fstat(fd, &a) == 0, a.st_mode & S_IFMT == S_IFREG, a.st_size > 0, a.st_size <= 16384 else { throw ChapterWorkerJournalError.corrupt }
        let bytes = try file.read(upToCount: 16385) ?? Data()
        guard bytes.count == a.st_size, fstat(fd, &b) == 0, fstatat(directory, leaf, &path, AT_SYMLINK_NOFOLLOW) == 0,
              same(a, b), same(a, path), a.st_size == b.st_size, a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec,
              a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec else { throw ChapterWorkerJournalError.corrupt }
        return bytes
    }
    private static func established(_ directory: Int32, partition: String, workerID: UUID) throws -> Bool {
        guard let bytes = try smallFile(directory, leaf: "worker-established.json") else { return false }
        let marker: Marker
        do { marker = try JSONDecoder().decode(Marker.self, from: bytes) } catch { throw ChapterWorkerJournalError.corrupt }
        guard marker.body.domain == "librox-local-worker-binding-1", marker.body.version == 1,
              marker.body.partition == partition, marker.body.workerID == workerID,
              try hash(encode(marker.body)) == marker.checksum, try encode(marker) == bytes else { throw ChapterWorkerJournalError.corrupt }
        return true
    }
    private static func isFresh(_ directory: Int32) throws -> Bool {
        let copy = dup(directory); guard copy >= 0 else { throw ChapterWorkerJournalError.storage }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw ChapterWorkerJournalError.storage }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else { guard errno == 0 else { throw ChapterWorkerJournalError.storage }; return true }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != "..", name != "owner.lock" { return false }
        }
    }
    private static func child(_ parent: Int32, _ name: String) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw ChapterWorkerJournalError.storage }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChapterWorkerJournalError.storage }
        guard fsync(parent) == 0 else { Darwin.close(fd); throw ChapterWorkerJournalError.storage }; return fd
    }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private static func write(_ bytes: Data, directory: Int32, leaf: String = "journal.json", immutable: Bool = false, afterRename: () throws -> Void = {}) throws {
        let name = ".worker-" + UUID().uuidString
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChapterWorkerJournalError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var identity = stat(); guard fstat(fd, &identity) == 0 else { throw ChapterWorkerJournalError.storage }
        defer { var path = stat(); if fstatat(directory, name, &path, AT_SYMLINK_NOFOLLOW) == 0, same(identity, path) { unlinkat(directory, name, 0) } }
        for start in stride(from: 0, to: bytes.count, by: 65536) {
            try autoreleasepool { try Task.checkCancellation(); try file.write(contentsOf: bytes[start..<min(start + 65536, bytes.count)]) }
        }
        if immutable, fchmod(fd, 0o400) != 0 { throw ChapterWorkerJournalError.storage }
        guard fsync(fd) == 0 else { throw ChapterWorkerJournalError.storage }
        try file.seek(toOffset: 0)
        var offset = 0
        while offset < bytes.count {
            try autoreleasepool {
                try Task.checkCancellation()
                let part = try file.read(upToCount: min(65536, bytes.count - offset)) ?? Data()
                guard !part.isEmpty, part == bytes[offset..<offset + part.count] else { throw ChapterWorkerJournalError.corrupt }
                offset += part.count
            }
        }
        var staged = stat(); guard fstatat(directory, name, &staged, AT_SYMLINK_NOFOLLOW) == 0, same(identity, staged) else { throw ChapterWorkerJournalError.storage }
        try Task.checkCancellation()
        if immutable {
            if linkat(directory, name, directory, leaf, 0) != 0 {
                guard errno == EEXIST, try smallFile(directory, leaf: leaf) == bytes else { throw ChapterWorkerJournalError.corrupt }
            }
        } else {
            guard renameat(directory, name, directory, leaf) == 0 else { throw ChapterWorkerJournalError.storage }
        }
        do { try afterRename(); guard fsync(directory) == 0 else { throw ChapterWorkerJournalError.storage } }
        catch { throw ChapterWorkerJournalError.ambiguousWrite }
    }
}
