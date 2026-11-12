import CryptoKit
import Foundation
import KokoroCatalog

/// Shared byte verification; callers retain their existing size/error policies.
enum VerifiedAssetFile {
    static func matchesDigest(_ url: URL, sha256: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            digest.update(data: data)
            return true
        }) {}
        return digest.finalize().map { String(format:"%02x",$0) }.joined() == sha256
    }
}

/// Replacement is staged beside the destination. A failed copy/verification
/// never removes the installed file. The host still serializes installation.
struct VerifiedFilePublication: Sendable {
    struct Operations: Sendable {
        var copy: @Sendable (URL,URL) throws -> Void = { try FileManager.default.copyItem(at:$0,to:$1) }
        var adopt: @Sendable (URL,URL) throws -> Void = { stage, target in
            if FileManager.default.fileExists(atPath:target.path) {
                _ = try FileManager.default.replaceItemAt(target,withItemAt:stage,options:.usingNewMetadataOnly)
            } else { try FileManager.default.moveItem(at:stage,to:target) }
        }
        var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at:$0) }
    }
    var operations = Operations()
    func publish(_ source: URL, to target: URL, verify: (URL) throws -> Void) throws {
        try Task.checkCancellation()
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let stage = parent.appendingPathComponent(".download-"+UUID().uuidString)
        defer { try? operations.remove(stage) }
        try operations.copy(source,stage)
        try verify(stage)
        try Task.checkCancellation()
        try operations.adopt(stage,target)
    }
}

struct VerifiedAssetTransfer: Sendable {
    var download: @Sendable (URL) async throws -> (URL,URLResponse) = { try await URLSession.shared.download(from:$0) }
    var publication = VerifiedFilePublication()
    func run(_ manifest: AssetManifest, to root: URL,
             matches: @Sendable (URL,AssetManifest.File) throws -> Bool,
             invalid: @Sendable (AssetManifest.File) -> any Error,
             progress: (@Sendable (Double) -> Void)?) async throws {
        var completed: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            guard !file.path.hasPrefix("/"), !file.path.split(separator:"/").contains("..") else { throw invalid(file) }
            let target = root.appendingPathComponent(file.path)
            if (try? matches(target,file)) != true {
                try Task.checkCancellation()
                let (temporary,response) = try await download(manifest.url(for:file))
                defer { try? FileManager.default.removeItem(at:temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                guard try matches(temporary,file) else { throw invalid(file) }
                try publication.publish(temporary,to:target) { staged in
                    guard try matches(staged,file) else { throw invalid(file) }
                }
            }
            completed += file.size
            progress?(Double(completed)/Double(manifest.downloadSize))
        }
    }
}
