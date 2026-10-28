import Foundation
import Accelerate

/// Host-side reproduction of the multilingual T3 `cond_enc.perceiver`
/// (`chatterbox/models/t3/modules/perceiver.py`). The Perceiver resamples a
/// variable-length conditioning-prompt speech embedding `(N, 1024)` down to a
/// fixed `(32, 1024)` block via one shared attention block applied twice
/// (cross-attention `query×prompt`, then self-attention on the result).
///
/// The shipped block is standard 4-head scaled-dot-product attention
/// (`flash_attention=True` → `F.scaled_dot_product_attention`; the `einsum`
/// branch is dead code), scale `head_dim**-0.5`, `LayerNorm` eps 1e-5, with a
/// residual on the query side. Verified equivalent to the PyTorch module
/// (cos 1.0) and to `prepare_conditioning` via the cond-block fixtures (`CondBlockTests`).
///
/// All math is plain `[Float]` on CPU — the block is tiny (32 queries × ~150
/// keys × 1024 dim) and computed once per voice (text-independent), so it never
/// touches the per-step hot path.
struct Perceiver: Sendable {
    static let dim = 1024
    static let heads = 4
    static let headDim = dim / heads          // 256
    static let queryLen = 32
    private static let eps: Float = 1e-5
    private static let scale: Float = 1.0 / 16.0   // head_dim**-0.5 = 256**-0.5

    private let query: [Float]                 // (32, 1024) row-major
    private let normW: [Float], normB: [Float] // (1024)
    private let qW: [Float], qB: [Float]       // to_q  (1024,1024)+(1024)
    private let kW: [Float], kB: [Float]       // to_k
    private let vW: [Float], vB: [Float]       // to_v
    private let outW: [Float], outB: [Float]   // proj_out

    /// Loads the perceiver tables from a directory of `.npy` files named
    /// `perceiver_query`, `perceiver_norm_{weight,bias}`,
    /// `perceiver_{to_q,to_k,to_v,proj_out}_{weight,bias}`.
    init(dir: URL) throws {
        func vec(_ name: String, _ expect: Int) throws -> [Float] {
            let (d, _) = try NPYFloat32.read(url: dir.appendingPathComponent("\(name).npy"))
            guard d.count == expect else {
                throw ChatterboxError.npy("perceiver \(name) count \(d.count) != \(expect)")
            }
            return d
        }
        let D = Self.dim
        query = try vec("perceiver_query", Self.queryLen * D)
        normW = try vec("perceiver_norm_weight", D)
        normB = try vec("perceiver_norm_bias", D)
        qW = try vec("perceiver_to_q_weight", D * D); qB = try vec("perceiver_to_q_bias", D)
        kW = try vec("perceiver_to_k_weight", D * D); kB = try vec("perceiver_to_k_bias", D)
        vW = try vec("perceiver_to_v_weight", D * D); vB = try vec("perceiver_to_v_bias", D)
        outW = try vec("perceiver_proj_out_weight", D * D); outB = try vec("perceiver_proj_out_bias", D)
    }

    /// Memberwise init (tests / in-memory construction).
    init(query: [Float], normW: [Float], normB: [Float],
         qW: [Float], qB: [Float], kW: [Float], kB: [Float],
         vW: [Float], vB: [Float], outW: [Float], outB: [Float]) {
        self.query = query; self.normW = normW; self.normB = normB
        self.qW = qW; self.qB = qB; self.kW = kW; self.kB = kB
        self.vW = vW; self.vB = vB; self.outW = outW; self.outB = outB
    }

    /// Resamples `prompt` (flat `(n, 1024)`, row-major) to a flat `(32, 1024)`
    /// conditioning block.
    func forward(_ prompt: [Float], n: Int) -> [Float] {
        let pre = block(x1: query, lq: Self.queryLen, x2: prompt, lk: n)   // cross
        return block(x1: pre, lq: Self.queryLen, x2: pre, lk: Self.queryLen) // self
    }

    // MARK: - one AttentionBlock2: out = x1 + proj_out(MHA(LN(x1), LN(x2), LN(x2)))

    private func block(x1: [Float], lq: Int, x2: [Float], lk: Int) -> [Float] {
        let D = Self.dim
        let x1n = Self.layerNorm(x1, rows: lq, dim: D, w: normW, b: normB, eps: Self.eps)
        let x2n = Self.layerNorm(x2, rows: lk, dim: D, w: normW, b: normB, eps: Self.eps)
        let q = Self.linear(x1n, rows: lq, inDim: D, outDim: D, w: qW, b: qB)
        let k = Self.linear(x2n, rows: lk, inDim: D, outDim: D, w: kW, b: kB)
        let v = Self.linear(x2n, rows: lk, inDim: D, outDim: D, w: vW, b: vB)
        let attended = Self.multiHeadAttention(q: q, lq: lq, k: k, v: v, lk: lk)
        let proj = Self.linear(attended, rows: lq, inDim: D, outDim: D, w: outW, b: outB)
        var out = [Float](repeating: 0, count: lq * D)
        for i in 0..<(lq * D) { out[i] = x1[i] + proj[i] }   // residual on x1
        return out
    }

    // MARK: - primitives (flat row-major)

    /// `y = (x − mean)/sqrt(var + eps) · w + b`, per row. var is the biased
    /// (population) variance, matching `nn.LayerNorm`.
    static func layerNorm(_ x: [Float], rows: Int, dim: Int, w: [Float], b: [Float], eps: Float) -> [Float] {
        var out = [Float](repeating: 0, count: rows * dim)
        let inv = 1.0 / Float(dim)
        x.withUnsafeBufferPointer { xp in
        w.withUnsafeBufferPointer { wp in
        b.withUnsafeBufferPointer { bp in
            for r in 0..<rows {
                let base = r * dim
                var mean: Float = 0
                for d in 0..<dim { mean += xp[base + d] }
                mean *= inv
                var varAcc: Float = 0
                for d in 0..<dim { let z = xp[base + d] - mean; varAcc += z * z }
                varAcc *= inv
                let rstd = 1.0 / (varAcc + eps).squareRoot()
                for d in 0..<dim { out[base + d] = (xp[base + d] - mean) * rstd * wp[d] + bp[d] }
            }
        }}}
        return out
    }

    /// `y = x · Wᵀ + b`, with `W` row-major `(outDim, inDim)` (PyTorch `nn.Linear`).
    /// Uses BLAS `sgemm` (C = x · Wᵀ) so it's fast in both debug and release.
    static func linear(_ x: [Float], rows: Int, inDim: Int, outDim: Int, w: [Float], b: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: rows * outDim)
        // C(rows×outDim) = A(rows×inDim) · op(B), op(B)=Bᵀ, B=W stored (outDim×inDim).
        x.withUnsafeBufferPointer { xp in
        w.withUnsafeBufferPointer { wp in
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                        Int32(rows), Int32(outDim), Int32(inDim),
                        1.0, xp.baseAddress, Int32(inDim),
                        wp.baseAddress, Int32(inDim),
                        0.0, &out, Int32(outDim))
        }}
        // + bias (broadcast over rows)
        b.withUnsafeBufferPointer { bp in
            for r in 0..<rows {
                let ob = r * outDim
                for o in 0..<outDim { out[ob + o] += bp[o] }
            }
        }
        return out
    }

    /// Standard 4-head SDPA. q `(lq, dim)`, k/v `(lk, dim)`, both reshaped to
    /// `(L, heads, headDim)` row-major. Returns `(lq, dim)`.
    static func multiHeadAttention(q: [Float], lq: Int, k: [Float], v: [Float], lk: Int) -> [Float] {
        let H = heads, hd = headDim, D = dim
        var out = [Float](repeating: 0, count: lq * D)
        var scores = [Float](repeating: 0, count: lk)
        q.withUnsafeBufferPointer { qp in
        k.withUnsafeBufferPointer { kp in
        v.withUnsafeBufferPointer { vp in
            for h in 0..<H {
                let hoff = h * hd
                for i in 0..<lq {
                    let qb = i * D + hoff
                    // scores[j] = (q_i · k_j) * scale
                    var maxS = -Float.greatestFiniteMagnitude
                    for j in 0..<lk {
                        let kb = j * D + hoff
                        var acc: Float = 0
                        for d in 0..<hd { acc += qp[qb + d] * kp[kb + d] }
                        acc *= scale
                        scores[j] = acc
                        if acc > maxS { maxS = acc }
                    }
                    // softmax
                    var sum: Float = 0
                    for j in 0..<lk { let e = Foundation.exp(scores[j] - maxS); scores[j] = e; sum += e }
                    let rsum = 1.0 / sum
                    // o_i = Σ_j attn_ij · v_j
                    let ob = i * D + hoff
                    for d in 0..<hd { out[ob + d] = 0 }
                    for j in 0..<lk {
                        let a = scores[j] * rsum
                        let vb = j * D + hoff
                        for d in 0..<hd { out[ob + d] += a * vp[vb + d] }
                    }
                }
            }
        }}}
        return out
    }
}
