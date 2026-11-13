import Foundation
import KokoroCatalog

/// Transport metadata only. Installed files and model/render identities stay in
/// the original manifest. Existing manifest-based installers remain supported.
public struct NarrationDownloadPlan: Sendable {
    public struct Artifact: Codable, Sendable {
        public enum Encoding: String, Codable, Sendable { case raw, gzip }
        public let url: URL
        public let size: Int64
        public let sha256: String
        public let decodedSize: Int64
        public let encoding: Encoding
    }
    public struct File: Sendable {
        public let installed: AssetManifest.File
        /// Ordered independent compressed chunks, or one original raw file.
        public let artifacts: [Artifact]
        public var downloadSize: Int64 { artifacts.reduce(0) { $0 + $1.size } }
    }
    public let revision: String
    public let manifest: AssetManifest
    public let files: [File]
    /// Wire bytes for a fresh download. Already verified installed files need no transfer.
    public var downloadSize: Int64 { files.reduce(0) { $0 + $1.downloadSize } }
}

/// Additive compressed transport API for foreground and host-owned background downloads.
/// Serialize all installation/removal for a destination with active rendering.
public enum NarrationDownloads {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let sha256: String
            let size: Int64
            let parts: [NarrationDownloadPlan.Artifact]
        }
        let revision: String
        let files: [Entry]
    }
    /// Uses compressed Max artifacts when the original content hash/size match.
    /// Other assets retain their original transport, including Basic's archive.
    public static func plan(for manifest: AssetManifest) throws -> NarrationDownloadPlan {
        guard let url = Bundle.module.url(forResource: "PocketTransfers-v1", withExtension: "json", subdirectory: "Transport") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        let entries = Dictionary(catalog.files.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        let files = try manifest.files.map { file -> NarrationDownloadPlan.File in
            try DownloadFileInstallation.validatePath(file.path)
            if let entry = entries[file.sha256], entry.size == file.size {
                guard !entry.parts.isEmpty, entry.parts.allSatisfy({
                    $0.size > 0 && $0.decodedSize > 0 && $0.decodedSize <= 64 * 1024 * 1024
                        && $0.url.scheme == "https" && $0.encoding == .gzip
                }), entry.parts.reduce(Int64(0), { $0 + $1.decodedSize }) == file.size else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return .init(installed: file, artifacts: entry.parts)
            }
            return .init(installed: file, artifacts: [.init(url: manifest.url(for: file), size: file.size,
                sha256: file.sha256, decodedSize: file.size, encoding: .raw)])
        }
        return .init(revision: catalog.revision, manifest: manifest, files: files)
    }

    /// Verify transport files, reconstruct exact original bytes and atomically
    /// adopt one file. URLs must follow artifact order. Sources remain caller-owned.
    /// After every file succeeds, call the existing matching NarrationAssets prepare API.
    public static func install(_ file: NarrationDownloadPlan.File, from artifacts: [URL], in directory: URL) throws {
        try DownloadFileInstallation.install(file, from: artifacts, in: directory)
    }

    /// Foreground convenience transport. Completed chunks survive retries in cache;
    /// URLSession resume data is retained when supplied by the OS. This does not
    /// promise process-surviving networking; hosts use their background URLSession.
    /// Progress is verified wire-byte completion (including reused files), not playback
    /// readiness. Call the existing prepare API after this returns. Cache is caller-owned;
    /// serialize uses of the same cache, and remove it after successful preparation.
    public static func download(_ plan: NarrationDownloadPlan, to directory: URL, cache: URL,
                                maximumConcurrentDownloads: Int = 3,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await NarrationTransport().run(plan, to: directory, cache: cache,
            concurrency: maximumConcurrentDownloads, progress: progress)
    }
}
