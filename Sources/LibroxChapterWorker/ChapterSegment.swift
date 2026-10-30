import Foundation
import CryptoKit

/// One COMPLETE independently decodable file in an incremental chapter stream.
/// Source offsets are global chapter UTF16; audio unit frame offsets are local
/// to this file. Metadata is never playable custody or chapter completion.
public struct ChapterSegmentManifest: Codable, Sendable, Equatable {
    public static let revision = "librox-passage-segments-1"
    public static let maximumBytes: Int64 = 16 * 1_024 * 1_024
    public static let maximumFrames: Int64 = 121 * 24_000
    public let version: Int
    public let accountPartition: String
    public let chapterRenderKey: String
    public let segmentIndex: Int
    public let previousSegmentSHA256: String?
    public let sourceRange: ChapterTextRange
    public let chapterStartFrame: Int64
    public let audio: ChapterArtifactManifest

    public init(request: ChapterRenderRequest, segmentIndex: Int, previousSegmentSHA256: String?,
                sourceRange: ChapterTextRange, chapterStartFrame: Int64, audio: ChapterArtifactManifest,
                originalText: String) throws {
        version = 1; accountPartition = request.accountPartition; chapterRenderKey = try request.renderKey()
        self.segmentIndex = segmentIndex; self.previousSegmentSHA256 = previousSegmentSHA256
        self.sourceRange = sourceRange; self.chapterStartFrame = chapterStartFrame; self.audio = audio
        try validate(for: request, originalText: originalText)
    }

    public func validate(for request: ChapterRenderRequest, originalText: String) throws {
        try request.validate(); try request.source.validate(text: originalText)
        guard version == 1, accountPartition == request.accountPartition,
              chapterRenderKey == (try request.renderKey()), (0..<4096).contains(segmentIndex),
              chapterStartFrame >= 0, chapterStartFrame <= ChapterLocalArtifact.maximumDecodedFrames,
              audio.decodedFrameCount <= ChapterLocalArtifact.maximumDecodedFrames - chapterStartFrame,
              audio.audioByteCount <= Self.maximumBytes, audio.decodedFrameCount <= Self.maximumFrames,
              sourceRange.valid(in: request.source.utf16Length), request.source.utf16Length <= 131072,
              (segmentIndex == 0 ? previousSegmentSHA256 == nil : previousSegmentSHA256.map(isDigest) == true),
              !audio.units.isEmpty, audio.units.count <= 128 else { throw ChapterWorkerError.invalidManifest }
        try audio.validateSourceMap(text: originalText, for: request)
        let source = originalText as NSString, boundaries = Set(originalText.indices).union([originalText.endIndex])
        func range(_ span: ChapterTextRange) throws {
            guard let r = Range(NSRange(location: span.offset, length: span.length), in: originalText),
                  boundaries.contains(r.lowerBound), boundaries.contains(r.upperBound) else { throw ChapterWorkerError.invalidManifest }
        }
        func ignored(_ start: Int, _ end: Int) throws {
            guard end >= start, source.substring(with: NSRange(location: start, length: end - start))
                .allSatisfy({ $0.isWhitespace || $0 == "\u{FFFC}" }) else { throw ChapterWorkerError.invalidManifest }
        }
        try range(sourceRange)
        let sourceEnd = sourceRange.offset + sourceRange.length
        var end = sourceRange.offset
        for unit in audio.units {
            guard unit.source.offset >= end, unit.source.offset + unit.source.length <= sourceEnd else { throw ChapterWorkerError.invalidManifest }
            try range(unit.source); try ignored(end, unit.source.offset)
            var fragmentEnd = unit.source.offset
            for fragment in unit.fragments {
                try range(fragment); try ignored(fragmentEnd, fragment.offset)
                fragmentEnd = fragment.offset + fragment.length
            }
            end = unit.source.offset + unit.source.length; try ignored(fragmentEnd, end)
        }
        try ignored(end, sourceEnd)
        // Reject unbounded or noncanonical received JSON at the transport edge.
        guard try encoded().count <= 128 * 1024 else { throw ChapterWorkerError.invalidManifest }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public func sha256() throws -> String {
        SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
    }
    public static func decode(_ bytes: Data, request: ChapterRenderRequest, originalText: String) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 128 * 1024 else { throw ChapterWorkerError.invalidManifest }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate(for: request, originalText: originalText)
        guard try value.encoded() == bytes else { throw ChapterWorkerError.invalidManifest }
        return value
    }
}

/// Metadata-only validated contiguous prefix. Keeping this separate from media
/// custody prevents an ordered manifest from becoming a playback grant.
public struct ChapterSegmentPrefix: Sendable {
    public static let maximumMetadataBytes = 8 * 1024 * 1024
    public private(set) var segmentCount = 0
    public private(set) var decodedFrameCount: Int64 = 0
    public private(set) var sourceEnd = 0
    public private(set) var tailSHA256: String?
    private let request: ChapterRenderRequest
    private let originalText: String
    private var metadataBytes = 0
    public init(request: ChapterRenderRequest, originalText: String) throws {
        try request.validate(); try request.source.validate(text: originalText)
        guard request.source.utf16Length <= 131072 else { throw ChapterWorkerError.invalidManifest }
        self.request = request; self.originalText = originalText
    }
    public mutating func append(_ manifest: ChapterSegmentManifest) throws {
        try manifest.validate(for: request, originalText: originalText)
        guard manifest.segmentIndex == segmentCount, manifest.previousSegmentSHA256 == tailSHA256,
              manifest.chapterStartFrame == decodedFrameCount, manifest.sourceRange.offset == sourceEnd else { throw ChapterWorkerError.invalidManifest }
        let bytes = try manifest.encoded()
        guard bytes.count <= Self.maximumMetadataBytes - metadataBytes else { throw ChapterWorkerError.invalidManifest }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        segmentCount += 1; decodedFrameCount += manifest.audio.decodedFrameCount
        sourceEnd += manifest.sourceRange.length; tailSHA256 = hash
        metadataBytes += bytes.count
    }
    public func completionSeal() throws -> ChapterSegmentCompletionSeal {
        guard segmentCount > 0, let tailSHA256,
              (originalText as NSString).substring(from: sourceEnd).allSatisfy({ $0.isWhitespace || $0 == "\u{FFFC}" })
        else { throw ChapterWorkerError.invalidManifest }
        let seal = ChapterSegmentCompletionSeal(version: 1, accountPartition: request.accountPartition, chapterRenderKey: try request.renderKey(),
                     segmentCount: segmentCount, decodedFrameCount: decodedFrameCount, tailSHA256: tailSHA256)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(seal).count <= Self.maximumMetadataBytes - metadataBytes else { throw ChapterWorkerError.invalidManifest }
        return seal
    }
    public func validate(_ seal: ChapterSegmentCompletionSeal) throws {
        guard try completionSeal() == seal else { throw ChapterWorkerError.invalidManifest }
    }
}

/// Final ordered prefix seal; does NOT imply that files have uploaded/downloaded
/// or passed Reader custody. A prefix with fewer segments remains a prefix.
public struct ChapterSegmentCompletionSeal: Codable, Sendable, Equatable {
    public let version: Int
    public let accountPartition, chapterRenderKey: String
    public let segmentCount: Int
    public let decodedFrameCount: Int64
    public let tailSHA256: String
}

/// Segment-only verified private custody. The reused low-level copy/hash/codec
/// verifier is deliberately private: no partial chapter artifact escapes here.
public final class ChapterLocalSegmentArtifact: Sendable {
    public let manifest: ChapterSegmentManifest
    public let request: ChapterRenderRequest
    public let session: ChapterAccountSession
    public var decodedPeak: Float { custody.decodedPeak }
    private let custody: ChapterLocalArtifact
    private init(manifest: ChapterSegmentManifest, custody: ChapterLocalArtifact) {
        self.manifest = manifest; request = custody.request; session = custody.session; self.custody = custody
    }
    public static func adopt(download: URL, manifest: ChapterSegmentManifest, request: ChapterRenderRequest,
                             originalText: String, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                             storageDirectory: URL) async throws -> ChapterLocalSegmentArtifact {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        try manifest.validate(for: request, originalText: originalText)
        let custody = try await ChapterLocalArtifact.adopt(download: download, request: request, manifest: manifest.audio,
            originalText: originalText, session: session, gate: gate, storageDirectory: storageDirectory)
        try await gate.validate(session); try Task.checkCancellation()
        return .init(manifest: manifest, custody: custody)
    }
    public func withFileAccess<Value: Sendable>(session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                                               _ body: @Sendable (URL) async throws -> Value) async throws -> Value {
        try await custody.withFileAccess(session: session, gate: gate, body)
    }
}
