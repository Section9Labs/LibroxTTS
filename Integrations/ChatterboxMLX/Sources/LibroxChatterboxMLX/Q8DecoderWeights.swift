import Foundation
import MLX
import MLXNN

/// Exact local V3 Q8 artifact. Its identity is checked before this loader is used.
enum Q8DecoderWeights {
    static func load(from url: URL, canonicalHalf: Bool = false, useNativePrefill: Bool = true, semanticRoPE: SemanticHalfRoPE? = nil) throws -> SpeechDecoder {
        let weights = try loadArrays(url: url)
        let model = SpeechDecoder(precision: .mixedFloat16Accurate)
        let expected = model.parameters().flattened()
        guard weights.count == 692 else { throw DecoderWeightError.invalidStructure }
        var keys = Set(expected.map(\.0))
        var modules: [(String, Module)] = []
        for (name, module) in model.leafModules().flattened() {
            guard name.hasPrefix("tfmr.layers."), let linear = module as? Linear else { continue }
            guard let w = weights[name + ".weight"], let s = weights[name + ".scales"],
                  let b = weights[name + ".biases"], w.dtype == .uint32,
                  s.dtype == .float16, b.dtype == .float16,
                  w.shape == [linear.shape.0, linear.shape.1 / 4],
                  s.shape == [linear.shape.0, linear.shape.1 / 64], s.shape == b.shape,
                  all(isFinite(s)).item(Bool.self), all(isFinite(b)).item(Bool.self)
            else { throw DecoderWeightError.invalidStructure }
            keys.insert(name + ".scales"); keys.insert(name + ".biases")
            let projection: QuantizedLinear = canonicalHalf
                ? CanonicalQ8Linear(weight: w, scales: s, biases: b, useNativePrefill: useNativePrefill)
                : QuantizedLinear(weight: w, scales: s, biases: b, groupSize: 64, bits: 8)
            guard projection(MLXArray.zeros([2, 1, linear.shape.1], dtype: .float16)).dtype == .float16
            else { throw DecoderWeightError.invalidStructure }
            modules.append((name, projection))
        }
        guard modules.count == 210, keys == Set(weights.keys) else { throw DecoderWeightError.invalidStructure }
        for (key, template) in expected where !key.hasPrefix("tfmr.layers.") || key.contains("layernorm") {
            guard let w = weights[key], w.shape == template.shape, w.dtype == .float32,
                  all(isFinite(w)).item(Bool.self) else { throw DecoderWeightError.invalidStructure }
        }
        model.update(modules: ModuleChildren.unflattened(modules))
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        if let semanticRoPE {
            guard canonicalHalf && useNativePrefill else { throw DecoderWeightError.invalidStructure }
            model.transformer.useSemanticHalfRoPE(semanticRoPE)
        }
        eval(model)
        return model
    }
}
