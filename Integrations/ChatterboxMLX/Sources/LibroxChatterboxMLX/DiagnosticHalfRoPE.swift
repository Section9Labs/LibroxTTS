#if os(macOS)
import MLX

/// Mac-only counterfactual, never selected by a production decoder. Uses the
/// CPU fallback's trig and distinct half-rounded multiplication/addition steps.
/// All positions are represented; there is no fixture-specific token adjustment.
final class DiagnosticHalfRoPE {
    private let cosines: MLXArray
    private let sines: MLXArray
    private let capacity: Int

    init(cosines: MLXArray, sines: MLXArray) {
        precondition(cosines.shape == [1536, 32] && sines.shape == cosines.shape)
        precondition(cosines.dtype == .float16 && sines.dtype == .float16)
        capacity = 1536
        self.cosines = cosines
        self.sines = sines
    }

    static func makeCPUTables(frequencies: [Float], capacity: Int) -> ([Float16], [Float16]) {
        precondition(frequencies.count == 32 && frequencies.allSatisfy { $0.isFinite && $0 > 0 })
        return Device.withDefaultDevice(.cpu) {
            let frequencies = MLXArray(frequencies)
            let positions = MLXArray(0..<capacity).asType(.float32).expandedDimensions(axis: -1)
            let theta = positions * reciprocal(frequencies)
            let c = cos(theta).asType(.float16), s = sin(theta).asType(.float16)
            eval(c, s)
            return (c.asArray(Float16.self), s.asArray(Float16.self))
        }
    }

    func callAsFunction(_ x: MLXArray, offset: Int) -> MLXArray {
        precondition(x.ndim == 4 && x.dim(-1) == 64 && x.dtype == .float16)
        let length = x.dim(-2)
        precondition(offset >= 0 && offset + length <= capacity)
        let c = cosines[offset..<(offset + length)].reshaped(1, 1, length, 32)
        let s = sines[offset..<(offset + length)].reshaped(1, 1, length, 32)
        let a = x[.ellipsis, 0..<32], b = x[.ellipsis, 32..<64]
        // Separate array operations intentionally retain half rounding boundaries.
        return concatenated([a * c - b * s, a * s + b * c], axis: -1)
    }
}
#endif
