import CryptoKit
import Foundation

public enum CTError: Error, LocalizedError, Sendable {
    case invalidAssets(String), invalidTensor(String), unsupportedLanguage, unsupportedVoice
    case emptyText, passageTooLong, invalidAudio, notLoaded
    public var errorDescription: String? {
        switch self {
        case .invalidAssets(let file): "Plus voice assets failed verification: \(file)."
        case .invalidTensor(let name): "Plus produced an incompatible tensor: \(name)."
        case .unsupportedLanguage: "This language is not supported by the Plus narrator."
        case .unsupportedVoice: "Choose a supported Plus voice. Voices from other models are not interchangeable."
        case .emptyText: "There is no speakable text in this passage."
        case .passageTooLong: "This passage exceeds the Plus narrator's bounded capacity."
        case .invalidAudio: "Plus produced invalid audio."
        case .notLoaded: "Load the Plus narrator before rendering."
        }
    }
}

public enum CTAssets {
    public static let identity = "librox-plus-dk-coreml-v2"
    public static let releaseTag = "plus-dk-coreml-preview-v2"
    public static let downloadBaseURL = "https://github.com/Section9Labs/LibroxTTS/releases/download/" + releaseTag + "/"
    public static let releasedIdentity = "librox-plus-ct-f1-coremlgpu-v2"
    public static let releasedTag = "plus-coreml-v2-2026-11-06"
    public static let coreMLIdentity = identity
    public static let voiceID = "dk-f1-v1"
    public static let styles = ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"]
    public static let voiceStyles = Dictionary(uniqueKeysWithValues: styles.map { ("dk-" + $0.lowercased() + "-v1", $0) })
    public static let parameterCount = 108_672_825
    public struct Manifest: Decodable, Sendable {
        public struct File: Decodable, Sendable {
            public let path: String
            public let bytes: Int
            public let sha256: String
        }
        public let identity: String
        public let referenceManifestSHA256: String
        public let parameterCount: Int
        public let files: [File]
    }
    public static func manifest(identity selected: String = identity) throws -> Manifest {
        guard [identity, releasedIdentity].contains(selected) else { throw CTError.invalidAssets("unsupported asset identity") }
        let resource = selected == identity ? "CTCoreMLManifest" : "CTReleasedManifest"
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw CTError.invalidAssets("SDK manifest")
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    /// Trust the SDK's pinned hashes, never a manifest supplied beside downloaded models.
    public static func validate(_ directory: URL, identity: String = identity) throws {
        for file in try manifest(identity: identity).files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.path)
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.bytes else {
                throw CTError.invalidAssets(file.path)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw CTError.invalidAssets(file.path)
            }
        }
    }
    /// Installation can pay the compiler cost before Play without retaining
    /// inference models. Later loads reuse this OS/source-specific disk cache.
    public static func prepare(_ directory: URL, specializeFor backend: CTEngine.Backend? = nil, identity: String = identity) throws {
        try validate(directory, identity: identity)
        for name in ["duration_predictor", "text_encoder_early", "text_encoder", "vector_estimator", "vocoder"] {
            try Task.checkCancellation()
            _ = try CTCompiledModelCache.modelURL(for: directory.appendingPathComponent("coreml/\(name).mlpackage"))
        }
        if let backend {
            // Loading pays Core ML's persistent hardware-specialization cost.
            // Retire each function before loading the next; no prediction or
            // audio session is started and no model stays resident afterward.
            for length in [64, 192, 320, 400] {
                try Task.checkCancellation()
                try autoreleasepool {
                    _ = try CTCoreMLGraph(package: directory.appendingPathComponent("coreml/vector_estimator.mlpackage"),
                        backend: backend, functionName: CTGenerator.functionName(for: length))
                }
            }
        }
    }
    /// An atomic, version-specific installation. An existing corrupt install is reported,
    /// never overwritten while another renderer may have it open.
    public static func install(from source: URL, into root: URL) throws -> URL {
        try validate(source)
        let fm = FileManager.default
        let destination = root.appendingPathComponent(identity, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try validate(destination); return destination }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".ct-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in try manifest().files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(file.path), to: target)
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            #endif
        }
        try validate(staging)
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: destination)
        var url = destination
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return destination
    }
}
