import CryptoKit
import Foundation
import Synchronization

/// Private-engine leases for immutable configuration and tokenizer data. The
/// tokenizer builds its trie once and all encode/decode scratch is local. This
/// owner never exposes a mutable Module, MLXArray, RNG, or public model instance.
package final class PocketPreparedTextAssets: @unchecked Sendable {
    package let config: PocketTTSModelConfig
    package let tokenizer: PocketTTSSentencePieceTokenizer
    private struct Weak: Sendable { weak var value: PocketPreparedTextAssets? }
    private static let owners = Mutex<[String: Weak]>([:])
    private init(config: PocketTTSModelConfig, data: Data, json: Bool) throws {
        self.config = config
        tokenizer = try PocketTTSSentencePieceTokenizer(data: data, isJSON: json, nBins: config.flowLM.lookupTable.nBins)
    }
    package static func load(_ root: URL) throws -> PocketPreparedTextAssets {
        // Read exact source bytes on every acquisition; path/mtime is not an
        // identity and an existing owner must not hide changed or missing files.
        let configuration = try Data(contentsOf: root.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(PocketTTSModelConfig.self, from: configuration)
        let candidates = ([config.tokenizerName].compactMap { $0 } + ["tokenizer.model", "tokenizer.json"])
            .filter { !$0.contains("://") }.map { root.appendingPathComponent($0) }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(domain: "PocketTTSConditioners", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing tokenizer.model or tokenizer.json in \(root.path)"])
        }
        let data = try Data(contentsOf: file), json = file.pathExtension == "json"
        let key = SHA256.hash(data: configuration).description + ":" + SHA256.hash(data: data).description + ":\(json)"
        return try owners.withLock { slots in
            if let owner = slots[key]?.value { return owner }
            let owner = try PocketPreparedTextAssets(config: config, data: data, json: json)
            slots = slots.filter { $0.value.value != nil }
            // Limit the registry itself; live leases continue to own their data.
            if slots.count < 64 { slots[key] = Weak(value: owner) }
            return owner
        }
    }
}
