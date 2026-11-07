// SPDX-License-Identifier: Apache-2.0 OR MIT
import CryptoKit
import Foundation

public enum PocketTTSCatalog {
    public static let attribution = """
    Pocket TTS by Kyutai. Model weights: Creative Commons Attribution 4.0
    (https://creativecommons.org/licenses/by/4.0/). Model:
    https://huggingface.co/kyutai/pocket-tts-without-voice-cloning
    Native Swift MLX execution adapted from Kyutai Pocket TTS and MLX Audio Swift
    (MIT; Prince Canuma). Original model tensors; no acoustic fine-tuning.
    Voice contributors and original recording URLs are in each language pack's
    VOICE-CREDITS.json; source licenses: https://huggingface.co/kyutai/tts-voices
    """
    public static let identity = "pocket-tts-mlx-2026-11-07"
    public static let isDownloadPublished = false
    public static let languages = ["en", "fr", "de", "pt", "it", "es", "nl"]
    public static let voiceNames = ["alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "daan", "eponine", "estelle", "eve", "fantine", "george", "giovanni", "jane", "javert", "juergen", "lola", "marius", "mary", "michael", "paul", "peter_yearsley", "rafael", "stuart_bell", "vera"]
    public static let defaultVoices = ["en": "alba", "fr": "estelle", "de": "juergen", "pt": "rafael", "it": "giovanni", "es": "lola", "nl": "daan"]
    public struct Voice: Sendable, Identifiable {
        public let name: String
        public let language: String
        public var id: String { "pocket-\(name)-\(language)-v1" }
    }
    public static var voices: [Voice] { languages.flatMap { language in voiceNames.map { Voice(name: $0, language: language) } } }
    public static func voice(id: String) -> Voice? { voices.first { $0.id == id } }
    public static func manifest(language: String? = nil) throws -> AssetManifest {
        let selected = language.map { [$0] } ?? languages
        guard selected.allSatisfy(languages.contains) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let manifests = try selected.map { code in
            guard let url = Bundle.module.url(forResource: code, withExtension: "json", subdirectory: "PocketTTS") else { throw CocoaError(.fileNoSuchFile) }
            return try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
        }
        return AssetManifest(repository: "Section9Labs/LibroxTTS", revision: identity,
            files: manifests.flatMap(\.files), installedFiles: manifests.flatMap(\.installedFiles))
    }
    public static func validate(in directory: URL, language: String) throws {
        for file in try manifest(language: language).installedFiles {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.path)
            guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(file.size) else { throw CocoaError(.fileReadCorruptFile) }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}
