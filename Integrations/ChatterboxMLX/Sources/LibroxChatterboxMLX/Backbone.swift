//
//  T3Model.swift
//  MLXAudio
//
//  T3 (Token-To-Token) TTS model: LLaMA backbone + text/speech embeddings + CFG inference.
//  Ported from mlx-audio Python: chatterbox/t3/t3.py
//

import Foundation
import MLX
import MLXFast
import MLXNN

// MARK: - Llama3 Scaled RoPE for T3

/// Llama3-style scaled RoPE matching the Chatterbox T3 config.
private class T3Llama3ScaledRoPE: Module {
    let dims: Int
    let traditional: Bool
    private let _freqs: MLXArray
#if os(macOS)
    // Mac-only causal probes; never configured by any renderer/profile.
    var diagnosticObserver: ((MLXArray, MLXArray, MLXArray, Int) -> Void)?
    var diagnosticRotation: ((MLXArray, Int) -> MLXArray)?
#endif

    init(
        dims: Int,
        traditional: Bool = false,
        base: Float = 500000.0,
        scaleFactor: Float = 8.0,
        lowFreqFactor: Float = 1.0,
        highFreqFactor: Float = 4.0,
        oldContextLen: Float = 8192.0
    ) {
        precondition(dims % 2 == 0, "RoPE dims must be even")
        self.dims = dims
        self.traditional = traditional

        let indices = MLXArray(stride(from: 0, to: dims, by: 2)).asType(.float32)
        let exponents = indices / MLXArray(Float(dims))
        var freqs = MLX.pow(MLXArray(base), exponents)

        let wavelens = MLXArray(2.0 * Float.pi) * freqs
        let lowFreqWavelen = oldContextLen / lowFreqFactor
        let highFreqWavelen = oldContextLen / highFreqFactor

        freqs = MLX.where(wavelens .> MLXArray(lowFreqWavelen), freqs * scaleFactor, freqs)

        let isMediumFreq = logicalAnd(
            wavelens .> MLXArray(highFreqWavelen),
            wavelens .< MLXArray(lowFreqWavelen)
        )

        let smoothFactors = (MLXArray(oldContextLen) / wavelens - MLXArray(lowFreqFactor))
            / MLXArray(highFreqFactor - lowFreqFactor)
        let denominator = (MLXArray(1.0) - smoothFactors) / MLXArray(scaleFactor) + smoothFactors
        let smoothFreqs = freqs / denominator

        self._freqs = MLX.where(isMediumFreq, smoothFreqs, freqs)
        super.init()
    }

    init(dims: Int, config: LlamaBackboneConfig) {
        let base = config.ropeTheta
        let rs = config.ropeScaling

        self.dims = dims
        self.traditional = false

        let scaleFactor = rs?.factor ?? 8.0
        let lowFreqFactor = rs?.lowFreqFactor ?? 1.0
        let highFreqFactor = rs?.highFreqFactor ?? 4.0
        let oldContextLen = Float(rs?.originalMaxPositionEmbeddings ?? 8192)

        let indices = MLXArray(stride(from: 0, to: dims, by: 2)).asType(.float32)
        let exponents = indices / MLXArray(Float(dims))
        var freqs = MLX.pow(MLXArray(base), exponents)

        let wavelens = MLXArray(2.0 * Float.pi) * freqs
        let lowFreqWavelen = oldContextLen / lowFreqFactor
        let highFreqWavelen = oldContextLen / highFreqFactor

        freqs = MLX.where(wavelens .> MLXArray(lowFreqWavelen), freqs * scaleFactor, freqs)

        let isMediumFreq = logicalAnd(
            wavelens .> MLXArray(highFreqWavelen),
            wavelens .< MLXArray(lowFreqWavelen)
        )

        let smoothFactors = (MLXArray(oldContextLen) / wavelens - MLXArray(lowFreqFactor))
            / MLXArray(highFreqFactor - lowFreqFactor)
        let denominator = (MLXArray(1.0) - smoothFactors) / MLXArray(scaleFactor) + smoothFactors
        let smoothFreqs = freqs / denominator

        self._freqs = MLX.where(isMediumFreq, smoothFreqs, freqs)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, offset: Int = 0) -> MLXArray {
#if os(macOS)
        if let diagnosticRotation { return diagnosticRotation(x, offset) }
#endif
        let result = MLXFast.RoPE(
            x,
            dimensions: dims,
            traditional: traditional,
            base: nil,
            scale: 1.0,
            offset: offset,
            freqs: _freqs
        )
#if os(macOS)
        diagnosticObserver?(x, _freqs, result, offset)
#endif
        return result
    }
}

// MARK: - T3 LLaMA Attention

private class T3Attention: Module {
#if os(macOS)
    var diagnosticMaterializedAttention = false
#endif
    let scale: Float
    let nHeads: Int
    let nKVHeads: Int
    let headDim: Int

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear

    let rope: T3Llama3ScaledRoPE

    init(_ config: LlamaBackboneConfig) {
        let dim = config.hiddenSize
        self.nHeads = config.numAttentionHeads
        self.nKVHeads = config.numKeyValueHeads
        self.headDim = config.headDim
        self.scale = pow(Float(headDim), -0.5)

        self._wq.wrappedValue = Linear(dim, nHeads * headDim, bias: config.attentionBias)
        self._wk.wrappedValue = Linear(dim, nKVHeads * headDim, bias: config.attentionBias)
        self._wv.wrappedValue = Linear(dim, nKVHeads * headDim, bias: config.attentionBias)
        self._wo.wrappedValue = Linear(nHeads * headDim, dim, bias: config.attentionBias)

        self.rope = T3Llama3ScaledRoPE(dims: headDim, config: config)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?, projectionType: DType,
        accurateActivations: Bool
    ) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))

        let projectedInput = x.asType(projectionType)
        var queries = wq(projectedInput)
        var keys = wk(projectedInput)
        var values = wv(projectedInput)

        queries = queries.reshaped(b, l, nHeads, headDim).transposed(0, 2, 1, 3)
        keys = keys.reshaped(b, l, nKVHeads, headDim).transposed(0, 2, 1, 3)
        values = values.reshaped(b, l, nKVHeads, headDim).transposed(0, 2, 1, 3)

        if let cache {
            queries = rope(queries, offset: cache.offset)
            keys = rope(keys, offset: cache.offset)
            (keys, values) = cache.update(keys: keys, values: values)
        } else {
            queries = rope(queries)
            keys = rope(keys)
        }

        let attentionType: DType = accurateActivations ? .float32 : projectionType
        let attended: MLXArray
#if os(macOS)
        if diagnosticMaterializedAttention {
            attended = DiagnosticArithmetic.attention(queries: queries.asType(attentionType),
                keys: keys.asType(attentionType), values: values.asType(attentionType), scale: scale)
        } else {
            attended = MLXFast.scaledDotProductAttention(
                queries: queries.asType(attentionType), keys: keys.asType(attentionType),
                values: values.asType(attentionType), scale: scale, mask: mask)
        }
#else
        attended = MLXFast.scaledDotProductAttention(
            queries: queries.asType(attentionType), keys: keys.asType(attentionType),
            values: values.asType(attentionType), scale: scale, mask: mask
        )
#endif
        let output = attended.transposed(0, 2, 1, 3).reshaped(b, l, -1).asType(projectionType)

        return wo(output).asType(x.dtype)
    }
}

// MARK: - T3 LLaMA MLP

private class T3MLP: Module {
#if os(macOS)
    var diagnosticUncompiledSiLU = false
#endif
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(_ config: LlamaBackboneConfig) {
        self._gate.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: config.mlpBias)
        self._down.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: config.mlpBias)
        self._up.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: config.mlpBias)
    }

    func callAsFunction(_ x: MLXArray, projectionType: DType, accurateActivations: Bool) -> MLXArray {
        let projectedInput = x.asType(projectionType)
        if accurateActivations {
#if os(macOS)
            if diagnosticUncompiledSiLU {
                let g = gate(projectedInput).asType(.float32)
                let activated = (g * MLX.sigmoid(g)) * up(projectedInput).asType(.float32)
                return down(activated.asType(projectionType)).asType(x.dtype)
            }
#endif
            let activated = silu(gate(projectedInput).asType(.float32)) * up(projectedInput).asType(.float32)
            return down(activated.asType(projectionType)).asType(x.dtype)
        }
        return down(silu(gate(projectedInput)) * up(projectedInput)).asType(x.dtype)
    }
}

// MARK: - T3 LLaMA Transformer Block

private class T3TransformerBlock: Module {
#if os(macOS)
    var diagnosticExplicitNorm = false
#endif
    @ModuleInfo(key: "self_attn") var attention: T3Attention
    @ModuleInfo(key: "mlp") var mlp: T3MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ config: LlamaBackboneConfig) {
        self._attention.wrappedValue = T3Attention(config)
        self._mlp.wrappedValue = T3MLP(config)
        self._inputLayerNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?, projectionType: DType,
        accurateActivations: Bool
    ) -> MLXArray {
#if os(macOS)
        if diagnosticExplicitNorm {
            let r = attention(DiagnosticArithmetic.norm(x, inputLayerNorm), mask: mask, cache: cache,
                projectionType: projectionType, accurateActivations: accurateActivations)
            let h = x + r
            return h + mlp(DiagnosticArithmetic.norm(h, postAttentionLayerNorm),
                projectionType: projectionType, accurateActivations: accurateActivations)
        }
#endif
        let r = attention(inputLayerNorm(x), mask: mask, cache: cache, projectionType: projectionType,
                          accurateActivations: accurateActivations)
        let h = x + r
        return h + mlp(postAttentionLayerNorm(h), projectionType: projectionType, accurateActivations: accurateActivations)
    }
}

// MARK: - T3 LLaMA Inner Model

/// Inner LLaMA model for T3 — takes **embeddings** (not token IDs).
///
/// In the Python code, `self.tfmr.model(inputs=None, input_embeddings=embeds, cache=cache)`.
/// This corresponds to LLaMA's model.layers + norm, accepting pre-computed embeddings.
class T3LlamaInner: Module {
#if os(macOS)
    private var diagnosticExplicitNorm = false
#endif
    fileprivate let layers: [T3TransformerBlock]
    let norm: RMSNorm

    init(_ config: LlamaBackboneConfig) {
        self.layers = (0 ..< config.numHiddenLayers).map { _ in T3TransformerBlock(config) }
        self.norm = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
    }

#if os(macOS)
    func diagnosticSetArithmetic(_ policy: DiagnosticArithmetic) {
        diagnosticExplicitNorm = policy.contains(.explicitNorm)
        for layer in layers {
            layer.diagnosticExplicitNorm = policy.contains(.explicitNorm)
            layer.attention.diagnosticMaterializedAttention = policy.contains(.materializedAttention)
            layer.mlp.diagnosticUncompiledSiLU = policy.contains(.uncompiledSiLU)
        }
    }

    func diagnosticObserveRoPE(_ observer: ((Int, MLXArray, MLXArray, MLXArray, Int) -> Void)?) {
        for (index, layer) in layers.enumerated() {
            layer.attention.rope.diagnosticObserver = observer.map { observe in
                { input, frequencies, output, offset in observe(index, input, frequencies, output, offset) }
            }
        }
    }

    func diagnosticReplaceRoPE(_ rotation: ((MLXArray, Int) -> MLXArray)?) {
        for layer in layers { layer.attention.rope.diagnosticRotation = rotation }
    }
#endif

    /// Forward pass with pre-computed embeddings.
    func callAsFunction(_ embeddings: MLXArray, cache: [KVCache]? = nil, projectionType: DType = .float32,
                        accurateActivations: Bool = false) -> MLXArray {
        var h = embeddings
        let mask = createAttentionMask(h: h, cache: cache?.first)

        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i], projectionType: projectionType,
                      accurateActivations: accurateActivations)
        }
#if os(macOS)
        if diagnosticExplicitNorm { return DiagnosticArithmetic.norm(h, norm) }
#endif
        return norm(h)
    }
}
