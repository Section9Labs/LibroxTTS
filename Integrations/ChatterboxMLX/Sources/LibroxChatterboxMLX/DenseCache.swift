import MLX
import MLXFast

/// Single-owner, bounded experimental KV storage. Grows in 256-position blocks;
/// only the active prefix is presented to attention. No cross-unit state reuse.
final class KVCache {
    enum FixedFixtureError: Error { case invalidState }
    var offset = 0
    private var keys: MLXArray?
    private var values: MLXArray?

#if os(macOS)
    /// Separate general diagnostic, preserving the old fixed-fixture restrictions.
    func diagnosticSnapshot(expectedOffset: Int) throws -> (keys: [Float16], values: [Float16], capacity: Int) {
        guard (1...1536).contains(expectedOffset), offset == expectedOffset, let keys, let values,
            keys.ndim == 4, keys.dim(0) == 2, keys.dim(1) == 16, keys.dim(3) == 64,
            keys.dim(2) >= expectedOffset, values.shape == keys.shape,
            keys.dtype == .float16, values.dtype == .float16 else { throw FixedFixtureError.invalidState }
        let k = keys[.ellipsis, ..<expectedOffset, 0...].asArray(Float16.self)
        let v = values[.ellipsis, ..<expectedOffset, 0...].asArray(Float16.self)
        guard k.allSatisfy(\.isFinite), v.allSatisfy(\.isFinite) else { throw FixedFixtureError.invalidState }
        return (k, v, keys.dim(2))
    }
#endif

    /// Fixed public Spanish fixture boundaries only. Independent host bytes prevent a
    /// later decode's in-place cache update from changing this snapshot.
    func fixedFixtureSnapshot(expectedOffset: Int = 93) throws -> (keys: [Float16], values: [Float16]) {
        guard [93, 94, 95].contains(expectedOffset), offset == expectedOffset, let keys, let values,
            keys.shape == [2, 16, 256, 64], values.shape == keys.shape,
            keys.dtype == .float16, values.dtype == .float16 else { throw FixedFixtureError.invalidState }
        let k = keys[.ellipsis, ..<expectedOffset, 0...].asArray(Float16.self)
        let v = values[.ellipsis, ..<expectedOffset, 0...].asArray(Float16.self)
        guard k.allSatisfy(\.isFinite), v.allSatisfy(\.isFinite) else { throw FixedFixtureError.invalidState }
        return (k, v)
    }

    /// Same zero padding, capacity and strides as a normal fixed public state.
    /// This helper is used only by a non-audio fixed-fixture diagnostic.
    static func restoringFixedFixture(keys: MLXArray, values: MLXArray, expectedOffset: Int = 93) throws -> KVCache {
        guard [93, 94, 95].contains(expectedOffset), keys.shape == [2, 16, expectedOffset, 64], values.shape == keys.shape,
            keys.dtype == .float16, values.dtype == .float16,
            all(isFinite(keys)).item(Bool.self), all(isFinite(values)).item(Bool.self)
        else { throw FixedFixtureError.invalidState }
        let cache = KVCache()
        cache.keys = MLXArray.zeros([2, 16, 256, 64], dtype: .float16)
        cache.values = MLXArray.zeros([2, 16, 256, 64], dtype: .float16)
        cache.keys?[.ellipsis, ..<expectedOffset, 0...] = keys
        cache.values?[.ellipsis, ..<expectedOffset, 0...] = values
        cache.offset = expectedOffset
        eval(cache.keys!, cache.values!)
        return cache
    }

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
