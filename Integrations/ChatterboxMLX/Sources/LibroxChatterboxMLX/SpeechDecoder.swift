import MLX
import MLXNN
import Foundation

enum DecoderWeightError: Error { case invalidStructure }

/// Separately measured profiles; mixed precision is an approximation, not a
/// replacement for the unchanged FP32 correctness reference.
enum DecoderPrecision: String {
    case float32, mixedFloat16, mixedFloat16Accurate
    var projectionType: DType { self == .float32 ? .float32 : .float16 }
    var accurateActivations: Bool { self == .mixedFloat16Accurate }
    var headType: DType { accurateActivations ? .float32 : projectionType }
    func loadWeights(from url: URL) throws -> [String: MLXArray] {
        var weights = try loadArrays(url: url)
        guard weights.count == 272,
              weights.values.filter({ $0.ndim == 2 }).count == 211,
              weights.values.filter({ $0.ndim == 1 }).count == 61,
              weights.values.allSatisfy({ $0.dtype == .float32 })
        else { throw DecoderWeightError.invalidStructure }
        if self != .float32 {
            // Remove, convert, materialize and release one original at a time.
            // Never retain full FP32 and FP16 dictionaries simultaneously.
            for key in Array(weights.keys) {
                try Task.checkCancellation()
                guard weights[key]!.ndim == 2 else { continue }
                if accurateActivations, key == "speech_head.weight" { continue }
                let original = weights.removeValue(forKey: key)!
                let converted = original.asType(.float16)
                eval(converted)
                weights[key] = converted
            }
            Memory.clearCache()
        }
        guard weights.allSatisfy({ key, value in
            value.dtype == (key == "speech_head.weight" ? headType : (value.ndim == 2 ? projectionType : .float32))
        })
        else { throw DecoderWeightError.invalidStructure }
        return weights
    }
}

/// Single-owner backbone-only decoder. V3 tokenization, conditioning, sampling
/// and acoustics are outside this diagnostic. No production integration implied.
final class SpeechDecoder: Module {
    let precision: DecoderPrecision
    @ModuleInfo(key: "tfmr") var transformer: T3LlamaInner
    @ModuleInfo(key: "speech_head") var head: Linear
    init(precision: DecoderPrecision = .float32, compiledDecodeMLP: Bool = false) {
        self.precision = precision
        _transformer.wrappedValue = T3LlamaInner(.llama520M, compiledDecodeMLP: compiledDecodeMLP)
        _head.wrappedValue = Linear(1024, 8194, bias: false)
    }
    func logits(_ embeddings: MLXArray, cache: [KVCache]) -> MLXArray {
        head(transformer(embeddings, cache: cache, projectionType: precision.projectionType,
                         accurateActivations: precision.accurateActivations)[0..., -1, 0...]
            .asType(precision.headType)).asType(.float32)
    }
}
