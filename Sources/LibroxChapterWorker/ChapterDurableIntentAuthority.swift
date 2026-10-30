import Foundation
import CryptoKit
import Darwin

public enum ChapterDurableAuthorityError: Error, Equatable {
    case invalidRecord, storage, busy, wrongDirectory, configurationRequired, budget
}

/// Local routing identity, not an account credential or producer epoch. The host
/// supplies the actual authorized directory separately; Worker session gates remain required.
public struct ChapterDurableIntentDescriptor: Codable, Sendable, Equatable {
    public let accountPartition: String
    public let deviceID, publisherID: UUID
    public let directoryDevice, directoryInode: UInt64
    init(accountPartition: String, deviceID: UUID, publisherID: UUID, directoryDevice: UInt64, directoryInode: UInt64) throws {
        guard isDigest(accountPartition), directoryInode > 0 else { throw ChapterDurableAuthorityError.invalidRecord }
        self.accountPartition = accountPartition; self.deviceID = deviceID; self.publisherID = publisherID
        self.directoryDevice = directoryDevice; self.directoryInode = directoryInode
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(accountPartition: c.decode(String.self, forKey: .accountPartition),
            deviceID: c.decode(UUID.self, forKey: .deviceID), publisherID: c.decode(UUID.self, forKey: .publisherID),
            directoryDevice: c.decode(UInt64.self, forKey: .directoryDevice), directoryInode: c.decode(UInt64.self, forKey: .directoryInode))
    }
    private enum CodingKeys: String, CodingKey { case accountPartition, deviceID, publisherID, directoryDevice, directoryInode }
}

/// Reads only Reader-published authority, including while Reader is closed.
/// This is an instantaneous observation, NOT a worker lease or acceptance lock.
public struct ChapterDurableIntentAuthority: ChapterIntentAuthority {
    private let directory: URL
    public let descriptor: ChapterDurableIntentDescriptor
    public init(directory: URL, descriptor: ChapterDurableIntentDescriptor) {
        self.directory = directory; self.descriptor = descriptor
    }
    public func validateCurrent(_ readSet: ChapterIntentReadSet) async throws -> Bool {
        try await validateCurrent(readSet, afterArchiveRead: {})
    }
    func validateCurrent(_ readSet: ChapterIntentReadSet,
                         afterArchiveRead: @escaping @Sendable () async throws -> Void) async throws -> Bool {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) { [directory, descriptor] in
            let root = try IntentAuthorityRoot(directory)
            try root.validate(descriptor)
            guard readSet.intent.deviceID == descriptor.deviceID,
                  readSet.intent.request.accountPartition == descriptor.accountPartition else { throw ChapterWorkerError.accountMismatch }
            guard let before = try root.read("current.json", maximum: 16384) else { return false }
            let barrier = try IntentAuthorityCodec.decode(IntentAuthorityBarrier.self, before)
            guard barrier.version == 1, barrier.descriptor == descriptor else { throw ChapterDurableAuthorityError.invalidRecord }
            guard barrier.ready else {
                guard barrier.archive == nil else { throw ChapterDurableAuthorityError.invalidRecord }; return false
            }
            guard let reference = barrier.archive, isDigest(reference) else { throw ChapterDurableAuthorityError.invalidRecord }
            let bytes = try root.required(reference + ".json", maximum: IntentAuthorityCodec.maximumArchiveBytes)
            guard IntentAuthorityCodec.hash(bytes) == reference else { throw ChapterDurableAuthorityError.invalidRecord }
            let archive = try IntentAuthorityCodec.decode(IntentAuthorityArchive.self, bytes)
            try archive.validate(descriptor)
            let key = try readSet.intent.request.renderKey()
            let matches = try archive.readSets.first(where: { try $0.intent.request.renderKey() == key }) == readSet
            try await afterArchiveRead()
            guard try root.read("current.json", maximum: 16384) == before else { return false }
            try root.validate(descriptor); try Task.checkCancellation()
            return matches
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); return result
    }
}

private struct IntentAuthorityBarrier: Codable {
    let version: Int
    let descriptor: ChapterDurableIntentDescriptor
    let generation: UUID
    let ready: Bool
    let archive: String?
}
private struct IntentAuthorityArchive: Codable {
    let version: Int
    let descriptor: ChapterDurableIntentDescriptor
    let readSets: [ChapterIntentReadSet]
    func validate(_ expected: ChapterDurableIntentDescriptor) throws {
        guard version == 1, descriptor == expected, readSets.count <= ChapterDemandOutbox.maximumEntries else { throw ChapterDurableAuthorityError.invalidRecord }
        var previous: String?
        for value in readSets {
            guard value.intent.deviceID == descriptor.deviceID, value.intent.request.accountPartition == descriptor.accountPartition
            else { throw ChapterDurableAuthorityError.invalidRecord }
            let key = try value.intent.request.renderKey()
            guard previous == nil || previous! < key else { throw ChapterDurableAuthorityError.invalidRecord }
            previous = key
        }
    }
}
private enum IntentAuthorityCodec {
    static let maximumArchiveBytes = 32 * 1024 * 1024
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try e.encode(value)
    }
    static func decode<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
        let value = try JSONDecoder().decode(type, from: data)
        guard try encode(value) == data else { throw ChapterDurableAuthorityError.invalidRecord }
        return value
    }
}

/// Owned only by the Reader outbox actor. No cross-actor sharing of its FDs.
final class ChapterIntentHeadWriter {
    private let root: IntentAuthorityRoot
    private let lock: FileHandle
    let descriptor: ChapterDurableIntentDescriptor
    private var generation: UUID?
    init(directory: URL, partition: String, device: UUID, expected: ChapterDurableIntentDescriptor?) throws {
        root = try IntentAuthorityRoot(directory)
        let fd = openat(root.fd, "publisher.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ChapterDurableAuthorityError.storage }
        lock = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ChapterDurableAuthorityError.busy }
        if let expected {
            guard expected.accountPartition == partition, expected.deviceID == device else { throw ChapterDurableAuthorityError.wrongDirectory }
            try root.validate(expected)
            if let bytes = try root.read("current.json", maximum: 16384) {
                let value = try IntentAuthorityCodec.decode(IntentAuthorityBarrier.self, bytes)
                guard value.version == 1, value.descriptor == expected else { throw ChapterDurableAuthorityError.wrongDirectory }
            }
            descriptor = expected
        } else {
            guard try root.isFresh() else { throw ChapterDurableAuthorityError.wrongDirectory }
            descriptor = try .init(accountPartition: partition, deviceID: device, publisherID: UUID(),
                directoryDevice: root.device, directoryInode: root.inode)
        }
        // Caller also holds the journal lock and persists/verifies its immutable
        // binding before calling block. Never touch an unverified foreign channel.
    }
    func block(ignoreCancellation: Bool = false) throws {
        try validateOwnership()
        let nonce = UUID()
        try writeBarrier(.init(version: 1, descriptor: descriptor, generation: nonce, ready: false, archive: nil), ignoreCancellation: ignoreCancellation)
        generation = nonce
    }
    func publish(_ readSets: [ChapterIntentReadSet], afterArchive: () throws -> Void = {}) throws {
        try validateOwnership()
        guard let generation else { throw ChapterDurableAuthorityError.configurationRequired }
        let archive = IntentAuthorityArchive(version: 1, descriptor: descriptor, readSets: readSets)
        try archive.validate(descriptor)
        let bytes = try IntentAuthorityCodec.encode(archive)
        guard bytes.count <= IntentAuthorityCodec.maximumArchiveBytes else { throw ChapterDurableAuthorityError.budget }
        let reference = IntentAuthorityCodec.hash(bytes)
        try root.write(bytes, leaf: reference + ".json", replace: false, maximum: IntentAuthorityCodec.maximumArchiveBytes)
        try afterArchive()
        try writeBarrier(.init(version: 1, descriptor: descriptor, generation: generation, ready: true, archive: reference))
    }
    private func validateOwnership() throws {
        try root.validate()
        var descriptor = stat(), path = stat()
        guard fstat(lock.fileDescriptor, &descriptor) == 0,
              fstatat(root.fd, "publisher.lock", &path, AT_SYMLINK_NOFOLLOW) == 0,
              descriptor.st_mode & S_IFMT == S_IFREG, descriptor.st_size == 0,
              descriptor.st_dev == path.st_dev, descriptor.st_ino == path.st_ino else { throw ChapterDurableAuthorityError.busy }
    }
    private func writeBarrier(_ value: IntentAuthorityBarrier, ignoreCancellation: Bool = false) throws {
        try validateOwnership()
        guard value.descriptor == descriptor else { throw ChapterDurableAuthorityError.invalidRecord }
        if let bytes = try root.read("current.json", maximum: 16384, checkCancellation: !ignoreCancellation) {
            let old = try IntentAuthorityCodec.decode(IntentAuthorityBarrier.self, bytes)
            guard old.descriptor == value.descriptor, old.version == 1 else { throw ChapterDurableAuthorityError.invalidRecord }
        }
        try root.write(IntentAuthorityCodec.encode(value), leaf: "current.json", replace: true, maximum: 16384, checkCancellation: !ignoreCancellation)
    }
}

private final class IntentAuthorityRoot {
    private let handle: FileHandle
    let supplied, resolved: URL
    private let identity: stat
    var fd: Int32 { handle.fileDescriptor }
    var device: UInt64 { UInt64(UInt32(bitPattern: identity.st_dev)) }
    var inode: UInt64 { identity.st_ino }
    init(_ directory: URL) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw ChapterDurableAuthorityError.storage }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChapterDurableAuthorityError.storage }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat(); guard fstat(fd, &info) == 0 else { throw ChapterDurableAuthorityError.storage }
        identity = info; supplied = directory; resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        try validate()
    }
    func validate(_ descriptor: ChapterDurableIntentDescriptor) throws {
        try validate()
        guard descriptor.directoryDevice == device, descriptor.directoryInode == inode else { throw ChapterDurableAuthorityError.wrongDirectory }
    }
    func validate() throws {
        var a = stat(), b = stat(), c = stat()
        guard lstat(supplied.path, &a) == 0, lstat(resolved.path, &b) == 0, fstat(fd, &c) == 0,
              same(identity, a), same(identity, b), same(identity, c) else { throw ChapterDurableAuthorityError.storage }
    }
    func isFresh() throws -> Bool {
        try validate()
        let duplicate = dup(fd); guard duplicate >= 0 else { throw ChapterDurableAuthorityError.storage }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw ChapterDurableAuthorityError.storage }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let value = readdir(stream) else {
                guard errno == 0 else { throw ChapterDurableAuthorityError.storage }; return true
            }
            let name = withUnsafePointer(to: value.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != ".", name != "..", name != "publisher.lock" { return false }
        }
    }
    func required(_ leaf: String, maximum: Int) throws -> Data {
        guard let value = try read(leaf, maximum: maximum) else { throw ChapterDurableAuthorityError.invalidRecord }; return value
    }
    func read(_ leaf: String, maximum: Int, checkCancellation: Bool = true) throws -> Data? {
        try validate(); if checkCancellation { try Task.checkCancellation() }
        let input = openat(fd, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if input < 0 {
            guard errno == ENOENT else { throw ChapterDurableAuthorityError.storage }; return nil
        }
        let file = FileHandle(fileDescriptor: input, closeOnDealloc: true); defer { try? file.close() }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maximum else { throw ChapterDurableAuthorityError.invalidRecord }
        var bytes = Data(); bytes.reserveCapacity(Int(before.st_size))
        while bytes.count < before.st_size {
            try autoreleasepool {
                if checkCancellation { try Task.checkCancellation() }
                let value = try file.read(upToCount: min(65536, Int(before.st_size) - bytes.count)) ?? Data()
                guard !value.isEmpty else { throw ChapterDurableAuthorityError.invalidRecord }; bytes.append(value)
            }
        }
        var after = stat(), path = stat()
        guard fstat(input, &after) == 0, fstatat(fd, leaf, &path, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(before, path), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ChapterDurableAuthorityError.invalidRecord }
        try validate(); return bytes
    }
    func write(_ data: Data, leaf: String, replace: Bool, maximum: Int, checkCancellation: Bool = true) throws {
        guard !data.isEmpty, data.count <= maximum else { throw ChapterDurableAuthorityError.budget }
        try validate(); if checkCancellation { try Task.checkCancellation() }
        let name = ".authority-" + UUID().uuidString
        let output = openat(fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ChapterDurableAuthorityError.storage }
        let file = FileHandle(fileDescriptor: output, closeOnDealloc: true); defer { try? file.close() }
        var identity = stat(); guard fstat(output, &identity) == 0 else { throw ChapterDurableAuthorityError.storage }
        defer {
            var current = stat()
            if fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(identity, current) { unlinkat(fd, name, 0) }
        }
        for start in stride(from: 0, to: data.count, by: 65536) {
            try autoreleasepool { if checkCancellation { try Task.checkCancellation() }; try file.write(contentsOf: data[start..<min(start + 65536, data.count)]) }
        }
        guard fchmod(output, 0o400) == 0, fsync(output) == 0 else { throw ChapterDurableAuthorityError.storage }
        var written = stat(); guard fstat(output, &written) == 0 else { throw ChapterDurableAuthorityError.storage }
        try file.seek(toOffset: 0)
        var offset = 0
        while offset < data.count {
            try autoreleasepool {
                if checkCancellation { try Task.checkCancellation() }
                let part = try file.read(upToCount: min(65536, data.count - offset)) ?? Data()
                guard !part.isEmpty, part == data[offset..<offset + part.count] else { throw ChapterDurableAuthorityError.invalidRecord }; offset += part.count
            }
        }
        var staged = stat(), finished = stat()
        guard fstat(output, &finished) == 0, fstatat(fd, name, &staged, AT_SYMLINK_NOFOLLOW) == 0, same(identity, staged), same(identity, finished), staged.st_size == data.count,
              finished.st_size == written.st_size, finished.st_mtimespec.tv_sec == written.st_mtimespec.tv_sec,
              finished.st_mtimespec.tv_nsec == written.st_mtimespec.tv_nsec
        else { throw ChapterDurableAuthorityError.storage }
        try validate(); if checkCancellation { try Task.checkCancellation() }
        if replace {
            if let _ = try read(leaf, maximum: maximum, checkCancellation: checkCancellation) { /* reject symlinks/nonregular/unstable destinations */ }
            guard renameat(fd, name, fd, leaf) == 0 else { throw ChapterDurableAuthorityError.storage }
        } else if linkat(fd, name, fd, leaf, 0) != 0 {
            guard errno == EEXIST, try required(leaf, maximum: maximum) == data else { throw ChapterDurableAuthorityError.invalidRecord }
        }
        guard fsync(fd) == 0 else { throw ChapterDurableAuthorityError.storage }
        try validate()
    }
    private func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
}

/// Immutable companion to the checked journal. It pins recovery to the same
/// authority root before the journal is read; new plain writers fail closed.
enum ChapterAuthorityBindingFile {
    private struct Packet: Codable { let version: Int; let descriptor: ChapterDurableIntentDescriptor; let checksum: String }
    static func read(_ directory: Int32) throws -> ChapterDurableIntentDescriptor? {
        let fd = openat(directory, "authority-binding.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { guard errno == ENOENT else { throw ChapterDurableAuthorityError.storage }; return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var a = stat(); guard fstat(fd, &a) == 0, a.st_mode & S_IFMT == S_IFREG, a.st_size > 0, a.st_size <= 16384
        else { throw ChapterDurableAuthorityError.invalidRecord }
        let bytes = try file.read(upToCount: 16385) ?? Data()
        var b = stat(), path = stat()
        guard bytes.count == a.st_size, fstat(fd, &b) == 0, fstatat(directory, "authority-binding.json", &path, AT_SYMLINK_NOFOLLOW) == 0,
              same(a, b), same(a, path), a.st_size == b.st_size, a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec,
              a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec else { throw ChapterDurableAuthorityError.invalidRecord }
        let packet = try IntentAuthorityCodec.decode(Packet.self, bytes)
        guard packet.version == 1, packet.checksum == (try IntentAuthorityCodec.hash(IntentAuthorityCodec.encode(packet.descriptor)))
        else { throw ChapterDurableAuthorityError.invalidRecord }
        return packet.descriptor
    }
    static func publish(_ value: ChapterDurableIntentDescriptor, directory: Int32) throws {
        let bytes = try IntentAuthorityCodec.encode(Packet(version: 1, descriptor: value,
            checksum: IntentAuthorityCodec.hash(IntentAuthorityCodec.encode(value))))
        let name = ".authority-binding-" + UUID().uuidString
        let fd = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChapterDurableAuthorityError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var identity = stat(); guard fstat(fd, &identity) == 0 else { throw ChapterDurableAuthorityError.storage }
        defer {
            var current = stat()
            if fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(identity, current) { unlinkat(directory, name, 0) }
        }
        try file.write(contentsOf: bytes)
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0 else { throw ChapterDurableAuthorityError.storage }
        try file.seek(toOffset: 0)
        guard try file.read(upToCount: bytes.count + 1) == bytes else { throw ChapterDurableAuthorityError.invalidRecord }
        var staged = stat()
        guard fstatat(directory, name, &staged, AT_SYMLINK_NOFOLLOW) == 0, same(identity, staged), staged.st_size == bytes.count
        else { throw ChapterDurableAuthorityError.storage }
        if linkat(directory, name, directory, "authority-binding.json", 0) != 0 {
            guard errno == EEXIST, try read(directory) == value else { throw ChapterDurableAuthorityError.invalidRecord }
        }
        guard fsync(directory) == 0 else { throw ChapterDurableAuthorityError.storage }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
}
