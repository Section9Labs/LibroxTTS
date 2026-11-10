import PocketTTSMLX
import PocketTTSCoreML
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
        case .pocket: PocketTTSBackend.platform.repositoryID
        case .compact: "mrbrutti/librox@kokoro-coreml-2026-10-15"
        case .kokoroDesktop: "narration-kokoroDesktop"
        case .plus: CTApprovedExpression.isDownloadPublished ? CTApprovedExpression.installationIdentity : CTAssets.coreMLIdentity
        case .enhanced: "narration-enhanced-ane-v1"
        case .qwenDesktop: "narration-qwenDesktop"
        }
    }
    public static func compatibleRepositoryIDs(_ model: NarrationModel) -> [String] {
        guard model == .plus else { return [repositoryID(model)] }
        var seen = Set<String>()
        return [repositoryID(model), CTApprovedExpression.installationIdentity, CTAssets.identity, CTAssets.releasedIdentity]
            .filter { seen.insert($0).inserted }
    }
    /// Older playback is explicit and restricted to that installation's voices.
    /// A retained CT F1 installation is never relabelled as the ten-style DK bank.
    public static func supportedNativeStyles(repositoryID: String) -> [String] {
        if [PocketTTSCatalog.identity, PocketTTSCoreMLCatalog.identity].contains(repositoryID) { return PocketTTSCatalog.voiceNames }
        return [CTAssets.identity, CTApprovedExpression.installationIdentity].contains(repositoryID)
            ? CTAssets.styles : repositoryID == CTAssets.releasedIdentity ? ["F1"] : []
    }
    /// Manifest-derived estimate only; corrupt/missing installed files download
    /// again. Reuse always verifies actual bytes before accepting them.
    public static func estimatedDownloadSize(_ model: NarrationModel, reusing repositoryID: String?,
                                             targetRepositoryID: String? = nil) throws -> Int64 {
        let current = try manifest(model, repositoryID: targetRepositoryID)
        guard let repositoryID else { return current.downloadSize }
        let reusable = model == .pocket && repositoryID == PocketTTSCatalog.identity
            ? try? PocketTTSCatalog.manifest() : try? manifest(model, repositoryID: repositoryID)
        guard let previous = reusable else { return current.downloadSize }
        let old = Set(previous.installedFiles.map { contentKey($0) })
        return current.files.reduce(0) { total, file in
            total + (old.contains(contentKey(file)) ? 0 : file.size)
        }
    }
    public static func manifest(_ model: NarrationModel, repositoryID selected: String? = nil, language: String? = nil) throws -> AssetManifest {
        guard selected == nil || compatibleRepositoryIDs(model).contains(selected!) else {
            throw CTError.invalidAssets("unsupported installation")
        }
        switch model {
        case .pocket: return try PocketTTSBackend.platform.manifest(language: language)
        case .compact: return try .bundled()
        case .kokoroDesktop:
            guard let url = Bundle.module.url(forResource: "NarrationBasic", withExtension: "json") else { throw CTError.invalidAssets("Basic manifest") }
            return try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
        case .plus:
            let identity = selected ?? repositoryID(model)
            let pinned = try CTAssets.manifest(identity: identity)
            let tag = identity == CTApprovedExpression.installationIdentity ? CTApprovedExpression.releaseTag
                : identity == CTAssets.identity ? CTAssets.releaseTag : CTAssets.releasedTag
            let prior = try CTAssets.manifest().files
            let files = pinned.files.map { file -> [String: Any] in
                // Identical weights can use immutable existing release assets.
                // New graph structure/metadata belongs to the new release only.
                let reusable = identity == CTApprovedExpression.installationIdentity
                    ? prior.first { $0.bytes == file.bytes && $0.sha256 == file.sha256 } : nil
                let sourceTag = reusable == nil ? tag : CTAssets.releaseTag
                let path = reusable?.path ?? file.path
                let url = "https://github.com/Section9Labs/LibroxTTS/releases/download/" + sourceTag + "/"
                    + path.replacingOccurrences(of: "/", with: "--")
                return ["path": file.path, "size": file.bytes, "sha256": file.sha256, "sourceURL": url]
            }
            let json: [String: Any] = ["repository": "Section9Labs/LibroxTTS", "revision": tag,
                                      "files": files, "installedFiles": files]
            return try JSONDecoder().decode(AssetManifest.self, from: JSONSerialization.data(withJSONObject: json))
        default: throw CTError.invalidAssets("Legacy model unavailable")
        }
    }
    public static func bundledResourceName(_ model: NarrationModel) -> String? {
        switch model {
        case .kokoroDesktop: "BundledNarrationHD"
        case .plus: CTApprovedExpression.isDownloadPublished ? "CTApprovedExpressionAssets" : "CTCoreMLV2GPUAssets"
        default: nil
        }
    }
    public static func isDownloadPublished(_ model: NarrationModel, repositoryID: String? = nil) -> Bool {
        let selected = repositoryID ?? Self.repositoryID(model)
        if model == .pocket && !PocketTTSBackend.platform.isDownloadPublished { return false }
        guard model.isEnabled, compatibleRepositoryIDs(model).contains(selected) else { return false }
        if selected == CTApprovedExpression.installationIdentity {
            return CTApprovedExpression.isDownloadPublished
        }
        return true
    }
    /// Preparation follows actual model/runtime identities, not the host's SDK
    /// version string. Hosts may persist this after successful preparation.
    public static func preparationIdentity(_ model: NarrationModel, repositoryID: String? = nil) -> String {
        let selected = repositoryID ?? Self.repositoryID(model)
        let expression = selected == CTApprovedExpression.installationIdentity ? ":" + CTApprovedExpression.identity : ""
        return model == .pocket ? selected + ":" + PocketTTSBackend.platform.runtimeIdentity : model == .plus ? selected + ":" + CTEngine.runtimeIdentity + ":gpu-specializations-1" + expression
            : selected + ":prepared-1"
    }
    /// Known older installations are read-only reuse candidates, not evidence
    /// that an old model can render every voice in the current catalog.
    public static func previousRepositoryIDs(_ model: NarrationModel) -> [String] {
        model == .pocket && PocketTTSBackend.platform == .coreML ? [PocketTTSCatalog.identity]
            : model == .plus ? [CTAssets.identity, "librox-plus-dk-coreml-v1", CTAssets.releasedIdentity] : []
    }

    /// Seed a private staging directory using current manifest hashes. Never
    /// move/delete a working installation or trust its old receipt as validation.
    @discardableResult
    public static func reuseVerifiedFiles(manifest: AssetManifest, from directories: [URL],
                                         into staging: URL) throws -> Set<String> {
        let fm = FileManager.default
        // A caller must provide a different staging root from all source roots.
        let targetRoot = staging.standardizedFileURL.resolvingSymlinksInPath()
        guard !directories.contains(where: {
            let source = $0.standardizedFileURL.resolvingSymlinksInPath().path
            return source == targetRoot.path || source.hasPrefix(targetRoot.path + "/") || targetRoot.path.hasPrefix(source + "/")
        }) else {
            throw CTError.invalidAssets("staging overlaps installed model")
        }
        // New graphs can share identical weights with an installed graph under
        // another path. Only manifest-pinned content hashes establish reuse;
        // matching graph/tensor names never do. Validate aliases before reading.
        for file in manifest.files {
            guard !file.path.isEmpty, !file.path.hasPrefix("/"),
                  !file.path.split(separator: "/").contains("..") else { throw CTError.invalidAssets(file.path) }
        }
        let aliases = Dictionary(grouping: manifest.files, by: contentKey)
        var reused: Set<String> = []
        for file in manifest.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            guard target.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(targetRoot.path + "/") else {
                throw CTError.invalidAssets(file.path)
            }
            if try matches(target, size: file.size, sha256: file.sha256) { reused.insert(file.path); continue }
            let paths = [file.path] + (aliases[contentKey(file)] ?? []).map(\.path).filter { $0 != file.path }
            search: for directory in directories {
                for path in paths {
                    let source = directory.appendingPathComponent(path)
                    guard try matches(source, size: file.size, sha256: file.sha256) else { continue }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: source, to: target)
                    reused.insert(file.path)
                    break search
                }
            }
        }
        return reused
    }
    private static func contentKey(_ file: AssetManifest.File) -> String {
        file.sha256 + ":" + String(file.size)
    }

    /// Foreground installer. Hosts needing process-surviving transfers can use
    /// manifest(_:), their background URLSession, and prepare(_:model:).
    /// Serialize installation for a destination and keep it separate from any
    /// active renderer until this function succeeds.
    public static func download(_ model: NarrationModel, to directory: URL, language: String? = nil,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard isDownloadPublished(model) else { throw CTError.invalidAssets("unavailable model") }
        if model == .compact { try await ModelAssets.download(to: directory, progress: progress); return }
        let pinned = try manifest(model, language: language)
        try await downloadFiles(pinned, to: directory, progress: progress)
        try prepare(directory, model: model, language: language)
        try configureForPlayback(directory)
    }

    /// Complete new-book narrator download, including the base language pack and
    /// the default Calm state with its credits. Existing base-only receipts stay valid.
    public static func manifestPocketNarratorPreset(language: String) throws -> AssetManifest {
        let preset = try PocketTTSNarratorPreset.defaultNarrator(language: language)
        return try PocketTTSDeliveryCatalog.narratorManifest(voiceID: preset.voiceID,
                                                             style: preset.delivery.narratorStyle)
    }

    public static func downloadPocketNarratorPreset(to directory: URL, language: String,
                                                    progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard isDownloadPublished(.pocket) else { throw CTError.invalidAssets("unavailable model") }
        try await downloadFiles(manifestPocketNarratorPreset(language: language), to: directory, progress: progress)
        try preparePocketNarratorPreset(in: directory, language: language)
    }

    /// Pair with manifestPocketNarratorPreset for background URLSession transfers.
    public static func preparePocketNarratorPreset(in directory: URL, language: String) throws {
        let preset = try PocketTTSNarratorPreset.defaultNarrator(language: language)
        try preparePocketDeliveryStyle(preset.delivery.narratorStyle, voiceID: preset.voiceID, in: directory)
    }

    /// Install the optional reference performances beside the base language pack.
    /// The caller must serialize installation with generation for this directory.
    public static func downloadPocketDeliveryStyles(to directory: URL, language: String,
                                                    progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let pinned = try PocketTTSDeliveryCatalog.manifest(language: language)
        try await downloadFiles(pinned, to: directory, progress: progress)
        try preparePocketDeliveryStyles(in: directory, language: language)
    }

    public static func downloadPocketDeliveryStyle(_ style: PocketTTSDeliveryStyle, voiceID: String,
                                                   to directory: URL,
                                                   progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let pinned = try PocketTTSDeliveryCatalog.manifest(voiceID: voiceID, style: style)
        try await downloadFiles(pinned, to: directory, progress: progress)
        try preparePocketDeliveryStyle(style, voiceID: voiceID, in: directory)
    }

    public static func preparePocketDeliveryStyle(_ style: PocketTTSDeliveryStyle, voiceID: String,
                                                  in directory: URL) throws {
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else {
            throw PocketTTSDeliveryCatalog.DeliveryError.unsupportedVoice
        }
        try prepare(directory, model: .pocket, language: voice.language)
        try validate(directory, manifest: PocketTTSDeliveryCatalog.manifest(voiceID: voiceID, style: style))
        try configureForPlayback(directory)
    }

    /// Background URLSession hosts use PocketTTSDeliveryCatalog.manifest and then
    /// call this after installation. This also applies background-readable protection.
    public static func preparePocketDeliveryStyles(in directory: URL, language: String) throws {
        try prepare(directory, model: .pocket, language: language)
        try PocketTTSDeliveryCatalog.validate(in: directory, language: language)
        try configureForPlayback(directory)
    }

    private static func downloadFiles(_ pinned: AssetManifest, to directory: URL,
                                      progress: (@Sendable (Double) -> Void)?) async throws {
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
    }
    /// Fast receipt/UI check. Loading separately verifies every pinned hash.
    public static func isPrepared(_ directory: URL, model: NarrationModel, repositoryID: String? = nil, language: String? = nil) -> Bool {
        guard let manifest = try? manifest(model, repositoryID: repositoryID, language: language), manifest.isPresent(in: directory) else { return false }
        if model == .pocket, PocketTTSBackend.platform == .coreML {
            return (language.map { [$0] } ?? PocketTTSCatalog.languages).allSatisfy {
                PocketTTSCoreMLAssets.isPrepared(in: directory, language: $0)
            }
        }
        return model != .kokoroDesktop || FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("frontend-fp32.mlmodelc").path)
    }
    public static func prepare(_ directory: URL, model: NarrationModel, repositoryID: String? = nil, language: String? = nil) throws {
        if model == .pocket, PocketTTSBackend.platform == .coreML {
            // Reject an old MLX receipt before compiling or accepting assets.
            _ = try manifest(model, repositoryID: repositoryID, language: language)
            for code in language.map({ [$0] }) ?? PocketTTSCatalog.languages {
                try PocketTTSCoreMLAssets.prepare(in: directory, language: code)
            }
            try configureForPlayback(directory)
            return
        }
        if model == .plus {
            // Pay the common generator functions' hardware specialization cost
            // while the install UI is preparing the voice, before the first Play.
            // Each model is released before the next; weights and audio stay unchanged.
            try CTAssets.prepare(directory, specializeFor: .coreMLGPUHeavy, identity: repositoryID ?? Self.repositoryID(model))
            try configureForPlayback(directory)
            return
        }
        if model == .compact { try ModelAssets.prepare(in: directory); return }
        try validate(directory, manifest: manifest(model, repositoryID: repositoryID, language: language))
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
