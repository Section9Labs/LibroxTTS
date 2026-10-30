import Foundation
import CryptoKit
import AVFoundation
import AudioToolbox
import Darwin

public enum ChapterLocalArtifactError: Error, Equatable {
    case unsupportedPolicy, unsupportedCodec, invalidFile, budgetExceeded, invalidFormat, invalidFrames, invalidSamples
}

/// A verified private copy of a complete chapter. Only adopt() can construct one.
/// This is local media custody, not a durable queue or an audio-content judgement.
public final class ChapterLocalArtifact: Sendable {
    public enum Codec: String, Sendable { case wavFloat32 = "wav-f32-1", alac24 = "alac24-1", aac64 = "aac-lc-64k-1" }
    public static let maximumDecodedFrames: Int64 = 518_400_000 // six hours at 24 kHz
    public static let maximumEncodedBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    public static let decodeChunkFrames: AVAudioFrameCount = 65_536
    public let request: ChapterRenderRequest
    public let session: ChapterAccountSession
    public let manifest: ChapterArtifactManifest
    public let codec: Codec
    public let decodedFrameCount: Int64
    public let decodedPeak: Float
    private let custody: Custody

    private final class Custody: Sendable {
        let directory: URL
        let file: URL
        init(directory: URL, file: URL) { self.directory = directory; self.file = file }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private init(request: ChapterRenderRequest, session: ChapterAccountSession,
                 manifest: ChapterArtifactManifest, codec: Codec, peak: Float, custody: Custody) {
        self.request = request; self.session = session; self.manifest = manifest
        self.codec = codec; self.decodedFrameCount = manifest.decodedFrameCount
        self.decodedPeak = peak; self.custody = custody
    }

    /// storageDirectory must be an existing, app-owned directory. This factory
    /// creates only a new UUID child and removes only that child on failure/release.
    /// It never moves, rewrites or deletes the incoming downloaded file.
    public static func adopt(download: URL, request: ChapterRenderRequest,
                             manifest: ChapterArtifactManifest, originalText: String,
                             session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                             storageDirectory: URL) async throws -> ChapterLocalArtifact {
        try Task.checkCancellation()
        guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session)
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try verifyAndCopy(download: download, request: request, manifest: manifest,
                              originalText: originalText, session: session, storageDirectory: storageDirectory)
        }
        let artifact = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        try await gate.validate(session)
        try Task.checkCancellation()
        return artifact
    }

    /// Retain this handle for the entire playback lifetime. The URL is scoped
    /// access to the read-only owned copy, never an alternate activation path.
    /// The host must also stop playback immediately on account/lifecycle revocation.
    public func withFileAccess<Result: Sendable>(session: ChapterAccountSession,
                                                gate: ChapterAccountSessionGate,
                                                _ body: @Sendable (URL) async throws -> Result) async throws -> Result {
        defer { withExtendedLifetime(self) {} }
        try Task.checkCancellation()
        guard session == self.session else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session)
        try Task.checkCancellation()
        let result = try await body(custody.file)
        try Task.checkCancellation()
        try await gate.validate(session)
        try Task.checkCancellation()
        return result
    }

    private static func verifyAndCopy(download: URL, request: ChapterRenderRequest,
                                      manifest: ChapterArtifactManifest, originalText: String,
                                      session: ChapterAccountSession, storageDirectory: URL) throws -> ChapterLocalArtifact {
        try Task.checkCancellation()
        try manifest.validateSourceMap(text: originalText, for: request)
        guard request.recipe.watermarkRevision == "disabled-1" else { throw ChapterLocalArtifactError.unsupportedPolicy }
        guard let codec = Codec(rawValue: manifest.codecRevision) else { throw ChapterLocalArtifactError.unsupportedCodec }
        // Manifest validation may impose a stricter encoded-byte budget. It is
        // never bypassed here (the original contract currently caps it at 1 GiB).
        guard manifest.audioByteCount <= maximumEncodedBytes,
              manifest.decodedFrameCount <= maximumDecodedFrames else { throw ChapterLocalArtifactError.budgetExceeded }
        guard download.isFileURL, storageDirectory.isFileURL,
              !download.path.utf8.contains(0), !storageDirectory.path.utf8.contains(0) else { throw ChapterLocalArtifactError.invalidFile }
        let base = try storageDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard base.isDirectory == true, base.isSymbolicLink != true else { throw ChapterLocalArtifactError.invalidFile }
        // O_NONBLOCK prevents a FIFO path from blocking before fstat rejects it.
        let descriptor = Darwin.open(download.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw ChapterLocalArtifactError.invalidFile }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size == manifest.audioByteCount else { throw ChapterLocalArtifactError.invalidFile }

        let directory = storageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(codec == .wavFloat32 ? "audio.wav" : "audio.m4a")
        let custody = Custody(directory: directory, file: file)
        let outputFD = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard outputFD >= 0 else { throw ChapterLocalArtifactError.invalidFile }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var hash = SHA256(), copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let part = try input.read(upToCount: 65_536) ?? Data()
            if part.isEmpty { break }
            guard Int64(part.count) <= manifest.audioByteCount - copied else { throw ChapterLocalArtifactError.invalidFile }
            hash.update(data: part)
            try output.write(contentsOf: part)
            copied += Int64(part.count)
        }
        guard copied == manifest.audioByteCount,
              hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.audioSHA256
        else { throw ChapterLocalArtifactError.invalidFile }
        try output.synchronize()
        try output.close()
        guard chmod(file.path, mode_t(0o400)) == 0 else { throw ChapterLocalArtifactError.invalidFile }
        try Task.checkCancellation()
        let peak = try decode(file: file, codec: codec, expectedFrames: manifest.decodedFrameCount)
        try Task.checkCancellation()
        return ChapterLocalArtifact(request: request, session: session, manifest: manifest,
                                    codec: codec, peak: peak, custody: custody)
    }

    private static func decode(file: URL, codec: Codec, expectedFrames: Int64) throws -> Float {
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = audio.fileFormat.streamDescription.pointee
        guard format.mSampleRate == 24_000, format.mChannelsPerFrame == 1,
              audio.processingFormat.sampleRate == 24_000, audio.processingFormat.channelCount == 1
        else { throw ChapterLocalArtifactError.invalidFormat }
        switch codec {
        case .wavFloat32:
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            let header = try input.read(upToCount: 12) ?? Data()
            guard header.count == 12, header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8),
                  format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            else { throw ChapterLocalArtifactError.invalidFormat }
        case .alac24:
            guard format.mFormatID == kAudioFormatAppleLossless,
                  format.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData
            else { throw ChapterLocalArtifactError.invalidFormat }
        case .aac64:
            // Actual AAC-LC at the declared rate/channel layout. Bitrate is not
            // inferred from the label; frames and decoded samples are verified.
            guard format.mFormatID == kAudioFormatMPEG4AAC else { throw ChapterLocalArtifactError.invalidFormat }
        }
        guard audio.length == expectedFrames else { throw ChapterLocalArtifactError.invalidFrames }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: decodeChunkFrames)
        else { throw ChapterLocalArtifactError.budgetExceeded }
        var frames: Int64 = 0, peak: Float = 0
        while frames < expectedFrames {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(Int64(decodeChunkFrames), expectedFrames - frames))
            try audio.read(into: buffer, frameCount: requested)
            let count = Int64(buffer.frameLength)
            guard count > 0, count <= Int64(requested), let samples = buffer.floatChannelData?[0]
            else { throw ChapterLocalArtifactError.invalidFrames }
            for index in 0..<Int(count) {
                let sample = samples[index]
                guard sample.isFinite, abs(sample) <= 1 else { throw ChapterLocalArtifactError.invalidSamples }
                peak = max(peak, abs(sample))
            }
            frames += count
        }
        // AVAudioFile may throw an opaque error on an extra read past EOF.
        // All declared frames were actually decoded; require exact final position.
        guard frames == expectedFrames, audio.framePosition == audio.length else { throw ChapterLocalArtifactError.invalidFrames }
        return peak
    }
}
