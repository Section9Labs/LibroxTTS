import CoreML
import CryptoKit
import KokoroCatalog
import Foundation

/// Native reader for the pinned Float32 voice-cache representation. Unsupported
/// representations retain the MLX reader, including its conversion/error behavior.
/// The catalog still verifies the complete source before this preparation step.
enum PocketVoiceArchive {
    // Only admit published bytes. A public engine can observe an original voice
    // file replaced after loading; unknown/modified archives must still use the
    // legacy reader, including validation of otherwise unused tensor records.
    private static let pinnedHashes: [String: String] = {
        var result: [String: String] = [:]
        for language in PocketTTSCatalog.languages {
            let manifests = [try? PocketTTSCatalog.manifest(language: language),
                             try? PocketTTSDeliveryCatalog.manifest(language: language)]
            for manifest in manifests.compactMap({ $0 }) {
                for file in manifest.installedFiles where file.path.contains("/embeddings/") {
                    result[file.path] = file.sha256
                }
            }
        }
        return result
    }()
    private struct Tensor: Decodable { let dtype: String; let shape: [Int]; let data_offsets: [Int] }
    static func read(_ url: URL) throws -> [MLMultiArray]? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let language = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let key = language + "/embeddings/" + url.lastPathComponent
        guard let expected = pinnedHashes[key],
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected,
              data.count >= 8 else { return nil }
        let header = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard header <= UInt64(data.count - 8), header <= 1_048_576 else { return nil }
        let start = 8 + Int(header)
        guard let tensors = try? JSONDecoder().decode([String: Tensor].self, from: data.subdata(in: 8..<start)) else { return nil }
        func valid(_ tensor: Tensor, bytes: Int) -> Bool {
            tensor.data_offsets.count == 2 && tensor.data_offsets[0] >= 0
                && tensor.data_offsets[1] >= tensor.data_offsets[0]
                && tensor.data_offsets[1] <= data.count - start
                && tensor.data_offsets[1] - tensor.data_offsets[0] == bytes
        }
        var result: [MLMultiArray] = []
        for i in 0..<6 {
            let prefix = "transformer.layers.\(i).self_attn/"
            guard let cache = tensors[prefix + "cache"], let offset = tensors[prefix + "offset"],
                  offset.dtype == "I64", offset.shape == [1], valid(offset, bytes: 8),
                  cache.dtype == "F32", cache.shape.count == 5, cache.shape[0] == 2,
                  cache.shape[1] == 1, cache.shape[3] == 16, cache.shape[4] == 64,
                  cache.shape[2] > 0, cache.shape[2] <= 4096,
                  valid(cache, bytes: 2 * cache.shape[2] * 16 * 64 * 4) else { return nil }
            let count = data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: start + offset.data_offsets[0], as: Int64.self)) }
            guard count > 0, count <= cache.shape[2], count <= 512 else { return nil }
            let n = Int(count)
            for pair in 0..<2 {
                let array = try MLMultiArray(shape: [1,16,NSNumber(value: n),64], dataType: .float32)
                // Copy Float32 bit patterns, including signed zero; no arithmetic.
                data.withUnsafeBytes { bytes in
                    let output = array.dataPointer.assumingMemoryBound(to: UInt8.self)
                    for head in 0..<16 { for frame in 0..<n {
                        let source = start + cache.data_offsets[0] + ((pair * cache.shape[2] + frame) * 16 + head) * 64 * 4
                        output.advanced(by: (head * n + frame) * 64 * 4)
                            .update(from: bytes.baseAddress!.advanced(by: source).assumingMemoryBound(to: UInt8.self), count: 64 * 4)
                    } }
                }
                result.append(array)
            }
        }
        return result
    }
}
