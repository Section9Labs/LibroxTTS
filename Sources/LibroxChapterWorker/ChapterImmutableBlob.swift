import Foundation
import CryptoKit
import Darwin

/// Small immutable local payloads. Task-local FDs, no mutable journal/claim.
/// Read/write calls belong on an owned off-main task; callers fence account state.
package enum ChapterImmutableBlob {
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    package static func publish(_ data: Data, identifier: String, directory: URL, maximumBytes: Int,
                        beforeCommit: @Sendable () async throws -> Void) async throws {
        guard isDigest(identifier), !data.isEmpty, data.count <= maximumBytes, hash(data) == identifier else { throw ChapterLocalSourceError.invalidRecord }
        try Task.checkCancellation()
        let root = try Root(directory)
        let name = ".source-" + UUID().uuidString
        let fd = openat(root.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChapterLocalSourceError.storage }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? output.close() }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { throw ChapterLocalSourceError.storage }
        defer {
            var current = stat()
            if fstatat(root.fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(identity, current) { unlinkat(root.fd, name, 0) }
        }
        for start in stride(from: 0, to: data.count, by: 65536) {
            try autoreleasepool {
                try Task.checkCancellation()
                try output.write(contentsOf: data[start..<min(start + 65536, data.count)])
            }
        }
        try output.synchronize()
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0 else { throw ChapterLocalSourceError.storage }
        try await beforeCommit()
        try Task.checkCancellation(); try root.validate()
        // Bind the staged path to our still-open inode before linking it.
        var staged = stat()
        guard fstatat(root.fd, name, &staged, AT_SYMLINK_NOFOLLOW) == 0,
              same(identity, staged), staged.st_size == data.count else { throw ChapterLocalSourceError.storage }
        try output.seek(toOffset: 0)
        var offset = 0
        while offset < data.count {
            try autoreleasepool {
                try Task.checkCancellation()
                let part = try output.read(upToCount: min(65536, data.count - offset)) ?? Data()
                guard !part.isEmpty, part == data[offset..<offset + part.count] else { throw ChapterLocalSourceError.invalidRecord }
                offset += part.count
            }
        }
        var afterRead = stat(), stagedPath = stat()
        guard fstat(fd, &afterRead) == 0, fstatat(root.fd, name, &stagedPath, AT_SYMLINK_NOFOLLOW) == 0,
              same(identity, afterRead), same(identity, stagedPath), afterRead.st_size == staged.st_size,
              afterRead.st_mtimespec.tv_sec == staged.st_mtimespec.tv_sec,
              afterRead.st_mtimespec.tv_nsec == staged.st_mtimespec.tv_nsec else { throw ChapterLocalSourceError.invalidRecord }
        let leaf = identifier + ".json"
        if linkat(root.fd, name, root.fd, leaf, 0) != 0 {
            guard errno == EEXIST else { throw ChapterLocalSourceError.storage }
            guard try read(identifier, root: root, maximumBytes: maximumBytes) == data else { throw ChapterLocalSourceError.invalidRecord }
        }
        // Also synchronize a matched existing entry after an ambiguous prior
        // commit. Presence/hash equality alone is not a durability receipt.
        guard fsync(root.fd) == 0 else { throw ChapterLocalSourceError.storage }
        try root.validate()
    }
    package static func read(_ identifier: String, directory: URL, maximumBytes: Int) throws -> Data {
        try read(identifier, root: Root(directory), maximumBytes: maximumBytes)
    }
    private static func read(_ identifier: String, root: Root, maximumBytes: Int) throws -> Data {
        guard isDigest(identifier) else { throw ChapterLocalSourceError.invalidReference }
        try root.validate(); try Task.checkCancellation()
        let leaf = identifier + ".json"
        let fd = openat(root.fd, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ChapterLocalSourceError.invalidRecord }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_size > 0, original.st_size <= maximumBytes else { throw ChapterLocalSourceError.invalidRecord }
        var data = Data(); data.reserveCapacity(Int(original.st_size))
        while data.count < original.st_size {
            try autoreleasepool {
                try Task.checkCancellation()
                let part = try input.read(upToCount: min(65536, Int(original.st_size) - data.count)) ?? Data()
                guard !part.isEmpty else { throw ChapterLocalSourceError.invalidRecord }
                data.append(part)
            }
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, fstatat(root.fd, leaf, &path, AT_SYMLINK_NOFOLLOW) == 0,
              same(original, after), same(original, path), original.st_size == after.st_size,
              original.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              original.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, hash(data) == identifier else { throw ChapterLocalSourceError.invalidRecord }
        try root.validate(); try Task.checkCancellation()
        return data
    }
    private final class Root {
        let fd: Int32
        private let supplied, resolved: URL
        private let identity: stat
        init(_ url: URL) throws {
            guard url.isFileURL, !url.path.utf8.contains(0) else { throw ChapterLocalSourceError.storage }
            let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ChapterLocalSourceError.storage }
            var info = stat()
            guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw ChapterLocalSourceError.storage }
            self.fd = fd; identity = info; supplied = url; resolved = url.resolvingSymlinksInPath().standardizedFileURL
            try validate()
        }
        deinit { Darwin.close(fd) }
        func validate() throws {
            var a = stat(), b = stat(), descriptor = stat()
            guard lstat(supplied.path, &a) == 0, lstat(resolved.path, &b) == 0, fstat(fd, &descriptor) == 0,
                  same(identity, a), same(identity, b), same(identity, descriptor) else { throw ChapterLocalSourceError.storage }
        }
    }
}
