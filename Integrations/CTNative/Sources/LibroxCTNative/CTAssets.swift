import CryptoKit
import Foundation

public enum CTError: Error, LocalizedError, Sendable {
    case invalidAssets(String), invalidTensor(String), unsupportedLanguage, unsupportedVoice
    case emptyText, passageTooLong, invalidAudio, notLoaded
    public var errorDescription: String? {
        switch self {
        case .invalidAssets(let file): "Plus voice assets failed verification: \(file)."
        case .invalidTensor(let name): "Plus produced an incompatible tensor: \(name)."
        case .unsupportedLanguage: "Plus currently supports English and Spanish."
        case .unsupportedVoice: "Choose the Plus F1 narrator. Existing voice selections are not interchangeable."
        case .emptyText: "There is no speakable text in this passage."
        case .passageTooLong: "This passage exceeds the Plus narrator's bounded capacity."
        case .invalidAudio: "Plus produced invalid audio."
        case .notLoaded: "Load the Plus narrator before rendering."
        }
    }
}

public enum CTAssets {
    public static let identity = "librox-plus-ct-f1-coremlgpu-v2"
    public static let releaseTag = "plus-coreml-v2-2026-11-06"
    public static let downloadBaseURL = "https://github.com/Section9Labs/LibroxTTS/releases/download/" + releaseTag + "/"
    public static let coreMLIdentity = identity
    public static let voiceID = "ct-f1-v1"
    public static let parameterCount = 108_425_399
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
    public static func manifest() throws -> Manifest {
        guard let url = Bundle.module.url(forResource: "CTCoreMLManifest", withExtension: "json") else {
            throw CTError.invalidAssets("SDK manifest")
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    /// Trust the SDK's pinned hashes, never a manifest supplied beside downloaded models.
    public static func validate(_ directory: URL) throws {
        for file in try manifest().files {
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
    public static func prepare(_ directory: URL) throws {
        try validate(directory)
        for name in ["duration_predictor", "text_encoder_early", "text_encoder", "vector_estimator", "vocoder"] {
            try Task.checkCancellation()
            _ = try CTCompiledModelCache.modelURL(for: directory.appendingPathComponent("coreml/\(name).mlpackage"))
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
