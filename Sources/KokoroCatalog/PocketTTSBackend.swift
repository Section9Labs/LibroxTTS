import Foundation

/// Max uses the same model and sampling profile on both platforms. Only its
/// execution format and installation/cache identities differ.
public enum PocketTTSBackend: String, Codable, Sendable {
    case mlx, coreML

    public static var platform: Self {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .coreML
        #else
        .mlx
        #endif
    }

    public var repositoryID: String {
        self == .coreML ? PocketTTSCoreMLCatalog.identity : PocketTTSCatalog.identity
    }
    public var runtimeIdentity: String {
        switch self {
        case .mlx: "pocket-mlx-28770c06-v3:quality4:adaptive:warm12:eos6:fp32"
        case .coreML: "pocket-coreml-28770c06-v1:fp32:tanh:quality4:adaptive:warm12:eos6"
        }
    }
    public var isDownloadPublished: Bool {
        self == .coreML ? PocketTTSCoreMLCatalog.isDownloadPublished : PocketTTSCatalog.isDownloadPublished
    }
    public func manifest(language: String? = nil) throws -> AssetManifest {
        switch self {
        case .mlx: try PocketTTSCatalog.manifest(language: language)
        case .coreML: try PocketTTSCoreMLCatalog.manifest(language: language)
        }
    }
}

/// Portable Core ML packages, compiled on the destination device. Tokenizer,
/// configuration, voices and credits reuse the immutable original asset URLs.
/// The original model.safetensors is never part of a Core ML installation.
public enum PocketTTSCoreMLCatalog {
    public static let identity = "pocket-tts-coreml-2026-11-10-v1"
    // Enable only after the immutable assets have been uploaded and verified.
    public static let isDownloadPublished = false
    public static let stages = ["text", "latent", "flow4", "flow8", "flowstep", "mimi"]

    public static func sharedManifest(language: String) throws -> AssetManifest {
        let original = try PocketTTSCatalog.manifest(language: language)
        let shared: (AssetManifest.File) -> Bool = { !$0.path.hasSuffix("/model.safetensors") }
        return AssetManifest(repository: original.repository, revision: identity + ":shared",
                             files: original.files.filter(shared), installedFiles: original.installedFiles.filter(shared))
    }

    public static func manifest(language: String? = nil) throws -> AssetManifest {
        let selected = language.map { [$0] } ?? PocketTTSCatalog.languages
        guard selected.allSatisfy(PocketTTSCatalog.languages.contains) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let manifests = try selected.map { code in
            guard let url = Bundle.module.url(forResource: "coreml-" + code, withExtension: "json", subdirectory: "PocketTTS") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let graph = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
            guard graph.revision == identity else { throw CocoaError(.fileReadCorruptFile) }
            let shared = try sharedManifest(language: code)
            return AssetManifest(repository: graph.repository, revision: identity,
                                 files: shared.files + graph.files, installedFiles: shared.installedFiles + graph.installedFiles)
        }
        return AssetManifest(repository: "Section9Labs/LibroxTTS", revision: identity,
                             files: manifests.flatMap(\.files), installedFiles: manifests.flatMap(\.installedFiles))
    }
}
