import Foundation
import CryptoKit

public enum ChapterWorkerError: Error, Equatable {
    case invalidIdentity, invalidManifest, accountMismatch, staleClaim, disabled, busy, invalidTransition
}

func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

/// Content identity is independent of a device's local library UUID.
public struct ChapterSourceIdentity: Codable, Sendable, Equatable {
    public let bookSHA256: String
    public let chapterKey: String
    public let textSHA256: String
    public let extractionRevision: String
    public let utf16Length: Int

    public init(bookSHA256: String, chapterKey: String, textSHA256: String,
                extractionRevision: String, utf16Length: Int) throws {
        self.bookSHA256 = bookSHA256; self.chapterKey = chapterKey
        self.textSHA256 = textSHA256; self.extractionRevision = extractionRevision
        self.utf16Length = utf16Length
        try validate()
    }

    public func validate() throws {
        guard isDigest(bookSHA256), isDigest(textSHA256), !chapterKey.isEmpty,
              chapterKey.utf8.count <= 1_024, !extractionRevision.isEmpty,
              extractionRevision.utf8.count <= 256, (1...10_000_000).contains(utf16Length)
        else { throw ChapterWorkerError.invalidIdentity }
    }

    public func validate(text: String) throws {
        try validate()
        guard text.utf16.count == utf16Length else { throw ChapterWorkerError.invalidIdentity }
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        guard digest == textSHA256 else { throw ChapterWorkerError.invalidIdentity }
    }
}

/// Explicit audible identity; host UI labels and local paths are excluded.
/// Initial cross-device capability is stock voices only. This API carries no
/// recording, conditioning bytes, source text or private voice upload mechanism.
public struct ChapterRenderRecipe: Codable, Sendable, Equatable {
    public let language: String
    public let stockVoiceID: String
    public let conditioningSHA256: String
    public let modelSHA256: String
    public let rendererProfile: String
    public let plannerRevision: String
    public let expressionSHA256: String
    /// Canonical digest of ALL effective sampling/token/solver options.
    public let synthesisOptionsSHA256: String
    public let seedPolicy: String
    public let watermarkRevision: String
    public let sampleRate: Int

    public init(language: String, stockVoiceID: String, conditioningSHA256: String,
                modelSHA256: String, rendererProfile: String, plannerRevision: String,
                expressionSHA256: String, synthesisOptionsSHA256: String, seedPolicy: String, watermarkRevision: String,
                sampleRate: Int = 24_000) throws {
        self.language = language; self.stockVoiceID = stockVoiceID
        self.conditioningSHA256 = conditioningSHA256; self.modelSHA256 = modelSHA256
        self.rendererProfile = rendererProfile; self.plannerRevision = plannerRevision
        self.expressionSHA256 = expressionSHA256; self.seedPolicy = seedPolicy
        self.synthesisOptionsSHA256 = synthesisOptionsSHA256
        self.watermarkRevision = watermarkRevision; self.sampleRate = sampleRate
        try validate()
    }

    public func validate() throws {
        guard ["en", "es"].contains(language), sampleRate == 24_000,
              isDigest(conditioningSHA256), isDigest(modelSHA256), isDigest(expressionSHA256), isDigest(synthesisOptionsSHA256),
              [stockVoiceID, rendererProfile, plannerRevision, seedPolicy, watermarkRevision]
                .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 })
        else { throw ChapterWorkerError.invalidIdentity }
    }
}

/// Delivery changes encoded bytes, never the synthesis recipe. AAC is lossy;
/// its nominal bitrate is an encoder request, not an audio-quality guarantee.
public enum ChapterAudioDelivery: String, Codable, Sendable, CaseIterable {
    case lossless = "alac24-1"
    case smaller = "aac-lc-64k-1"

    public var codecRevision: String { rawValue }
    public var isLossless: Bool { self == .lossless }
}

public struct ChapterRenderRequest: Codable, Sendable, Equatable {
    public static let revision = "librox-chapter-request-1"
    public let schemaVersion: Int
    /// Opaque, locally derived account partition. Never reuse state after account changes.
    public let accountPartition: String
    public let source: ChapterSourceIdentity
    public let recipe: ChapterRenderRecipe
    /// nil preserves pre-format request identities and their WAV/ALAC admission.
    /// New hosts must explicitly submit the user's selected delivery format.
    public let delivery: ChapterAudioDelivery?
    public var effectiveDelivery: ChapterAudioDelivery { delivery ?? .lossless }

    public init(accountPartition: String, source: ChapterSourceIdentity, recipe: ChapterRenderRecipe,
                delivery: ChapterAudioDelivery? = nil) throws {
        schemaVersion = 1; self.accountPartition = accountPartition; self.source = source; self.recipe = recipe; self.delivery = delivery
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1, isDigest(accountPartition) else { throw ChapterWorkerError.invalidIdentity }
        try source.validate(); try recipe.validate()
    }

    /// Deterministic within and across devices; account partitioning is separate.
    public func renderKey() throws -> String {
        try validate()
        struct Content: Encodable {
            let revision: String; let source: ChapterSourceIdentity; let recipe: ChapterRenderRecipe
            let delivery: ChapterAudioDelivery?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(Content(revision: Self.revision, source: source, recipe: recipe, delivery: delivery)))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Shared synthesis identity permits reuse of verified PCM when encoding
    /// another delivery format. It must not substitute for the delivered asset key.
    public func synthesisKey() throws -> String {
        try validate()
        return try ChapterRenderRequest(accountPartition: accountPartition, source: source, recipe: recipe).renderKey()
    }
}
