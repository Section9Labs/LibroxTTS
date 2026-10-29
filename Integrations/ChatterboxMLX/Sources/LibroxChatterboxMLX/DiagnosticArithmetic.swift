#if os(macOS)
import MLX
import MLXNN

/// Source-backed CPU-fallback operation sequences, GPU-executed only in the
/// offline counterfactual. Not exposed as a renderer or accepted precision mode.
struct DiagnosticArithmetic: OptionSet {
    let rawValue: Int
    static let explicitNorm = Self(rawValue: 1)
    static let materializedAttention = Self(rawValue: 2)
    static let uncompiledSiLU = Self(rawValue: 4)

    static func norm(_ x: MLXArray, _ layer: RMSNorm) -> MLXArray {
        precondition(x.dtype == .float32 && layer.weight.dtype == .float32)
        let f = x.asType(.float32)
        return ((f * rsqrt(mean(square(f), axis: -1, keepDims: true) + layer.eps)).asType(x.dtype)) * layer.weight
    }

    static func attention(queries: MLXArray, keys: MLXArray, values: MLXArray, scale: Float) -> MLXArray {
        precondition(queries.dtype == .float32 && keys.dtype == .float32 && values.dtype == .float32)
        precondition(queries.dim(1) == keys.dim(1)) // T3 has no grouped-query repeats.
        var scores = matmul(queries * scale, keys.swappedAxes(-1, -2))
        let qLength = queries.dim(-2), kLength = keys.dim(-2)
        if qLength > 1 {
            let q = MLXArray((kLength - qLength)..<kLength).expandedDimensions(axis: -1)
            let k = MLXArray(0..<kLength).expandedDimensions(axis: 0)
            scores = MLX.where(q .>= k, scores, MLXArray(-Float.greatestFiniteMagnitude))
        }
        return matmul(softmax(scores, axis: -1, precise: true), values)
    }
}
#endif
