//
//  ChatterboxConfig.swift
//  MLXAudio
//
//  Chatterbox TTS configuration.
//  Ported from mlx-audio Python: chatterbox/config.py
//

import Foundation

// MARK: - LLaMA 520M Configuration (T3 backbone)

/// Static LLaMA configuration used by T3.
/// Maps to Python's LLAMA_520M_CONFIG dict.
public struct LlamaBackboneConfig: Codable, Sendable {
    public var modelType: String
    public var vocabSize: Int
    public var hiddenSize: Int
    public var numHiddenLayers: Int
    public var intermediateSize: Int
    public var numAttentionHeads: Int
    public var numKeyValueHeads: Int
    public var headDim: Int
    public var maxPositionEmbeddings: Int
    public var rmsNormEps: Float
    public var ropeTheta: Float
    public var ropeScaling: RopeScaling?
    public var attentionBias: Bool
    public var mlpBias: Bool
    public var tieWordEmbeddings: Bool

    public struct RopeScaling: Codable, Sendable {
        public var factor: Float
        public var highFreqFactor: Float
        public var lowFreqFactor: Float
        public var originalMaxPositionEmbeddings: Int
        public var ropeType: String

        enum CodingKeys: String, CodingKey {
            case factor
            case highFreqFactor = "high_freq_factor"
            case lowFreqFactor = "low_freq_factor"
            case originalMaxPositionEmbeddings = "original_max_position_embeddings"
            case ropeType = "rope_type"
        }
    }

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case vocabSize = "vocab_size"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case numAttentionHeads = "num_attention_heads"
        case numKeyValueHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case maxPositionEmbeddings = "max_position_embeddings"
        case rmsNormEps = "rms_norm_eps"
        case ropeTheta = "rope_theta"
        case ropeScaling = "rope_scaling"
        case attentionBias = "attention_bias"
        case mlpBias = "mlp_bias"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    /// Default LLaMA 520M config matching Python's LLAMA_520M_CONFIG.
    public static let llama520M = LlamaBackboneConfig(
        modelType: "llama",
        vocabSize: 4000,
        hiddenSize: 1024,
        numHiddenLayers: 30,
        intermediateSize: 4096,
        numAttentionHeads: 16,
        numKeyValueHeads: 16,
        headDim: 64,
        maxPositionEmbeddings: 131072,
        rmsNormEps: 1e-05,
        ropeTheta: 500000.0,
        ropeScaling: RopeScaling(
            factor: 8.0,
            highFreqFactor: 4.0,
            lowFreqFactor: 1.0,
            originalMaxPositionEmbeddings: 8192,
            ropeType: "llama3"
        ),
        attentionBias: false,
        mlpBias: false,
        tieWordEmbeddings: false
    )
}
