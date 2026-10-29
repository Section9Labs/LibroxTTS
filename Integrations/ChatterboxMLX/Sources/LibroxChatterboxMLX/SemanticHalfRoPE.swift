import Foundation
import CryptoKit
import MLX

/// Portable, independently certified constants for the additive semantic-Q8
/// profile. No device libm, runtime frequency powers or fixture-specific edits.
final class SemanticHalfRoPE {
    static let sha256 = "1d58a8abbe8e7f9c668cbc3d3b53bee8563e43f7cdb4cb8b758100f7ec664ca9"
    private let cosines: MLXArray, sines: MLXArray
    static func bundledURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "semantic-rope-v01", withExtension: "bin", subdirectory: "Resources")
        else { throw ChatterboxMLXRenderer.RendererError.identityMismatch }
        return url
    }
    static func bundledBytes() throws -> Data {
        let handle = try FileHandle(forReadingFrom: bundledURL()); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 196737), data.count == 196736,
            try handle.read(upToCount: 1)?.isEmpty != false else { throw ChatterboxMLXRenderer.RendererError.identityMismatch }
        return data
    }
    init(data: Data) throws {
        guard data.count == 196736,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.sha256
        else { throw ChatterboxMLXRenderer.RendererError.identityMismatch }
        func table(_ start: Int) -> [Float16] {
            data.withUnsafeBytes { raw in (0..<49152).map {
                Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: start + $0 * 2, as: UInt16.self)))
            } }
        }
        let c = table(128), s = table(128 + 49152 * 2)
        guard c.allSatisfy(\.isFinite), s.allSatisfy(\.isFinite) else { throw ChatterboxMLXRenderer.RendererError.identityMismatch }
        cosines = MLXArray(c, [1536, 32]); sines = MLXArray(s, [1536, 32])
    }
    func callAsFunction(_ x: MLXArray, offset: Int) -> MLXArray {
        precondition(x.ndim == 4 && x.dim(-1) == 64 && x.dtype == .float16)
        let length = x.dim(-2)
        precondition(offset >= 0 && length > 0 && offset + length <= 1536)
        let c = cosines[offset..<(offset + length)].reshaped(1, 1, length, 32)
        let s = sines[offset..<(offset + length)].reshaped(1, 1, length, 32)
        let a = x[.ellipsis, 0..<32], b = x[.ellipsis, 32..<64]
        // Each array operation has an F16 output boundary, as qualified by the
        // independent evaluator. Do not replace this with fused fast RoPE.
        return concatenated([a * c - b * s, a * s + b * c], axis: -1)
    }
}
