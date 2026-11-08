// SPDX-License-Identifier: Apache-2.0 OR MIT
import MLX
import MLXFast

/// Actor-owned cache. State snapshots share immutable MLX values, never mutable caches.
public final class KVCacheSimple {
    public var offset = 0
    private var keys: MLXArray?
    private var values: MLXArray?
    public init() {}
    public var state: [MLXArray] {
        get { guard let keys, let values else { return [] }; return [keys, values] }
        set { precondition(newValue.count == 2); keys = newValue[0]; values = newValue[1]; offset = newValue[0].shape[2] }
    }
    public func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        let k = self.keys.map { concatenated([$0, keys], axis: 2) } ?? keys
        let v = self.values.map { concatenated([$0, values], axis: 2) } ?? values
        self.keys = k; self.values = v; offset += keys.shape[2]
        return (k, v)
    }
    @discardableResult public func trim(_ count: Int) -> Int {
        let n = min(offset, max(0, count)); offset -= n
        if offset == 0 { keys = nil; values = nil }
        else { keys = keys?[.ellipsis, ..<offset, 0...]; values = values?[.ellipsis, ..<offset, 0...] }
        return n
    }
}
public typealias KVCache = KVCacheSimple
func createAttentionMask(h: MLXArray, cache: KVCacheSimple) -> MLXFast.ScaledDotProductAttentionMaskMode {
    h.shape[1] == 1 ? .none : .causal
}
