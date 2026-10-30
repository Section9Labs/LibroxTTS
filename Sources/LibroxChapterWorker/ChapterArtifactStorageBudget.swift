import Foundation
import Darwin

public enum ChapterStorageBudgetError: Error, Equatable {
    case invalidConfiguration, closed, alreadyOpen, busy, staleReservation, unsafeEntry, inventoryLimit, capacity, freeSpace, storage
}
public struct ChapterStorageBudgetPolicy: Sendable {
    public let maximumManagedBytes, minimumAvailableBytes: UInt64
    public let maximumEntries, maximumDepth, maximumReservations: Int
    public init(maximumManagedBytes: UInt64, minimumAvailableBytes: UInt64,
                maximumEntries: Int = 100_000, maximumDepth: Int = 32, maximumReservations: Int = 8) throws {
        guard maximumManagedBytes > 0, maximumManagedBytes <= UInt64(Int64.max), minimumAvailableBytes <= UInt64(Int64.max),
              (1...1_000_000).contains(maximumEntries), (1...64).contains(maximumDepth), (1...32).contains(maximumReservations) else { throw ChapterStorageBudgetError.invalidConfiguration }
        self.maximumManagedBytes = maximumManagedBytes; self.minimumAvailableBytes = minimumAvailableBytes
        self.maximumEntries = maximumEntries; self.maximumDepth = maximumDepth; self.maximumReservations = maximumReservations
    }
}
public struct ChapterStorageInventory: Sendable, Equatable {
    public let logicalBytes: UInt64
    public let regularFiles, directories: Int
    /// Minimum observed available bytes among managed volumes, not reserved OS space.
    public let minimumVolumeAvailableBytes: UInt64
}
/// Admission allowance, not a kernel allocation or proof a producer honored a write cap.
public struct ChapterStorageReservation: Sendable, Equatable {
    let owner, id: UUID
    public let bytes: UInt64
}

/// One owner of explicitly supplied app-private artifact roots. Never scans a
/// library/model tree implicitly and NEVER evicts, rewrites or deletes entries.
/// Producer write bounds and settle-after-join integration remain caller duties.
public actor ChapterArtifactStorageBudget {
    private struct Pin: Sendable {
        let supplied, resolved: URL
        let device: Int32
        let inode: UInt64
        init(_ url: URL) throws {
            guard url.isFileURL, url.standardizedFileURL.path != "/", !url.path.utf8.contains(0) else { throw ChapterStorageBudgetError.invalidConfiguration }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            var a = stat(), b = stat()
            guard lstat(url.path, &a) == 0, lstat(resolved.path, &b) == 0,
                  a.st_mode & S_IFMT == S_IFDIR, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw ChapterStorageBudgetError.invalidConfiguration }
            supplied = url; self.resolved = resolved; device = a.st_dev; inode = a.st_ino
        }
        func validate() throws {
            var a = stat(), b = stat()
            guard lstat(supplied.path, &a) == 0, lstat(resolved.path, &b) == 0,
                  a.st_mode & S_IFMT == S_IFDIR, b.st_mode & S_IFMT == S_IFDIR,
                  a.st_dev == device, b.st_dev == device, a.st_ino == inode, b.st_ino == inode else { throw ChapterStorageBudgetError.unsafeEntry }
        }
    }
    private final class Ownership: Sendable {
        let directory, lock: Int32
        init(directory: Int32, lock: Int32) { self.directory = directory; self.lock = lock }
        deinit { Darwin.close(lock); Darwin.close(directory) }
        func validate() throws {
            var a = stat(), b = stat()
            guard fstat(lock, &a) == 0, fstatat(directory, "artifact-budget.lock", &b, AT_SYMLINK_NOFOLLOW) == 0,
                  a.st_mode & S_IFMT == S_IFREG, a.st_size == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw ChapterStorageBudgetError.storage }
        }
    }
    public let policy: ChapterStorageBudgetPolicy
    private let pins: [Pin], control: Pin
    private let ownerID = UUID()
    private var ownership: [Ownership]?
    private var reservations: [UUID: UInt64] = [:]
    private var inventoryTask: Task<ChapterStorageInventory, Error>?
    private var beforeScanForTesting: (@Sendable () async -> Void)?
    private var beforeSettlementCommitForTesting: (@Sendable () async -> Void)?

    public init(controlDirectory: URL, managedDirectories: [URL], policy: ChapterStorageBudgetPolicy) throws {
        guard (1...8).contains(managedDirectories.count) else { throw ChapterStorageBudgetError.invalidConfiguration }
        let pins = try managedDirectories.map(Pin.init), control = try Pin(controlDirectory)
        for a in pins.indices {
            for b in pins.indices where b > a {
                let x = pins[a], y = pins[b]
                guard !(x.device == y.device && x.inode == y.inode), x.resolved.path != y.resolved.path,
                      !x.resolved.path.hasPrefix(y.resolved.path + "/"), !y.resolved.path.hasPrefix(x.resolved.path + "/")
                else { throw ChapterStorageBudgetError.invalidConfiguration }
            }
        }
        guard pins.contains(where: { $0.device == control.device && $0.inode == control.inode }) else { throw ChapterStorageBudgetError.invalidConfiguration }
        var owners: [Ownership] = []
        // Every exact managed root is locked, so changing controlDirectory cannot
        // create a second independent allowance over the same configured root.
        for pin in pins {
            let fd = Darwin.open(pin.supplied.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ChapterStorageBudgetError.storage }
            var identity = stat()
            guard fstat(fd, &identity) == 0, identity.st_dev == pin.device, identity.st_ino == pin.inode else {
                Darwin.close(fd); throw ChapterStorageBudgetError.unsafeEntry
            }
            let lock = openat(fd, "artifact-budget.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard lock >= 0 else { Darwin.close(fd); throw ChapterStorageBudgetError.storage }
            let owner = Ownership(directory: fd, lock: lock)
            try owner.validate()
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ChapterStorageBudgetError.alreadyOpen }
            try pin.validate(); owners.append(owner)
        }
        self.pins = pins; self.control = control; self.policy = policy; ownership = owners
    }
    public func inventory() async throws -> ChapterStorageInventory {
        try writable(); guard inventoryTask == nil else { throw ChapterStorageBudgetError.busy }
        let pins = self.pins, policy = self.policy, checkpoint = beforeScanForTesting
        let task = Task.detached(priority: .utility) {
            await checkpoint?(); try Task.checkCancellation(); return try Self.scan(pins, policy: policy)
        }
        inventoryTask = task; defer { inventoryTask = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try writable()
        return result
    }
    public func reserve(bytes: UInt64) async throws -> ChapterStorageReservation {
        try writable()
        guard reservations.count < policy.maximumReservations else { throw ChapterStorageBudgetError.busy }
        guard bytes > 0, bytes <= policy.maximumManagedBytes else { throw ChapterStorageBudgetError.capacity }
        let usage = try await inventory()
        try writable(); try Task.checkCancellation()
        guard reservations.count < policy.maximumReservations else { throw ChapterStorageBudgetError.busy }
        let totalReserved = try reservedBytes()
        let requested = try Self.add(totalReserved, bytes)
        guard try Self.add(usage.logicalBytes, requested) <= policy.maximumManagedBytes else { throw ChapterStorageBudgetError.capacity }
        guard try Self.add(policy.minimumAvailableBytes, requested) <= usage.minimumVolumeAvailableBytes else { throw ChapterStorageBudgetError.freeSpace }
        let token = ChapterStorageReservation(owner: ownerID, id: UUID(), bytes: bytes)
        reservations[token.id] = bytes; return token
    }
    /// After producers join, remeasure everything including unknown files. A
    /// limit error keeps the reservation active until explicit release-after-join.
    public func settleAfterJoining(_ token: ChapterStorageReservation) async throws -> ChapterStorageInventory {
        let result = try await observeWithinCapacity(token)
        await beforeSettlementCommitForTesting?()
        try validate(token); try Task.checkCancellation()
        reservations.removeValue(forKey: token.id); return result
    }
    /// Measured stage-boundary admission while the producer remains owned. This
    /// does not consume its allowance, reserve OS blocks or limit a native write.
    public func observeWithinCapacity(_ token: ChapterStorageReservation) async throws -> ChapterStorageInventory {
        try validate(token)
        let result = try await inventory()
        try validate(token); try Task.checkCancellation()
        // Other producers may still consume their full allowance. Preserve the
        // conservative accounting used at admission, even where some of those
        // bytes already appear in the inventory.
        let remaining = try reservedBytes() - token.bytes
        guard try Self.add(result.logicalBytes, remaining) <= policy.maximumManagedBytes else { throw ChapterStorageBudgetError.capacity }
        guard try Self.add(policy.minimumAvailableBytes, remaining) <= result.minimumVolumeAvailableBytes else { throw ChapterStorageBudgetError.freeSpace }
        return result
    }
    /// Failure path after producer join. Removes only in-memory allowance, never data.
    public func releaseAfterJoining(_ token: ChapterStorageReservation) throws {
        try validate(token); reservations.removeValue(forKey: token.id)
    }
    /// Binds a producer's exact destination root to this inventory scope. Does
    /// not authorize another role's journal or an arbitrary child directory.
    public func requireManagedDirectory(_ directory: URL) throws {
        try writable()
        let candidate = try Pin(directory)
        guard pins.contains(where: { $0.device == candidate.device && $0.inode == candidate.inode })
        else { throw ChapterStorageBudgetError.invalidConfiguration }
        try candidate.validate()
    }
    /// Ownership transfer requires the complete expected scope, without extra
    /// Reader/control/model roots sharing this owner's terminal close.
    public func requireExactManagedDirectories(_ directories: [URL]) throws {
        try writable()
        guard directories.count == pins.count else { throw ChapterStorageBudgetError.invalidConfiguration }
        let expected = try directories.map(Pin.init)
        for candidate in expected {
            guard expected.filter({ $0.device == candidate.device && $0.inode == candidate.inode }).count == 1,
                  pins.contains(where: { $0.device == candidate.device && $0.inode == candidate.inode })
            else { throw ChapterStorageBudgetError.invalidConfiguration }
            try candidate.validate()
        }
    }
    public func close() throws {
        guard inventoryTask == nil, reservations.isEmpty else { throw ChapterStorageBudgetError.busy }; ownership = nil
    }
    func pauseScanForTesting(_ checkpoint: (@Sendable () async -> Void)?) { beforeScanForTesting = checkpoint }
    func pauseSettlementForTesting(_ checkpoint: (@Sendable () async -> Void)?) { beforeSettlementCommitForTesting = checkpoint }
    private func writable() throws {
        guard let ownership else { throw ChapterStorageBudgetError.closed }
        for owner in ownership { try owner.validate() }; try control.validate()
    }
    private func validate(_ token: ChapterStorageReservation) throws {
        try writable(); guard token.owner == ownerID, reservations[token.id] == token.bytes else { throw ChapterStorageBudgetError.staleReservation }
    }
    private func reservedBytes() throws -> UInt64 { try reservations.values.reduce(0, Self.add) }
    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.addingReportingOverflow(b); guard !result.overflow else { throw ChapterStorageBudgetError.capacity }; return result.partialValue
    }
    private static func scan(_ pins: [Pin], policy: ChapterStorageBudgetPolicy) throws -> ChapterStorageInventory {
        var bytes: UInt64 = 0, files = 0, directories = 0, visited = 0, available = UInt64.max
        func walk(_ fd: Int32, depth: Int, device: Int32) throws {
            try Task.checkCancellation()
            guard depth <= policy.maximumDepth else { throw ChapterStorageBudgetError.inventoryLimit }
            let duplicate = dup(fd); guard duplicate >= 0 else { throw ChapterStorageBudgetError.storage }
            guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw ChapterStorageBudgetError.storage }
            defer { closedir(stream) }
            while true {
                try Task.checkCancellation(); errno = 0
                guard let entry = readdir(stream) else { guard errno == 0 else { throw ChapterStorageBudgetError.storage }; break }
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                visited += 1; guard visited <= policy.maximumEntries else { throw ChapterStorageBudgetError.inventoryLimit }
                var before = stat()
                guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0, before.st_dev == device else { throw ChapterStorageBudgetError.unsafeEntry }
                switch before.st_mode & S_IFMT {
                case S_IFREG:
                    guard before.st_size >= 0 else { throw ChapterStorageBudgetError.unsafeEntry }
                    bytes = try add(bytes, UInt64(before.st_size)); files += 1
                case S_IFDIR:
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw ChapterStorageBudgetError.unsafeEntry }
                    defer { Darwin.close(child) }
                    var actual = stat()
                    guard fstat(child, &actual) == 0, actual.st_dev == before.st_dev, actual.st_ino == before.st_ino else { throw ChapterStorageBudgetError.unsafeEntry }
                    directories += 1; try walk(child, depth: depth + 1, device: device)
                default: throw ChapterStorageBudgetError.unsafeEntry // No symlink/FIFO/socket/device traversal.
                }
                var after = stat()
                guard fstatat(fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0, before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino, before.st_mode == after.st_mode, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                else { throw ChapterStorageBudgetError.unsafeEntry }
            }
        }
        for pin in pins {
            try pin.validate(); try Task.checkCancellation()
            let fd = Darwin.open(pin.supplied.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ChapterStorageBudgetError.unsafeEntry }; defer { Darwin.close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0, info.st_dev == pin.device, info.st_ino == pin.inode else { throw ChapterStorageBudgetError.unsafeEntry }
            var volume = statvfs(); guard fstatvfs(fd, &volume) == 0 else { throw ChapterStorageBudgetError.storage }
            let block = UInt64(volume.f_frsize == 0 ? volume.f_bsize : volume.f_frsize)
            let free = UInt64(volume.f_bavail).multipliedReportingOverflow(by: block)
            guard !free.overflow else { throw ChapterStorageBudgetError.storage }; available = min(available, free.partialValue)
            directories += 1; try walk(fd, depth: 0, device: pin.device); try pin.validate()
        }
        try Task.checkCancellation()
        return .init(logicalBytes: bytes, regularFiles: files, directories: directories, minimumVolumeAvailableBytes: available)
    }
}
