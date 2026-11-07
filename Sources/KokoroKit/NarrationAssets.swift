import CoreML
import CryptoKit
import Foundation
import LibroxCTNative
import KokoroNarration

/// Model-specific asset selection and preparation belong to the SDK. Hosts may
/// persist generic download receipts and supply their application storage root.
public enum NarrationAssets {
    public static func repositoryID(_ model: NarrationModel) -> String {
        switch model {
        case .compact: "mrbrutti/librox@kokoro-coreml-2026-10-15"
        case .kokoroDesktop: "narration-kokoroDesktop"
        case .plus: CTAssets.coreMLIdentity
        case .enhanced: "narration-enhanced-ane-v1"
        case .qwenDesktop: "narration-qwenDesktop"
        }
    }
    public static func manifest(_ model: NarrationModel) throws -> AssetManifest {
        switch model {
        case .compact: return try .bundled()
        case .kokoroDesktop:
            guard let url = Bundle.module.url(forResource: "NarrationBasic", withExtension: "json") else { throw CTError.invalidAssets("Basic manifest") }
            return try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
        case .plus:
            let pinned = try CTAssets.manifest()
            let files = pinned.files.map {
                ["path": $0.path, "size": $0.bytes, "sha256": $0.sha256,
                 "sourceURL": CTAssets.downloadBaseURL + $0.path.replacingOccurrences(of: "/", with: "--")] as [String: Any]
            }
            let json: [String: Any] = ["repository": "Section9Labs/LibroxTTS", "revision": CTAssets.releaseTag,
                                      "files": files, "installedFiles": files]
            return try JSONDecoder().decode(AssetManifest.self, from: JSONSerialization.data(withJSONObject: json))
        default: throw CTError.invalidAssets("Legacy model unavailable")
        }
    }
    public static func bundledResourceName(_ model: NarrationModel) -> String? {
        switch model { case .kokoroDesktop: "BundledNarrationHD"; case .plus: "CTCoreMLV2GPUAssets"; default: nil }
    }
    public static func isDownloadPublished(_ model: NarrationModel) -> Bool { model.isEnabled && model != .plus }
    /// Foreground installer. Hosts needing process-surviving transfers can use
    /// manifest(_:), their background URLSession, and prepare(_:model:).
    /// Serialize installation for a destination and keep it separate from any
    /// active renderer until this function succeeds.
    public static func download(_ model: NarrationModel, to directory: URL,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard isDownloadPublished(model) else { throw CTError.invalidAssets("unavailable model") }
        if model == .compact { try await ModelAssets.download(to: directory, progress: progress); return }
        let pinned = try manifest(model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var downloaded: Int64 = 0
        for file in pinned.files {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                throw CTError.invalidAssets(file.path)
            }
            let destination = directory.appendingPathComponent(file.path)
            if (try? matches(destination, size: file.size, sha256: file.sha256)) != true {
                let (temporary, response) = try await URLSession.shared.download(from: pinned.url(for: file))
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                guard try matches(temporary, size: file.size, sha256: file.sha256) else {
                    throw CTError.invalidAssets(file.path)
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            downloaded += file.size
            progress?(Double(downloaded) / Double(pinned.downloadSize))
        }
        try prepare(directory, model: model)
        try configureForPlayback(directory)
    }
    /// Fast receipt/UI check. Loading separately verifies every pinned hash.
    public static func isPrepared(_ directory: URL, model: NarrationModel) -> Bool {
        guard let manifest = try? manifest(model), manifest.isPresent(in: directory) else { return false }
        return model != .kokoroDesktop || FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("frontend-fp32.mlmodelc").path)
    }
    public static func prepare(_ directory: URL, model: NarrationModel) throws {
        if model == .plus {
            // Pay the common generator functions' hardware specialization cost
            // while the install UI is preparing the voice, before the first Play.
            // Each model is released before the next; weights and audio stay unchanged.
            try CTAssets.prepare(directory, specializeFor: .coreMLGPUHeavy)
            try configureForPlayback(directory)
            return
        }
        if model == .compact { try ModelAssets.prepare(in: directory); return }
        try validate(directory, manifest: manifest(model))
        if model == .kokoroDesktop {
            let compiled = try MLModel.compileModel(at: directory.appendingPathComponent("frontend-fp32.mlpackage"))
            defer { try? FileManager.default.removeItem(at: compiled) }
            let target = directory.appendingPathComponent("frontend-fp32.mlmodelc")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: compiled, to: target)
        }
    }
    public static func validate(_ directory: URL, manifest: AssetManifest) throws {
        guard !manifest.installedFiles.isEmpty else { throw CTError.invalidAssets("empty manifest") }
        for file in manifest.installedFiles {
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."),
                  try matches(directory.appendingPathComponent(file.path), size: file.size, sha256: file.sha256) else {
                throw CTError.invalidAssets(file.path)
            }
        }
    }
    public static func matches(_ url: URL, size: Int64, sha256: String) throws -> Bool {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == Int(size) else { return false }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
    private static func configureForPlayback(_ directory: URL) throws {
        #if os(iOS)
        let fm = FileManager.default
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        if let entries = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in entries {
                try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
        }
        #endif
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
