import MLX
import MLXFast
import MLXNN

/// Separately versioned experimental arithmetic; default and Q8-v1 stay unchanged.
/// Packed weights remain resident; two-row decode rounds every reconstructed
/// weight to FP16, multiplies/accumulates in FP32, then rounds output to FP16.
final class CanonicalQ8Linear: QuantizedLinear {
    private let useNativePrefill: Bool

    init(weight: MLXArray, scales: MLXArray, biases: MLXArray, useNativePrefill: Bool = false) {
        self.useNativePrefill = useNativePrefill
        super.init(weight: weight, scales: scales, biases: biases, groupSize: 64, bits: 8)
    }
    private static let reconstruction = """
        inline half canonical_q8_weight(uint q, half scale, half bias) {
            return half(float(q) * float(scale) + float(bias));
        }
        """
    private let decodeKernel = MLXFast.metalKernel(
        name: "librox_q8_canonical_half_decode_v1",
        inputNames: ["x", "w", "s", "b"], outputNames: ["out"],
        source: """
            uint row = threadgroup_position_in_grid.x;
            uint lane = thread_index_in_simdgroup;
            float a0 = 0.0f;
            float a1 = 0.0f;
            for (uint k = lane * 4; k < K; k += 128) {
                uint packed = w[row * (K / 4) + k / 4];
                half scale = s[row * (K / 64) + k / 64];
                half bias = b[row * (K / 64) + k / 64];
                for (uint j = 0; j < 4; ++j) {
                    float weight = float(canonical_q8_weight((packed >> (8 * j)) & 255u, scale, bias));
                    a0 = fma(float(x[k + j]), weight, a0);
                    a1 = fma(float(x[K + k + j]), weight, a1);
                }
            }
            a0 = simd_sum(a0);
            a1 = simd_sum(a1);
            if (lane == 0) {
                out[row] = half(a0);
                out[N + row] = half(a1);
            }
            """, header: CanonicalQ8Linear.reconstruction)
    private let reconstructionKernel = MLXFast.metalKernel(
        name: "librox_q8_canonical_half_reconstruction_v1",
        inputNames: ["w", "s", "b"], outputNames: ["out"],
        source: """
            uint i = thread_position_in_grid.x;
            if (i >= N * K) return;
            uint row = i / K;
            uint k = i % K;
            uint packed = w[row * (K / 4) + k / 4];
            out[i] = canonical_q8_weight((packed >> (8 * (k % 4))) & 255u,
                s[row * (K / 64) + k / 64], b[row * (K / 64) + k / 64]);
            """, header: CanonicalQ8Linear.reconstruction)

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        precondition(bits == 8 && groupSize == 64 && x.dtype == .float16 && bias == nil)
        let (n, k) = shape
        precondition(x.shape.last == k && k % 128 == 0 && scales.dtype == .float16 && biases?.dtype == .float16)
        if x.size / k == 2 {
            var outputShape = x.shape; outputShape[outputShape.count - 1] = n
            return decodeKernel([x, weight, scales, biases!],
                template: [("K", k), ("N", n)], grid: (n * 32, 1, 1), threadGroup: (32, 1, 1),
                outputShapes: [outputShape], outputDTypes: [.float16])[0]
        }
        if useNativePrefill { return super.callAsFunction(x) }
        // Prefill control uses the same canonical weights and FP32 accumulation.
        // Its transient dense allocation is measured, never a memory-win claim.
        let rounded = reconstructedWeights()
        return matmul(x.asType(.float32), rounded.asType(.float32).T).asType(.float16)
    }

    func reconstructedWeights() -> MLXArray {
        let (n, k) = shape
        return reconstructionKernel([weight, scales, biases!], template: [("K", k), ("N", n)],
            grid: (n * k, 1, 1), threadGroup: (256, 1, 1),
            outputShapes: [[n, k]], outputDTypes: [.float16])[0]
    }
}
