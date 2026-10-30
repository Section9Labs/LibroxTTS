import Foundation
import CryptoKit
import Darwin

public enum ChapterLocalHandoffError: Error, Equatable {
    case invalidReference, invalidRecord, budget, storage, collision
}

/// Content identity only: neither an account credential nor proof of publication.
public struct ChapterLocalHandoffReference: Codable, Sendable, Equatable {
    public let identifier: String
    public init(identifier: String) throws {
        guard isDigest(identifier) else { throw ChapterLocalHandoffError.invalidReference }
        self.identifier = identifier
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identifier: c.decode(String.self, forKey: .identifier))
    }
    private enum CodingKeys: String, CodingKey { case identifier }
}

/// SDK-produced, live-process publication completion. Epoch is not serialized.
/// This is complete file publication, not Reader acceptance or playable state.
public struct ChapterLocalHandoffPublication: Sendable {
    public let reference: ChapterLocalHandoffReference
    public let request: ChapterRenderRequest
    public let session: ChapterAccountSession
}

/// Immutable, account-partitioned complete asset transfer. No shared mutable
/// journal, demand acknowledgement, distributed claim, or implicit playback.
/// The publisher alone writes the private directory; readers never mutate it.
public enum ChapterLocalHandoff {
    public static let maximumMetadataBytes = 8 * 1024 * 1024
    public static let maximumSourceUTF16 = 131072
    private struct Envelope: Codable, Sendable {
        let version: Int
        let request: ChapterRenderRequest
        let manifest: ChapterArtifactManifest
    }
    enum Event: Sendable { case beforeCommit, afterCommit, beforeAdoption, afterAdoption }
    typealias Checkpoint = @Sendable (Event) async throws -> Void

    /// Deterministic recovery key. A returned identity alone does not make an
    /// asset queued, published, acknowledged or playable.
    public static func contentReference(for artifact: ChapterLocalArtifact, submission: ChapterSubmission) throws -> ChapterLocalHandoffReference {
        guard artifact.request == submission.request, artifact.session == submission.session else { throw ChapterWorkerError.accountMismatch }
        try artifact.manifest.validateCompleteSourceMap(text: submission.originalText, for: submission.request)
        return try .init(identifier: digest(metadata(request: artifact.request, manifest: artifact.manifest)))
    }
    public static func publishVerified(_ artifact: ChapterLocalArtifact, submission: ChapterSubmission,
                                       gate: ChapterAccountSessionGate, directory: URL) async throws -> ChapterLocalHandoffPublication {
        let reference = try await publish(artifact, submission: submission, gate: gate, directory: directory)
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return .init(reference: reference, request: submission.request, session: submission.session)
    }
    public static func publish(_ artifact: ChapterLocalArtifact, submission: ChapterSubmission,
                               gate: ChapterAccountSessionGate, directory: URL) async throws -> ChapterLocalHandoffReference {
        try await publish(artifact, submission: submission, gate: gate, directory: directory, checkpoint: { _ in })
    }
    static func publish(_ artifact: ChapterLocalArtifact, submission: ChapterSubmission,
                        gate: ChapterAccountSessionGate, directory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChapterLocalHandoffReference {
        try Task.checkCancellation()
        guard artifact.request == submission.request, artifact.session == submission.session else { throw ChapterWorkerError.accountMismatch }
        try artifact.manifest.validateCompleteSourceMap(text: submission.originalText, for: submission.request)
        let session = submission.session
        let bytes = try metadata(request: artifact.request, manifest: artifact.manifest)
        let reference = try ChapterLocalHandoffReference(identifier: digest(bytes))
        let manifest = artifact.manifest
        return try await artifact.withFileAccess(session: session, gate: gate) { source in
            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let parent = try Directory(directory)
                guard !within(parent.url, source.deletingLastPathComponent()) else { throw ChapterLocalHandoffError.storage }
                let stage = try Publication(parent: parent, reference: reference)
                try stage.copyAudio(source, manifest: manifest)
                try stage.writeMetadata(bytes)
                try await checkpoint(.beforeCommit)
                try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
                try stage.commit(expectedMetadata: bytes, manifest: manifest)
                try await checkpoint(.afterCommit)
                try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
                try parent.validate()
                return reference
            }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
    }
    /// The receiver supplies its own exact request/text/session. Producer epochs
    /// are deliberately absent: they cannot authorize the receiver's lifecycle.
    /// Metadata-only size admission. This is NOT decoded custody or playable.
    /// Receive revalidates the exact immutable identity before its actual copy.
    public static func inspectManifest(_ reference: ChapterLocalHandoffReference, submission: ChapterSubmission,
                                       gate: ChapterAccountSessionGate, directory: URL) async throws -> ChapterArtifactManifest {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            let parent = try Directory(directory)
            let bundle = try Directory(parent.url.appendingPathComponent(reference.identifier))
            let bytes = try readMetadata(bundle)
            guard digest(bytes) == reference.identifier else { throw ChapterLocalHandoffError.invalidRecord }
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 1, envelope.request == submission.request,
                  try metadata(request: envelope.request, manifest: envelope.manifest) == bytes
            else { throw ChapterLocalHandoffError.invalidRecord }
            try envelope.manifest.validateCompleteSourceMap(text: submission.originalText, for: submission.request)
            try parent.validate(); try bundle.validate()
            try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
            return envelope.manifest
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return result
    }
    public static func receive(_ reference: ChapterLocalHandoffReference, submission: ChapterSubmission,
                               gate: ChapterAccountSessionGate, directory: URL,
                               storageDirectory: URL) async throws -> ChapterLocalArtifact {
        try await receive(reference, submission: submission, gate: gate, directory: directory,
            storageDirectory: storageDirectory, checkpoint: { _ in })
    }
    static func receive(_ reference: ChapterLocalHandoffReference, submission: ChapterSubmission,
                        gate: ChapterAccountSessionGate, directory: URL, storageDirectory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChapterLocalArtifact {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            let parent = try Directory(directory)
            let bundle = try Directory(parent.url.appendingPathComponent(reference.identifier))
            let storage = try Directory(storageDirectory)
            guard !same(parent.identity, storage.identity), !same(bundle.identity, storage.identity),
                  !within(storage.url, parent.url) else { throw ChapterLocalHandoffError.storage }
            let bytes = try readMetadata(bundle)
            guard digest(bytes) == reference.identifier else { throw ChapterLocalHandoffError.invalidRecord }
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 1, envelope.request == submission.request,
                  try metadata(request: envelope.request, manifest: envelope.manifest) == bytes
            else { throw ChapterLocalHandoffError.invalidRecord }
            try envelope.manifest.validateCompleteSourceMap(text: submission.originalText, for: submission.request)
            try await checkpoint(.beforeAdoption)
            try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
            try parent.validate(); try bundle.validate(); try storage.validate()
            let artifact = try await ChapterLocalArtifact.adopt(download: bundle.url.appendingPathComponent("audio"),
                request: submission.request, manifest: envelope.manifest, originalText: submission.originalText,
                session: submission.session, gate: gate, storageDirectory: storageDirectory)
            try await checkpoint(.afterAdoption)
            try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
            try parent.validate(); try bundle.validate(); try storage.validate()
            guard try readMetadata(bundle) == bytes else { throw ChapterLocalHandoffError.invalidRecord }
            return artifact
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return result
    }
    private static func metadata(request: ChapterRenderRequest, manifest: ChapterArtifactManifest) throws -> Data {
        try manifest.validate(for: request)
        guard request.recipe.watermarkRevision == "disabled-1", request.source.utf16Length <= maximumSourceUTF16,
              manifest.decodedFrameCount <= ChapterLocalArtifact.maximumDecodedFrames,
              ChapterLocalArtifact.Codec(rawValue: manifest.codecRevision) != nil,
              manifest.units.count <= 4096 else { throw ChapterLocalHandoffError.budget }
        var fragments = 0
        for unit in manifest.units {
            guard unit.fragments.count <= maximumSourceUTF16 - fragments else { throw ChapterLocalHandoffError.budget }
            fragments += unit.fragments.count
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Envelope(version: 1, request: request, manifest: manifest))
        guard bytes.count <= maximumMetadataBytes else { throw ChapterLocalHandoffError.budget }
        return bytes
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
    private static func within(_ child: URL, _ parent: URL) -> Bool {
        let a = child.resolvingSymlinksInPath().standardizedFileURL.path
        let b = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// Task-local non-Sendable descriptors; none cross a task/actor boundary.
    private final class Directory {
        let url: URL, fd: Int32, identity: stat
        private let suppliedURL: URL
        init(_ url: URL) throws {
            guard url.isFileURL, !url.path.utf8.contains(0) else { throw ChapterLocalHandoffError.storage }
            let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw ChapterLocalHandoffError.storage }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { Darwin.close(fd); throw ChapterLocalHandoffError.storage }
            self.url = url.resolvingSymlinksInPath().standardizedFileURL
            self.suppliedURL = url; self.fd = fd; identity = info
            try validate()
        }
        deinit { Darwin.close(fd) }
        func validate() throws {
            var path = stat(), supplied = stat(), descriptor = stat()
            guard lstat(url.path, &path) == 0, fstat(fd, &descriptor) == 0,
                  lstat(suppliedURL.path, &supplied) == 0,
                  same(identity, path), same(identity, descriptor), same(identity, supplied) else { throw ChapterLocalHandoffError.storage }
        }
    }
    private static func readMetadata(_ directory: Directory) throws -> Data {
        try directory.validate()
        let fd = openat(directory.fd, "receipt.json", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ChapterLocalHandoffError.invalidRecord }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              (1...maximumMetadataBytes).contains(Int(before.st_size)) else { throw ChapterLocalHandoffError.invalidRecord }
        var bytes = Data(); bytes.reserveCapacity(Int(before.st_size))
        while bytes.count < before.st_size {
            try autoreleasepool {
                try Task.checkCancellation()
                let part = try input.read(upToCount: min(65536, Int(before.st_size) - bytes.count)) ?? Data()
                guard !part.isEmpty else { throw ChapterLocalHandoffError.invalidRecord }
                bytes.append(part)
            }
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, fstatat(directory.fd, "receipt.json", &path, AT_SYMLINK_NOFOLLOW) == 0,
              same(before, after), same(before, path), after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw ChapterLocalHandoffError.invalidRecord }
        return bytes
    }
    private static func verifyAudio(_ file: URL, manifest: ChapterArtifactManifest,
                                    write: ((Data) throws -> Void)? = nil) throws {
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ChapterLocalHandoffError.invalidRecord }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size == manifest.audioByteCount else { throw ChapterLocalHandoffError.invalidRecord }
        var hash = SHA256(), count: Int64 = 0
        while count < manifest.audioByteCount {
            try autoreleasepool {
                try Task.checkCancellation()
                let part = try input.read(upToCount: Int(min(65536, manifest.audioByteCount - count))) ?? Data()
                guard !part.isEmpty else { throw ChapterLocalHandoffError.invalidRecord }
                hash.update(data: part); try write?(part); count += Int64(part.count)
            }
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(file.path, &path) == 0,
              same(before, after), same(before, path), before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.audioSHA256
        else { throw ChapterLocalHandoffError.invalidRecord }
    }
    private final class Publication {
        let parent: Directory, stage: Directory, reference: ChapterLocalHandoffReference, temporaryName: String
        private var files: [String: stat] = [:]
        private var committed = false
        init(parent: Directory, reference: ChapterLocalHandoffReference) throws {
            self.parent = parent; self.reference = reference
            temporaryName = ".stage-" + UUID().uuidString
            guard mkdirat(parent.fd, temporaryName, 0o700) == 0 else { throw ChapterLocalHandoffError.storage }
            stage = try Directory(parent.url.appendingPathComponent(temporaryName))
        }
        deinit {
            if !committed {
                for (name, expected) in files {
                    var current = stat()
                    if fstatat(stage.fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(expected, current) { unlinkat(stage.fd, name, 0) }
                }
                var current = stat()
                if fstatat(parent.fd, temporaryName, &current, AT_SYMLINK_NOFOLLOW) == 0, same(stage.identity, current) {
                    unlinkat(parent.fd, temporaryName, AT_REMOVEDIR) // Unknown entries remain, never recursive cleanup.
                }
            }
        }
        private func writeFile(_ name: String, _ body: (FileHandle) throws -> Void) throws {
            try stage.validate(); try parent.validate()
            let fd = openat(stage.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ChapterLocalHandoffError.storage }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? output.close() }
            var identity = stat()
            guard fstat(fd, &identity) == 0 else { throw ChapterLocalHandoffError.storage }
            files[name] = identity
            try body(output); try output.synchronize()
            guard fchmod(fd, 0o400) == 0 else { throw ChapterLocalHandoffError.storage }
            try output.close()
        }
        func copyAudio(_ source: URL, manifest: ChapterArtifactManifest) throws {
            try writeFile("audio") { output in try verifyAudio(source, manifest: manifest, write: { try output.write(contentsOf: $0) }) }
        }
        func writeMetadata(_ bytes: Data) throws { try writeFile("receipt.json") { try $0.write(contentsOf: bytes) } }
        func commit(expectedMetadata: Data, manifest: ChapterArtifactManifest) throws {
            try parent.validate(); try stage.validate()
            guard try readMetadata(stage) == expectedMetadata else { throw ChapterLocalHandoffError.invalidRecord }
            try verifyAudio(stage.url.appendingPathComponent("audio"), manifest: manifest)
            guard fsync(stage.fd) == 0 else { throw ChapterLocalHandoffError.storage }
            let renamed = renameatx_np(parent.fd, temporaryName, parent.fd, reference.identifier, UInt32(RENAME_EXCL))
            if renamed == 0 {
                committed = true // Preserve complete publication even if later fsync/epoch checks fail.
            } else if errno == EEXIST {
                let existing = try Directory(parent.url.appendingPathComponent(reference.identifier))
                guard try readMetadata(existing) == expectedMetadata else { throw ChapterLocalHandoffError.collision }
                try verifyAudio(existing.url.appendingPathComponent("audio"), manifest: manifest)
            } else { throw ChapterLocalHandoffError.storage }
            // Reconciliation may follow an earlier ambiguous rename/fsync.
            // Matching visible bytes alone do not establish directory durability.
            guard fsync(parent.fd) == 0 else { throw ChapterLocalHandoffError.storage }
            try parent.validate()
        }
    }
}
