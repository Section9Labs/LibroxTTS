import Foundation
import CryptoKit

public struct ChapterTextRange: Codable, Sendable, Equatable {
    public let offset: Int
    public let length: Int
    public init(offset: Int, length: Int) { self.offset = offset; self.length = length }
    func valid(in count: Int) -> Bool { offset >= 0 && length > 0 && offset <= count && length <= count - offset }
}

/// Timings are actual post-cadence rendered frame boundaries. Component text
/// fragments intentionally have no invented sentence or word timestamps.
public struct ChapterAudioUnit: Codable, Sendable, Equatable {
    public let source: ChapterTextRange
    public let fragments: [ChapterTextRange]
    public let startFrame: Int64
    public let frameCount: Int64
    public init(source: ChapterTextRange, fragments: [ChapterTextRange], startFrame: Int64, frameCount: Int64) {
        self.source = source; self.fragments = fragments
        self.startFrame = startFrame; self.frameCount = frameCount
    }
}

/// Describes a completed asset, not a streaming or partially uploaded chapter.
public struct ChapterArtifactManifest: Codable, Sendable, Equatable {
    public static let revision = "librox-chapter-artifact-1"
    public let schemaVersion: Int
    public let renderKey: String
    public let audioSHA256: String
    public let audioByteCount: Int64
    public let decodedFrameCount: Int64
    public let codecRevision: String
    public let units: [ChapterAudioUnit]

    public init(renderKey: String, audioSHA256: String, audioByteCount: Int64,
                decodedFrameCount: Int64, codecRevision: String, units: [ChapterAudioUnit]) {
        schemaVersion = 1; self.renderKey = renderKey; self.audioSHA256 = audioSHA256; self.audioByteCount = audioByteCount
        self.decodedFrameCount = decodedFrameCount; self.codecRevision = codecRevision; self.units = units
    }

    public func validate(for request: ChapterRenderRequest) throws {
        guard schemaVersion == 1, renderKey == (try request.renderKey()), isDigest(audioSHA256),
              (1...1_073_741_824).contains(audioByteCount), decodedFrameCount > 0,
              !codecRevision.isEmpty, codecRevision.utf8.count <= 128,
              !units.isEmpty, units.count <= 100_000 else { throw ChapterWorkerError.invalidManifest }
        if let delivery = request.delivery, codecRevision != delivery.codecRevision {
            throw ChapterWorkerError.invalidManifest
        }
        // Legacy requests were lossless-only. Missing delivery must never admit AAC.
        if request.delivery == nil, !["wav-f32-1", "alac24-1"].contains(codecRevision) {
            throw ChapterWorkerError.invalidManifest
        }
        var end: Int64 = 0, textEnd = 0
        for unit in units {
            guard unit.startFrame == end, unit.frameCount > 0,
                  unit.startFrame <= decodedFrameCount, unit.frameCount <= decodedFrameCount - unit.startFrame,
                  unit.source.valid(in: request.source.utf16Length), unit.source.offset >= textEnd,
                  !unit.fragments.isEmpty, unit.fragments.count <= 128 else { throw ChapterWorkerError.invalidManifest }
            var fragmentEnd = unit.source.offset
            for fragment in unit.fragments {
                guard fragment.valid(in: request.source.utf16Length), fragment.offset >= fragmentEnd,
                      fragment.offset >= unit.source.offset,
                      fragment.offset + fragment.length <= unit.source.offset + unit.source.length
                else { throw ChapterWorkerError.invalidManifest }
                fragmentEnd = fragment.offset + fragment.length
            }
            end = unit.startFrame + unit.frameCount; textEnd = unit.source.offset + unit.source.length
        }
        guard end == decodedFrameCount else { throw ChapterWorkerError.invalidManifest }
    }

    /// The host has the original document. Validate scalar-safe ranges against
    /// that exact hashed extraction before using the source map for playback.
    public func validateSourceMap(text: String, for request: ChapterRenderRequest) throws {
        try validate(for: request); try request.source.validate(text: text)
        let utf16 = Array(text.utf16)
        func scalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0 && offset < utf16.count else { return true }
            return !((0xD800...0xDBFF).contains(utf16[offset - 1]) && (0xDC00...0xDFFF).contains(utf16[offset]))
        }
        for unit in units {
            for span in [unit.source] + unit.fragments {
                guard scalarBoundary(span.offset), scalarBoundary(span.offset + span.length),
                      Range(NSRange(location: span.offset, length: span.length), in: text) != nil
                else { throw ChapterWorkerError.invalidManifest }
            }
        }
    }

    /// Streaming bounded byte verification. A codec adapter must ALSO decode and
    /// validate format, frame count, finite samples, peak policy and watermark.
    /// Passing this method alone never makes a chapter playable.
    public func verifyBytes(at file: URL, for request: ChapterRenderRequest) throws {
        try validate(for: request)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == audioByteCount else { throw ChapterWorkerError.invalidManifest }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256(), count: Int64 = 0
        while true {
            try Task.checkCancellation()
            let part = try handle.read(upToCount: 65_536) ?? Data()
            if part.isEmpty { break }
            count += Int64(part.count)
            guard count <= audioByteCount else { throw ChapterWorkerError.invalidManifest }
            digest.update(data: part)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == audioByteCount, hash == audioSHA256 else { throw ChapterWorkerError.invalidManifest }
    }
}
