import Foundation
import CryptoKit
import Darwin

enum ChapterCloudFileError: Error, Equatable { case invalidFile, budget, storage }

/// Private bounded bytes captured while a CloudKit staging URL is still valid.
/// This is NOT decoded audio, a source grant, a job receipt or playable custody.
/// Native callbacks supply operation cancellation; callers fence epochs before
/// the operation and after Foundation completion. Never serialize this handle.
final class ChapterCloudFileCapture: Sendable {
    static let maximumBytes: Int64 = 1_073_741_824
    let session: ChapterAccountSession
    let byteCount: Int64
    let sha256: String
    private let custody: Custody

    private final class Root: Sendable {
        let supplied, resolved: URL
        let fd: Int32
        let identity: stat
        init(_ url: URL) throws {
            guard url.isFileURL, url.standardizedFileURL.path != "/", !url.path.utf8.contains(0) else { throw ChapterCloudFileError.invalidFile }
            supplied = url; resolved = url.resolvingSymlinksInPath().standardizedFileURL
            fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ChapterCloudFileError.storage }
            var info = stat()
            guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw ChapterCloudFileError.storage }
            identity = info
            // All stored properties are initialized: a thrown validation runs
            // deinit, which owns this descriptor. Do not close it twice.
            try validate()
        }
        deinit { Darwin.close(fd) }
        func validate() throws {
            var a = stat(), b = stat(), c = stat()
            guard fstat(fd, &a) == 0, lstat(supplied.path, &b) == 0, lstat(resolved.path, &c) == 0,
                  b.st_mode & S_IFMT == S_IFDIR, c.st_mode & S_IFMT == S_IFDIR,
                  Self.same(identity, a), Self.same(identity, b), Self.same(identity, c) else { throw ChapterCloudFileError.invalidFile }
        }
        static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    }
    private final class Custody: Sendable {
        let root: Root
        let name: String
        let directoryFD, fileFD: Int32
        let directoryIdentity, fileIdentity: stat
        let url: URL
        init(root: Root, name: String, directoryFD: Int32, fileFD: Int32, directory: stat, file: stat) {
            self.root = root; self.name = name; self.directoryFD = directoryFD; self.fileFD = fileFD
            directoryIdentity = directory; fileIdentity = file
            url = root.supplied.appendingPathComponent(name).appendingPathComponent("payload")
        }
        deinit {
            var value = stat()
            if fstatat(directoryFD, "payload", &value, AT_SYMLINK_NOFOLLOW) == 0, Root.same(fileIdentity, value) {
                unlinkat(directoryFD, "payload", 0)
            }
            if fstatat(root.fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0, Root.same(directoryIdentity, value) {
                // Unknown entries make rmdir fail. Never recursively remove them.
                unlinkat(root.fd, name, AT_REMOVEDIR)
            }
            Darwin.close(fileFD); Darwin.close(directoryFD)
        }
        func validate(bytes: Int64, hash: String, check: () throws -> Void) throws {
            try check(); try root.validate()
            var dir = stat(), dirPath = stat(), file = stat(), filePath = stat()
            guard fstat(directoryFD, &dir) == 0, fstatat(root.fd, name, &dirPath, AT_SYMLINK_NOFOLLOW) == 0,
                  Root.same(directoryIdentity, dir), Root.same(directoryIdentity, dirPath),
                  fstat(fileFD, &file) == 0, fstatat(directoryFD, "payload", &filePath, AT_SYMLINK_NOFOLLOW) == 0,
                  Root.same(fileIdentity, file), Root.same(fileIdentity, filePath), file.st_mode & S_IFMT == S_IFREG,
                  file.st_mode & 0o222 == 0, file.st_size == bytes else { throw ChapterCloudFileError.invalidFile }
            let actual = try ChapterCloudFileCapture.hash(fileFD, bytes: bytes, check: check)
            var after = stat(), pathAfter = stat()
            guard actual == hash, fstat(fileFD, &after) == 0,
                  fstatat(directoryFD, "payload", &pathAfter, AT_SYMLINK_NOFOLLOW) == 0,
                  Root.same(fileIdentity, after), Root.same(fileIdentity, pathAfter), after.st_size == file.st_size,
                  after.st_mtimespec.tv_sec == file.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == file.st_mtimespec.tv_nsec else { throw ChapterCloudFileError.invalidFile }
            try root.validate(); try check()
        }
    }
    private init(session: ChapterAccountSession, bytes: Int64, hash: String, custody: Custody) {
        self.session = session; byteCount = bytes; sha256 = hash; self.custody = custody
    }
    static func capture(download: URL, expectedBytes: Int64, expectedSHA256: String, maximum: Int64,
                        session: ChapterAccountSession, storageDirectory: URL,
                        check: () throws -> Void) throws -> ChapterCloudFileCapture {
        try validate(bytes: expectedBytes, hash: expectedSHA256, maximum: maximum); try check()
        guard download.isFileURL, !download.path.utf8.contains(0) else { throw ChapterCloudFileError.invalidFile }
        let fd = Darwin.open(download.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ChapterCloudFileError.invalidFile }; defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size == expectedBytes else { throw ChapterCloudFileError.invalidFile }
        return try build(bytes: expectedBytes, hash: expectedSHA256, session: session, storage: storageDirectory, check: check) { output in
            var offset: Int64 = 0
            let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            while offset < expectedBytes {
                try autoreleasepool {
                    try check()
                    let data = try input.read(upToCount: Int(min(65_536, expectedBytes - offset))) ?? Data()
                    guard !data.isEmpty else { throw ChapterCloudFileError.invalidFile }
                    try output.write(contentsOf: data); offset += Int64(data.count)
                }
            }
            var after = stat(), path = stat()
            guard fstat(fd, &after) == 0, lstat(download.path, &path) == 0,
                  Root.same(before, after), Root.same(before, path), after.st_size == before.st_size,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw ChapterCloudFileError.invalidFile }
        }
    }
    static func create(_ data: Data, maximum: Int64, session: ChapterAccountSession,
                       storageDirectory: URL, check: () throws -> Void) throws -> ChapterCloudFileCapture {
        let hash = digest(data)
        try validate(bytes: Int64(data.count), hash: hash, maximum: maximum)
        return try build(bytes: Int64(data.count), hash: hash, session: session, storage: storageDirectory, check: check) { output in
            for start in stride(from: 0, to: data.count, by: 65_536) {
                try autoreleasepool { try check(); try output.write(contentsOf: data[start..<min(start + 65_536, data.count)]) }
            }
        }
    }
    func withFileAccess<Value: Sendable>(session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                                       _ body: @Sendable (URL) async throws -> Value) async throws -> Value {
        defer { withExtendedLifetime(self) {} }
        guard session == self.session else { throw ChapterWorkerError.accountMismatch }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        // Hash IO belongs to the caller's owned off-main operation chain.
        try custody.validate(bytes: byteCount, hash: sha256, check: { try Task.checkCancellation() })
        let value = try await body(custody.url)
        try custody.validate(bytes: byteCount, hash: sha256, check: { try Task.checkCancellation() })
        try await gate.validate(session); try Task.checkCancellation()
        return value
    }
    /// Bounded exact immutable bytes from the pinned FD. pread keeps concurrent
    /// readers independent of a shared descriptor offset. This is not typed
    /// source/media admission; callers still validate their expected envelope.
    func data(session: ChapterAccountSession, gate: ChapterAccountSessionGate, maximum: Int64) async throws -> Data {
        guard maximum > 0, maximum <= Self.maximumBytes, byteCount <= maximum else { throw ChapterCloudFileError.budget }
        return try await withFileAccess(session: session, gate: gate) { _ in
            var bytes = Data(); bytes.reserveCapacity(Int(self.byteCount))
            while Int64(bytes.count) < self.byteCount {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let count = Int(min(65536, self.byteCount - Int64(bytes.count)))
                    var buffer = [UInt8](repeating: 0, count: count)
                    let received = buffer.withUnsafeMutableBytes { pread(self.custody.fileFD, $0.baseAddress, count, off_t(bytes.count)) }
                    guard received > 0, received <= count else { throw ChapterCloudFileError.invalidFile }
                    bytes.append(contentsOf: buffer.prefix(received))
                }
            }
            return bytes
        }
    }
    private static func build(bytes: Int64, hash: String, session: ChapterAccountSession, storage: URL,
                              check: () throws -> Void, write: (FileHandle) throws -> Void) throws -> ChapterCloudFileCapture {
        try check(); let root = try Root(storage), name = "cloud-capture-" + UUID().uuidString
        guard mkdirat(root.fd, name, 0o700) == 0 else { throw ChapterCloudFileError.storage }
        let dir = openat(root.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw ChapterCloudFileError.storage }
        var directory = stat()
        guard fstat(dir, &directory) == 0 else { Darwin.close(dir); throw ChapterCloudFileError.storage }
        let fd = openat(dir, "payload", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { Darwin.close(dir); throw ChapterCloudFileError.storage }
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { Darwin.close(fd); Darwin.close(dir); throw ChapterCloudFileError.storage }
        let custody = Custody(root: root, name: name, directoryFD: dir, fileFD: fd, directory: directory, file: identity)
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try write(output); try output.synchronize()
        guard fchmod(fd, 0o400) == 0, fsync(fd) == 0, fsync(dir) == 0, fsync(root.fd) == 0 else { throw ChapterCloudFileError.storage }
        try custody.validate(bytes: bytes, hash: hash, check: check)
        return .init(session: session, bytes: bytes, hash: hash, custody: custody)
    }
    private static func validate(bytes: Int64, hash: String, maximum: Int64) throws {
        guard maximum > 0, maximum <= maximumBytes, bytes > 0, bytes <= maximum,
              hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ChapterCloudFileError.budget }
    }
    private static func hash(_ fd: Int32, bytes: Int64, check: () throws -> Void) throws -> String {
        var result = SHA256(), offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while offset < bytes {
            try autoreleasepool {
                try check()
                let size = Int(min(65_536, bytes - offset))
                let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, size, off_t(offset)) }
                guard count > 0, count <= size else { throw ChapterCloudFileError.invalidFile }
                result.update(data: Data(buffer.prefix(count))); offset += Int64(count)
            }
        }
        return result.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
