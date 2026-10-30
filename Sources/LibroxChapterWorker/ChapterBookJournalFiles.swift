import Foundation
import Darwin

public enum ChapterBookJournalError: Error, Equatable {
    case closed, alreadyOpen, corrupt, storage, budget, ambiguousWrite, staleAdmission, notFound
}

/// One PRIVATE Reader book-journal namespace. Never a Worker lock or CloudKit
/// lease. Initialize/use off the UI actor; no recursive cleanup or data eviction.
final class ChapterBookJournalFiles: Sendable {
    private final class Descriptor: Sendable {
        let fd: Int32
        init(_ fd: Int32) throws { guard fd >= 0 else { throw ChapterBookJournalError.storage }; self.fd = fd }
        deinit { Darwin.close(fd) }
    }
    private let base, account, directory, lock: Descriptor
    private let supplied, resolved: URL
    private let baseIdentity, accountIdentity, directoryIdentity, lockIdentity: stat
    let partition, deviceName: String
    var device: UInt64 { UInt64(UInt32(bitPattern: directoryIdentity.st_dev)) }
    var inode: UInt64 { UInt64(directoryIdentity.st_ino) }
    init(directory url: URL, partition: String, deviceID: UUID) throws {
        guard url.isFileURL, !url.path.utf8.contains(0), url.standardizedFileURL.path != "/", isDigest(partition) else {
            throw ChapterWorkerError.invalidIdentity
        }
        supplied = url; resolved = url.resolvingSymlinksInPath().standardizedFileURL
        self.partition = partition; deviceName = deviceID.uuidString.lowercased()
        base = try Descriptor(Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        baseIdentity = try Self.info(base.fd)
        account = try Self.child(base.fd, partition); accountIdentity = try Self.info(account.fd)
        directory = try Self.child(account.fd, deviceName); directoryIdentity = try Self.info(directory.fd)
        lock = try Descriptor(openat(directory.fd, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600))
        lockIdentity = try Self.info(lock.fd)
        guard lockIdentity.st_mode & S_IFMT == S_IFREG, lockIdentity.st_size == 0,
              flock(lock.fd, LOCK_EX | LOCK_NB) == 0 else { throw ChapterBookJournalError.alreadyOpen }
        try validate()
    }
    private static func info(_ fd: Int32) throws -> stat {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw ChapterBookJournalError.storage }; return value
    }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private static func child(_ parent: Int32, _ name: String) throws -> Descriptor {
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw ChapterBookJournalError.storage }
        let value = try Descriptor(openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        guard fsync(parent) == 0 else { throw ChapterBookJournalError.storage }; return value
    }
    func validate() throws {
        var a = stat(), b = stat(), c = stat(), d = stat(), e = stat()
        guard lstat(supplied.path, &a) == 0, lstat(resolved.path, &b) == 0,
              fstatat(base.fd, partition, &c, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(account.fd, deviceName, &d, AT_SYMLINK_NOFOLLOW) == 0,
              fstatat(directory.fd, "owner.lock", &e, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(baseIdentity, a), Self.same(baseIdentity, b), Self.same(accountIdentity, c),
              Self.same(directoryIdentity, d), Self.same(lockIdentity, e), e.st_size == 0,
              Self.same(baseIdentity, try Self.info(base.fd)), Self.same(accountIdentity, try Self.info(account.fd)),
              Self.same(directoryIdentity, try Self.info(directory.fd)), Self.same(lockIdentity, try Self.info(lock.fd))
        else { throw ChapterBookJournalError.storage }
    }
    func isFresh() throws -> Bool {
        let duplicate = dup(directory.fd); guard duplicate >= 0 else { throw ChapterBookJournalError.storage }
        guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw ChapterBookJournalError.storage }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if ![".", "..", "owner.lock"].contains(name) { return false }
        }
        guard errno == 0 else { throw ChapterBookJournalError.storage }
        try validate()
        return true
    }
    func read(_ leaf: String, maximum: Int) throws -> Data? {
        try validate(); try Task.checkCancellation()
        let fd = openat(directory.fd, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw ChapterBookJournalError.corrupt }
            try validate(); try Task.checkCancellation(); return nil
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        let before = try Self.info(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= maximum else { throw ChapterBookJournalError.corrupt }
        var bytes = Data()
        while bytes.count < before.st_size {
            try autoreleasepool {
                try Task.checkCancellation()
                let part = try file.read(upToCount: min(65536, Int(before.st_size) - bytes.count)) ?? Data()
                guard !part.isEmpty else { throw ChapterBookJournalError.corrupt }; bytes.append(part)
            }
        }
        let after = try Self.info(fd); var path = stat()
        guard fstatat(directory.fd, leaf, &path, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(before, after), Self.same(before, path), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw ChapterBookJournalError.corrupt }
        try validate(); try Task.checkCancellation(); return bytes
    }
    func write(_ data: Data, leaf: String, immutable: Bool = false,
               afterRename: (() throws -> Void)? = nil) throws {
        try validate(); try Task.checkCancellation()
        let name = ".book-pending-" + UUID().uuidString
        let fd = openat(directory.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChapterBookJournalError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        let created = try Self.info(fd)
        defer {
            var current = stat()
            if fstatat(directory.fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, Self.same(created, current) { unlinkat(directory.fd, name, 0) }
        }
        for start in stride(from: 0, to: data.count, by: 65536) {
            try autoreleasepool { try Task.checkCancellation(); try file.write(contentsOf: data[start..<min(start + 65536, data.count)]) }
        }
        try file.synchronize()
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0 else { throw ChapterBookJournalError.storage }
        try file.seek(toOffset: 0)
        var offset = 0
        while offset < data.count {
            try autoreleasepool {
                try Task.checkCancellation()
                let part = try file.read(upToCount: min(65536, data.count - offset)) ?? Data()
                guard !part.isEmpty, part == data[offset..<offset + part.count] else { throw ChapterBookJournalError.corrupt }
                offset += part.count
            }
        }
        try validate()
        var staged = stat()
        guard fstatat(directory.fd, name, &staged, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(created, staged), staged.st_size == data.count else { throw ChapterBookJournalError.storage }
        if immutable {
            if linkat(directory.fd, name, directory.fd, leaf, 0) != 0 {
                guard errno == EEXIST, try read(leaf, maximum: data.count) == data else { throw ChapterBookJournalError.corrupt }
            }
        } else {
            guard renameat(directory.fd, name, directory.fd, leaf) == 0 else { throw ChapterBookJournalError.storage }
        }
        try afterRename?()
        guard fsync(directory.fd) == 0 else { throw ChapterBookJournalError.storage }
        try validate(); try Task.checkCancellation()
    }
}
