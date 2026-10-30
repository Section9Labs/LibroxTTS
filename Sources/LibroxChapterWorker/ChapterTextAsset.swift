import Foundation
import CryptoKit
import Darwin

public enum ChapterTextAssetError: Error, Equatable { case invalidManifest, invalidFile, invalidUTF8, storage }

/// Exact original extraction bytes. No normalization, re-extraction, lossy
/// decoding, recording or voice-conditioning field is part of this format.
public struct ChapterTextAssetManifest: Codable, Sendable, Equatable {
    public static let maximumBytes = 40_000_000
    public let version: Int
    public let accountPartition: String
    public let source: ChapterSourceIdentity
    public let byteCount: Int
    public let utf8SHA256: String
    public init(request: ChapterRenderRequest, byteCount: Int) throws {
        version = 1; accountPartition = request.accountPartition; source = request.source
        self.byteCount = byteCount; utf8SHA256 = request.source.textSHA256
        try validate(for: request)
    }
    public func validate(for request: ChapterRenderRequest) throws {
        try request.validate(); try validateHeader()
        guard accountPartition == request.accountPartition, source == request.source
        else { throw ChapterTextAssetError.invalidManifest }
    }
    private func validateHeader() throws {
        try source.validate()
        guard version == 1, isDigest(accountPartition), utf8SHA256 == source.textSHA256,
              (1...Self.maximumBytes).contains(byteCount), byteCount >= source.utf16Length,
              byteCount <= source.utf16Length * 3 else { throw ChapterTextAssetError.invalidManifest }
    }
    public func sourceKey() throws -> String {
        try validateHeader()
        return try Self.sourceKey(for: source)
    }
    /// Content key only, not account authorization or proof of a stored asset.
    public static func sourceKey(for source: ChapterSourceIdentity) throws -> String {
        try source.validate()
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try e.encode(source)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Scoped custody of a verified private UTF8 copy for a future source CKAsset.
/// This is not an upload, server-ready record or durable adoption database.
public final class ChapterTextAsset: Sendable {
    public let manifest: ChapterTextAssetManifest
    public let session: ChapterAccountSession
    private let custody: Custody
    private final class Custody: Sendable {
        let baseFD, directoryFD, identityFD: Int32
        let name: String
        let url: URL
        let directoryDevice: dev_t, fileDevice: dev_t
        let directoryInode: ino_t, fileInode: ino_t
        init(baseFD: Int32, directoryFD: Int32, identityFD: Int32, name: String, url: URL, directory: stat, file: stat) {
            self.baseFD = baseFD; self.directoryFD = directoryFD; self.identityFD = identityFD
            self.name = name; self.url = url
            directoryDevice = directory.st_dev; directoryInode = directory.st_ino
            fileDevice = file.st_dev; fileInode = file.st_ino
        }
        deinit {
            var value = stat()
            if fstatat(directoryFD, "source.utf8", &value, AT_SYMLINK_NOFOLLOW) == 0,
               value.st_dev == fileDevice, value.st_ino == fileInode { unlinkat(directoryFD, "source.utf8", 0) }
            if fstatat(baseFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
               value.st_dev == directoryDevice, value.st_ino == directoryInode {
                // Never recursively remove unknown/replaced files.
                unlinkat(baseFD, name, AT_REMOVEDIR)
            }
            Darwin.close(identityFD); Darwin.close(directoryFD); Darwin.close(baseFD)
        }
    }
    private init(manifest: ChapterTextAssetManifest, session: ChapterAccountSession, custody: Custody) {
        self.manifest = manifest; self.session = session; self.custody = custody
    }
    public static func create(_ submission: ChapterSubmission, gate: ChapterAccountSessionGate,
                              storageDirectory: URL) async throws -> ChapterTextAsset {
        try await gate.validate(submission.session); try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            let data = Data(submission.originalText.utf8)
            let manifest = try ChapterTextAssetManifest(request: submission.request, byteCount: data.count)
            return try build(manifest: manifest, session: submission.session, storage: storageDirectory) { output in
                for offset in stride(from: 0, to: data.count, by: 65536) {
                    try Task.checkCancellation()
                    try output.write(contentsOf: data[offset..<min(data.count, offset + 65536)])
                }
            }
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return result
    }
    public static func adopt(download: URL, manifest: ChapterTextAssetManifest, request: ChapterRenderRequest,
                             session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                             storageDirectory: URL) async throws -> ChapterTextAsset {
        try manifest.validate(for: request)
        guard session.accountPartition == request.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session); try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try captureDownloadedFile(download: download, manifest: manifest, request: request,
                session: session, storageDirectory: storageDirectory, check: { try Task.checkCancellation() })
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        return result
    }
    /// Internal synchronous CloudKit-callback capture. Does not authorize an
    /// account: the transport fences the session before the operation and after
    /// Foundation completion. Copy while staging URL is still in its callback.
    static func captureDownloadedFile(download: URL, manifest: ChapterTextAssetManifest,
        request: ChapterRenderRequest, session: ChapterAccountSession,
        storageDirectory: URL, check: () throws -> Void) throws -> ChapterTextAsset {
        try manifest.validate(for: request)
        guard session.accountPartition == request.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try check()
        guard download.isFileURL, !download.path.utf8.contains(0) else { throw ChapterTextAssetError.invalidFile }
        let fd = Darwin.open(download.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ChapterTextAssetError.invalidFile }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size == manifest.byteCount
        else { throw ChapterTextAssetError.invalidFile }
        let result = try build(manifest: manifest, session: session, storage: storageDirectory) { output in
            var copied = 0
            while true {
                try check()
                let part = try input.read(upToCount: 65536) ?? Data()
                if part.isEmpty { break }
                guard part.count <= manifest.byteCount - copied else { throw ChapterTextAssetError.invalidFile }
                try output.write(contentsOf: part); copied += part.count
            }
            guard copied == manifest.byteCount else { throw ChapterTextAssetError.invalidFile }
        }
        try check()
        return result
    }
    public func text(session: ChapterAccountSession, gate: ChapterAccountSessionGate) async throws -> String {
        defer { withExtendedLifetime(self) {} }
        guard session == self.session else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session); try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try self.readVerifiedText() }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        return result
    }
    public func withFileAccess<Value: Sendable>(session: ChapterAccountSession, gate: ChapterAccountSessionGate,
        _ body: @Sendable (URL) async throws -> Value) async throws -> Value {
        defer { withExtendedLifetime(self) {} }
        guard session == self.session else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session); try Task.checkCancellation()
        _ = try await text(session: session, gate: gate)
        try validateExportPath()
        let result = try await body(custody.url)
        _ = try await text(session: session, gate: gate)
        try validateExportPath()
        return result
    }
    private func validateExportPath() throws {
        let fd = Darwin.open(custody.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ChapterTextAssetError.invalidFile }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_dev == custody.fileDevice, info.st_ino == custody.fileInode,
              info.st_size == manifest.byteCount else { throw ChapterTextAssetError.invalidFile }
    }
    private func readVerifiedText() throws -> String {
        let fd = openat(custody.directoryFD, "source.utf8", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ChapterTextAssetError.invalidFile }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_dev == custody.fileDevice, info.st_ino == custody.fileInode,
              info.st_size == manifest.byteCount else { throw ChapterTextAssetError.invalidFile }
        var data = Data(); data.reserveCapacity(manifest.byteCount)
        while true {
            try Task.checkCancellation()
            let part = try input.read(upToCount: 65536) ?? Data()
            if part.isEmpty { break }
            guard part.count <= manifest.byteCount - data.count else { throw ChapterTextAssetError.invalidFile }
            data.append(part)
        }
        guard data.count == manifest.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.utf8SHA256,
              let text = String(data: data, encoding: .utf8), Data(text.utf8) == data,
              text.utf16.count == manifest.source.utf16Length else { throw ChapterTextAssetError.invalidUTF8 }
        return text
    }
    // Internal creation seam permits deterministic storage-failure/cancellation
    // tests without exposing a factory that skips public request/epoch checks.
    enum CreationBoundary: CaseIterable, Equatable { case directoryBound, fileBound, identityBound }
    static func build(manifest: ChapterTextAssetManifest, session: ChapterAccountSession, storage: URL,
                      boundary: (CreationBoundary) throws -> Void = { _ in },
                      write: (FileHandle) throws -> Void) throws -> ChapterTextAsset {
        guard storage.isFileURL, !storage.path.utf8.contains(0) else { throw ChapterTextAssetError.storage }
        let base = Darwin.open(storage.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw ChapterTextAssetError.storage }
        let name = UUID().uuidString
        var directory: Int32 = -1, identity: Int32 = -1
        var dirInfo: stat?, fileInfo: stat?, output: FileHandle?
        var transferred = false
        defer {
            if !transferred {
                // Only remove entries whose original inode is still pinned by
                // our open descriptors. Unbound/uncertain paths are preserved.
                var current = stat()
                if let fileInfo, fstatat(directory, "source.utf8", &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == fileInfo.st_dev, current.st_ino == fileInfo.st_ino {
                    unlinkat(directory, "source.utf8", 0)
                }
                if let dirInfo, fstatat(base, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == dirInfo.st_dev, current.st_ino == dirInfo.st_ino {
                    unlinkat(base, name, AT_REMOVEDIR)
                }
                if identity >= 0 { Darwin.close(identity) }
                if directory >= 0 { Darwin.close(directory) }
                Darwin.close(base)
            }
            try? output?.close()
        }
        guard mkdirat(base, name, mode_t(0o700)) == 0 else { throw ChapterTextAssetError.storage }
        directory = openat(base, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ChapterTextAssetError.storage }
        var captured = stat()
        guard fstat(directory, &captured) == 0 else { throw ChapterTextAssetError.storage }
        dirInfo = captured
        try boundary(.directoryBound)
        let fd = openat(directory, "source.utf8", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ChapterTextAssetError.storage }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true); output = writer
        guard fstat(fd, &captured) == 0 else { throw ChapterTextAssetError.storage }
        fileInfo = captured
        try boundary(.fileBound)
        // Pin the original inode until cleanup; an unlinked replacement cannot
        // reuse the inode number and masquerade as our owned entry.
        identity = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard identity >= 0 else { throw ChapterTextAssetError.storage }
        try boundary(.identityBound)
        let custody = Custody(baseFD: base, directoryFD: directory, identityFD: identity, name: name,
            url: storage.appendingPathComponent(name).appendingPathComponent("source.utf8"), directory: dirInfo!, file: fileInfo!)
        transferred = true
        try Task.checkCancellation(); try write(writer); try writer.synchronize()
        guard fchmod(fd, mode_t(0o400)) == 0 else { throw ChapterTextAssetError.storage }
        try writer.close()
        let result = ChapterTextAsset(manifest: manifest, session: session, custody: custody)
        _ = try result.readVerifiedText()
        return result
    }
}
