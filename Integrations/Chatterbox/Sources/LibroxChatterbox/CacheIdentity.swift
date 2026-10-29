import Foundation
import CryptoKit
import KokoroNarration

extension ChatterboxRequest {
    /// Bump when preprocessing, conditioning, sampling or tensor interpretation changes.
    public static let adapterRevision = "chatterbox-coreml-v3-librox-4-logical-layout"

    /// The host supplies hashes of its immutable installed-model manifest and the
    /// exact conditioning file (including the installed default, when used).
    /// Existing Kokoro cache revisions alone are insufficient for this backend.
    public func cacheKey(modelManifestSHA256: String, conditioningSHA256: String,
                         rendererProfile: String = "automatic") throws -> String {
        func valid(_ hash: String) -> Bool {
            hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard valid(modelManifestSHA256), valid(conditioningSHA256) else {
            throw ChatterboxNarrationError.invalidOptions
        }
        let fields: [String: String] = [
            "backend": Self.adapterRevision,
            "rendererProfile": rendererProfile,
            "model": modelManifestSHA256, "conditioning": conditioningSHA256,
            "text": text, "language": language,
            "exaggeration": String(exaggeration), "cfg": String(guidance),
            "temperature": String(temperature), "maxTokens": String(maxTokens),
            "seed": seed.map(String.init) ?? "none",
            "voiceID": sourceContext?.voiceID ?? "installed-default-or-explicit-reference",
            "speakerID": sourceContext?.speakerID ?? "none",
            "performanceRevision": NarrationPerformance.revision,
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(fields)).map { String(format: "%02x", $0) }.joined()
    }
}
