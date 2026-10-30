import MLX
import MLXFast

/// Single-owner, bounded experimental KV storage. Grows in 256-position blocks;
/// only the active prefix is presented to attention. No cross-unit state reuse.
final class KVCache {
    var offset = 0
    private var keys: MLXArray?
    private var values: MLXArray?

    /// Diagnostic metadata observation only; callers must not evaluate to inspect availability.
    var retainedArrays: [MLXArray] { [keys, values].compactMap { $0 } }

    func update(keys incomingKeys: MLXArray, values incomingValues: MLXArray) -> (MLXArray, MLXArray) {
        let previous = offset
        let next = previous + incomingKeys.dim(2)
        precondition(next <= 1536)
        if keys == nil || next > keys!.dim(2) {
            let needed = ((incomingKeys.dim(2) + 255) / 256) * 256
            let shape = [incomingKeys.dim(0), incomingKeys.dim(1), needed, incomingKeys.dim(3)]
            let newK = MLXArray.zeros(shape, dtype: incomingKeys.dtype)
            let newV = MLXArray.zeros(shape, dtype: incomingValues.dtype)
            if let oldK = keys, let oldV = values {
                keys = concatenated([oldK[.ellipsis, ..<previous, 0...], newK], axis: 2)
                values = concatenated([oldV[.ellipsis, ..<previous, 0...], newV], axis: 2)
            } else { keys = newK; values = newV }
        }
        offset = next
        keys?[.ellipsis, previous..<next, 0...] = incomingKeys
        values?[.ellipsis, previous..<next, 0...] = incomingValues
        return (keys![.ellipsis, ..<next, 0...], values![.ellipsis, ..<next, 0...])
    }
}

func createAttentionMask(h: MLXArray, cache: KVCache?) -> MLXFast.ScaledDotProductAttentionMaskMode {
    h.dim(1) == 1 ? .none : .causal
}
