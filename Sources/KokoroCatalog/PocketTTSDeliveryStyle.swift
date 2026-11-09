import CryptoKit
import Foundation

/// A reference performance, not a native emotion/intensity parameter.
/// Original preserves the released Kyutai preset and its existing cache identity.
public enum PocketTTSDeliveryStyle: String, CaseIterable, Codable, Hashable, Sendable {
    case original, neutral, calm, happy, sad, worried, surprised
    case anger, confused, enthused, excited, frustrated, shout, tired

    public var name: String { rawValue.capitalized }
    /// New reference performances need the listener's own narration audition.
    public var isPreview: Bool { self != .original }
    public var cacheIdentity: String {
        self == .original ? "original" : PocketTTSDeliveryCatalog.identity + ":" + rawValue
    }
}

/// Optional, separately installed voice states. Base language packs remain valid.
/// Only bundled, hash-pinned exports are offered; source recordings alone do not
/// make an expressive preset available to the application.
public enum PocketTTSDeliveryCatalog {
    public static let sourceRevision = "490cfbee850a6d409076f477c766f567000a79b6"
    public static let identity = "pocket-delivery-voicezero-490cfbee-v1"
    public static let referenceVoiceNames = ["bill_boerst", "caro_davy", "peter_yearsley", "stuart_bell"]

    public enum DeliveryError: LocalizedError {
        case unsupportedVoice, unpublishedLanguage, missingOrInvalidAsset
        public var errorDescription: String? {
            switch self {
            case .unsupportedVoice: "This Max voice has no matching delivery-style reference. Choose Original or a supported narrator."
            case .unpublishedLanguage: "Max delivery-style exports are not available for this language yet."
            case .missingOrInvalidAsset: "This Max delivery style is missing or invalid. Install its voice pack before using it."
            }
        }
    }

    public static func stateName(voiceID: String, style: PocketTTSDeliveryStyle) throws -> String {
        guard let voice = PocketTTSCatalog.voice(id: voiceID),
              style == .original || referenceVoiceNames.contains(voice.name) else {
            throw DeliveryError.unsupportedVoice
        }
        return style == .original ? voice.name : voice.name + "__" + style.rawValue
    }

    public static func manifest(language: String) throws -> AssetManifest {
        guard PocketTTSCatalog.languages.contains(language),
              let url = Bundle.module.url(forResource: "delivery-" + language,
                                          withExtension: "json", subdirectory: "PocketTTS") else {
            throw DeliveryError.unpublishedLanguage
        }
        let manifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
        guard manifest.revision == identity else { throw DeliveryError.missingOrInvalidAsset }
        return manifest
    }

    /// A single performance plus provenance, avoiding a whole-language download.
    public static func manifest(voiceID: String, style: PocketTTSDeliveryStyle) throws -> AssetManifest {
        let name = try stateName(voiceID: voiceID, style: style)
        guard style != .original else { return try PocketTTSCatalog.manifest(language: PocketTTSCatalog.voice(id: voiceID)!.language) }
        let voice = PocketTTSCatalog.voice(id: voiceID)!
        let full = try manifest(language: voice.language)
        let path = "\(voice.language)/embeddings/\(name).safetensors"
        guard full.installedFiles.contains(where: { $0.path == path }) else {
            throw DeliveryError.missingOrInvalidAsset
        }
        let selected: (AssetManifest.File) -> Bool = { $0.path == path || !$0.path.contains("/embeddings/") }
        return AssetManifest(repository: full.repository, revision: full.revision,
                             files: full.files.filter(selected), installedFiles: full.installedFiles.filter(selected))
    }

    /// Suitable for a download picker. Availability is derived from actual exports,
    /// never from the existence of an enum case or upstream audio sample.
    public static func publishedStyles(voiceID: String) -> [PocketTTSDeliveryStyle] {
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { return [] }
        guard let manifest = try? manifest(language: voice.language) else { return [.original] }
        return PocketTTSDeliveryStyle.allCases.filter { style in
            guard style != .original else { return true }
            guard let name = try? stateName(voiceID: voiceID, style: style) else { return false }
            return manifest.installedFiles.contains { $0.path == "\(voice.language)/embeddings/\(name).safetensors" }
        }
    }

    /// May perform disk hashing. Call outside the main actor when populating UI.
    public static func installedStyles(voiceID: String, in directory: URL) throws -> [PocketTTSDeliveryStyle] {
        var result: [PocketTTSDeliveryStyle] = []
        for style in publishedStyles(voiceID: voiceID) {
            try Task.checkCancellation()
            do { try validate(style, voiceID: voiceID, in: directory); result.append(style) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return result
    }

    public static func validate(_ style: PocketTTSDeliveryStyle, voiceID: String, in directory: URL) throws {
        let name = try stateName(voiceID: voiceID, style: style)
        guard style != .original else { return }
        let voice = PocketTTSCatalog.voice(id: voiceID)!
        let manifest = try manifest(language: voice.language)
        guard let file = manifest.installedFiles.first(where: {
            $0.path == "\(voice.language)/embeddings/\(name).safetensors"
        }) else { throw DeliveryError.missingOrInvalidAsset }
        try validate(file, in: directory)
    }

    public static func validate(in directory: URL, language: String) throws {
        for file in try manifest(language: language).installedFiles { try validate(file, in: directory) }
    }

    private static func validate(_ file: AssetManifest.File, in directory: URL) throws {
        try Task.checkCancellation()
        let url = directory.appendingPathComponent(file.path)
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size) else {
            throw DeliveryError.missingOrInvalidAsset
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw DeliveryError.missingOrInvalidAsset
        }
    }
}
