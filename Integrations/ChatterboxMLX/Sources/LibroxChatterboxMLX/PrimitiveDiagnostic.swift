#if os(macOS)
import Foundation
import MLX
import MLXFast
import MLXNN

/// Public-stock fixed tensors only, exported on CPU and replayed in a fresh
/// GPU process. Nothing here creates or selects an inference profile.
enum PrimitiveDiagnostic {
    // CPU export v02 passed all exact trace and restore controls before pinning.
    static let fixtureSHA256 = "ba0a7add438d5f1326ce7aa541339cee4b2d3d3d973c3f56ddfb6019b00d38d4"
    enum Failure: Error { case identity, fixture, output }
    struct Files {
        let weights: URL
        let oracle: URL
        let cpu93: URL
        let cpu95: URL
        let primitives: URL
        let output: URL
    }
    struct Difference: Codable {
        let count: Int
        let maximumAbsoluteError: Float
        let relativeL2: Double
        let unequalStoredBits: Int
        let unequalHalfRoundedBits: Int
    }
    struct Row: Codable {
        let module: String
        let kind: String
        let policy: String
        let difference: Difference
        let directHeadComparison: ChatterboxQ8FixedFixtureDiagnostic.Comparison?
    }
    private final class Recorder {
        var enabled = false
        var arrays: [String: MLXArray] = [:]
        func observe(_ name: String, _ array: MLXArray) {
            guard enabled else { return }
            precondition(arrays[name] == nil)
            arrays[name] = array
        }
        func freeze() throws {
            enabled = false
            for key in Array(arrays.keys) {
                try ChatterboxMLXRenderer.healthy()
                let array = arrays[key]!
                if array.dtype == .float16 {
                    arrays[key] = MLXArray(array.asArray(Float16.self), array.shape)
                } else if array.dtype == .float32 {
                    arrays[key] = MLXArray(array.asArray(Float.self), array.shape)
                } else { throw Failure.fixture }
            }
        }
    }
    private final class ObservedLinear: Linear {
        let name: String
        let recorder: Recorder
        init(_ layer: Linear, name: String, recorder: Recorder) {
            self.name = name; self.recorder = recorder
            super.init(weight: layer.weight, bias: layer.bias)
        }
        override func callAsFunction(_ x: MLXArray) -> MLXArray {
            let output = super.callAsFunction(x)
            recorder.observe(name + ".input", x); recorder.observe(name + ".output", output)
            return output
        }
    }
    private final class ObservedNorm: RMSNorm {
        let name: String
        let recorder: Recorder
        init(_ layer: RMSNorm, name: String, recorder: Recorder) throws {
            self.name = name; self.recorder = recorder
            super.init(dimensions: layer.weight.size, eps: layer.eps)
            try update(parameters: ModuleParameters.unflattened([("weight", layer.weight)]), verify: .all)
        }
        override func callAsFunction(_ x: MLXArray) -> MLXArray {
            let output = super.callAsFunction(x)
            recorder.observe(name + ".input", x); recorder.observe(name + ".output", output)
            return output
        }
    }

    private static func identities(_ f: Files) throws {
        let profile = ChatterboxMLXRenderer.DecoderProfile.q8CanonicalHalfV2
        guard try ChatterboxMLXRenderer.digest(f.weights) == profile.weightsSHA256,
            try ChatterboxMLXRenderer.digest(f.oracle) == profile.oracleSHA256,
            try ChatterboxMLXRenderer.digest(f.cpu93) == ChatterboxQ8FixedFixtureDiagnostic.cpuPrefillCacheSHA256,
            try ChatterboxMLXRenderer.digest(f.cpu95) == DiagnosticRoPEFixture.sha256,
            ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0",
            !FileManager.default.fileExists(atPath: f.output.path)
        else { throw Failure.identity }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: 3 * 1_024 * 1_024 * 1_024)
    }

    static func export(_ f: Files, loadCPUModel: () throws -> SpeechDecoder) throws {
        try identities(f)
        guard !FileManager.default.fileExists(atPath: f.primitives.path) else { throw Failure.identity }
        let began = Date()
        try Device.withDefaultDevice(.cpu) {
            let model = try loadCPUModel()
            let fixture = try loadArrays(url: f.oracle)
            let recorder = Recorder()
            var updated = 0
            for traced in [false, true] {
                if traced {
                    var replacements: [(String, Module)] = []
                    for (name, module) in model.leafModules().flattened() {
                        if let layer = module as? Linear {
                            replacements.append((name, ObservedLinear(layer, name: name, recorder: recorder)))
                        } else if let layer = module as? RMSNorm, name != "tfmr.norm" {
                            replacements.append((name, try ObservedNorm(layer, name: name, recorder: recorder)))
                        }
                    }
                    // The final norm is an immutable module, observed through
                    // the backbone hook without replacing its registration.
                    guard replacements.count == 271 else { throw Failure.fixture }
                    updated = replacements.count
                    model.update(modules: ModuleChildren.unflattened(replacements))
                    model.transformer.diagnosticObservePrimitives { recorder.observe($0, $1) }
                }
                for language in ["en", "es"] {
                    let caches = (0..<30).map { _ in KVCache() }
                    for step in 0...8 {
                        try ChatterboxMLXRenderer.healthy()
                        let stem = language + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                        guard let input = fixture[stem + ".input"], let target = fixture[stem + ".logits"]
                        else { throw Failure.fixture }
                        recorder.enabled = traced && language == "es" && step == 3
                        let output = model.logits(input, cache: caches); eval(output)
                        try exact(output, target)
                        if recorder.enabled { try recorder.freeze() }
                    }
                }
            }
            model.transformer.diagnosticObservePrimitives(nil)
            let source = try loadArrays(url: f.cpu95)
            try DiagnosticRoPEFixture.validate(source)
            let caches = try restore(source, offset: 95)
            guard let input = fixture["es.decode.2.input"], let expected = fixture["es.decode.2.logits"]
            else { throw Failure.fixture }
            let output = model.logits(input, cache: caches); eval(output); try exact(output, expected)
            guard recorder.arrays.count == 694 else { throw Failure.fixture }
            for array in recorder.arrays.values {
                try ChatterboxMLXRenderer.healthy()
                guard all(isFinite(array)).item(Bool.self) else { throw Failure.output }
            }
            try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
            try save(arrays: recorder.arrays, metadata: ["scope": "public fixed es.decode.2 primitives only",
                "cpu_untraced_and_traced_18_bit_identical": "true", "cpu95_restore_target_bit_identical": "true",
                "weights_sha256": try ChatterboxMLXRenderer.digest(f.weights),
                "oracle_sha256": try ChatterboxMLXRenderer.digest(f.oracle)], url: f.primitives)
            try write(["completed": true, "cpu_only_process": true,
                "cpu_untraced_and_traced_18_bit_identical": true, "cpu95_restore_target_bit_identical": true,
                "wrapped_modules": updated, "arrays": recorder.arrays.count,
                "primitive_fixture_sha256": try ChatterboxMLXRenderer.digest(f.primitives),
                "wall_seconds": Date().timeIntervalSince(began)], to: f.output.appendingPathComponent("report.json"))
        }
    }

    static func replay(_ f: Files, expectedSHA256: String) throws {
        try identities(f)
        guard expectedSHA256 == fixtureSHA256, try ChatterboxMLXRenderer.digest(f.primitives) == fixtureSHA256
        else { throw Failure.identity }
        let began = Date()
        try Device.withDefaultDevice(.gpu) {
            let arrays = try loadArrays(url: f.primitives)
            let model = try Q8DecoderWeights.load(from: f.weights, canonicalHalf: true)
            try validate(arrays, model: model)
            var rows: [Row] = []
            for (name, module) in primitives(model).sorted(by: { $0.0 < $1.0 }) {
                try ChatterboxMLXRenderer.healthy()
                guard let input = arrays[name + ".input"], let expected = arrays[name + ".output"]
                else { throw Failure.fixture }
                if let layer = module as? Linear {
                    rows.append(try row(name, "projection", "nativeV2", layer(input), expected))
                    if let packed = layer as? CanonicalQ8Linear {
                        let dense = packed.reconstructedWeights()
                        rows.append(try row(name, "projection", "denseHalfMatmul", matmul(input, dense.T), expected))
                        rows.append(try row(name, "projection", "denseFP32Accumulation",
                            matmul(input.asType(.float32), dense.asType(.float32).T).asType(.float16), expected))
                    }
                } else if let layer = module as? RMSNorm {
                    rows.append(try row(name, "norm", "nativeGPU", layer(input), expected))
                    rows.append(try row(name, "norm", "explicitSequence", DiagnosticArithmetic.norm(input, layer), expected))
                } else { throw Failure.fixture }
            }
            for index in 0..<30 {
                try ChatterboxMLXRenderer.healthy()
                let stem = "tfmr.layers.\(index)."
                guard let q = arrays[stem + "attention.query"], let k = arrays[stem + "attention.key"],
                    let v = arrays[stem + "attention.value"], let target = arrays[stem + "attention.output"],
                    let g = arrays[stem + "mlp.gate_proj.output"], let u = arrays[stem + "mlp.up_proj.output"],
                    let activated = arrays[stem + "mlp.activated"] else { throw Failure.fixture }
                rows.append(try row(stem + "attention", "attention", "nativeGPU",
                    MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 0.125, mask: .none), target))
                rows.append(try row(stem + "attention", "attention", "materializedSequence",
                    DiagnosticArithmetic.attention(queries: q, keys: k, values: v, scale: 0.125), target))
                let g32 = g.asType(.float32), u32 = u.asType(.float32)
                rows.append(try row(stem + "mlp", "activation", "compiledSiLU", silu(g32) * u32, activated))
                rows.append(try row(stem + "mlp", "activation", "uncompiledSiLU", (g32 * MLX.sigmoid(g32)) * u32, activated))
            }
            let fixture = try loadArrays(url: f.oracle)
            var controls: [[String: Any]] = []
            for language in ["en", "es"] {
                let caches = (0..<30).map { _ in KVCache() }
                var comparisons: [ChatterboxQ8FixedFixtureDiagnostic.Comparison] = []
                for step in 0...8 {
                    try ChatterboxMLXRenderer.healthy()
                    let stem = language + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                    guard let input = fixture[stem + ".input"], let expected = fixture[stem + ".logits"] else { throw Failure.fixture }
                    let output = model.logits(input, cache: caches); eval(output)
                    comparisons.append(try ChatterboxQ8FixedFixtureDiagnostic.compare(output.asArray(Float.self),
                        expected.asArray(Float.self), stage: stem))
                }
                controls.append(["source": "native" + language, "comparisons": try object(comparisons)])
            }
            for offset in [93, 95] {
                let source = try loadArrays(url: offset == 93 ? f.cpu93 : f.cpu95)
                let caches = try restore(source, offset: offset)
                var comparisons: [ChatterboxQ8FixedFixtureDiagnostic.Comparison] = []
                for step in (offset - 93)..<3 {
                    try ChatterboxMLXRenderer.healthy()
                    let stem = "es.decode.\(step)"
                    guard let input = fixture[stem + ".input"], let expected = fixture[stem + ".logits"] else { throw Failure.fixture }
                    let output = model.logits(input, cache: caches); eval(output)
                    comparisons.append(try ChatterboxQ8FixedFixtureDiagnostic.compare(output.asArray(Float.self), expected.asArray(Float.self), stage: stem))
                }
                controls.append(["source": "cpu\(offset)", "comparisons": try object(comparisons)])
            }
            try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
            try write(["completed": true, "diagnostic_only": true, "gpu_only_process": true,
                "primitive_fixture_sha256": fixtureSHA256, "rows": try object(rows), "controls": controls,
                "unmeasured_leaf_modules": model.leafModules().flattened().filter {
                    !($0.1 is Linear) && !($0.1 is RMSNorm)
                }.map(\.0),
                "wall_seconds": Date().timeIntervalSince(began),
                "scope": "same-input primitive measurements; not a correction or inference clearance"],
                to: f.output.appendingPathComponent("report.json"))
        }
    }

    /// Before assigning discrepancies to the GPU, verify that materializing a
    /// captured input has not changed CPU dispatch/rounding itself.
    static func replayCPUProjections(_ f: Files, expectedSHA256: String,
                                     loadCPUModel: () throws -> SpeechDecoder) throws {
        try identities(f)
        guard expectedSHA256 == fixtureSHA256, try ChatterboxMLXRenderer.digest(f.primitives) == fixtureSHA256
        else { throw Failure.identity }
        let began = Date()
        try Device.withDefaultDevice(.cpu) {
            let arrays = try loadArrays(url: f.primitives)
            let model = try loadCPUModel()
            try validate(arrays, model: model)
            var rows: [Row] = []
            for (name, module) in primitives(model).sorted(by: { $0.0 < $1.0 }) {
                guard let layer = module as? Linear else { continue }
                try ChatterboxMLXRenderer.healthy()
                guard let input = arrays[name + ".input"], let expected = arrays[name + ".output"]
                else { throw Failure.fixture }
                rows.append(try row(name, "projection", "nativeCPUHalf", layer(input), expected))
                if name != "speech_head" {
                    rows.append(try row(name, "projection", "cpuFP32ThenHalf",
                        matmul(input.asType(.float32), layer.weight.asType(.float32).T).asType(.float16), expected))
                }
            }
            let control = rows.filter { $0.policy == "nativeCPUHalf" }
            let exact = control.count == 211 && control.allSatisfy { $0.difference.unequalStoredBits == 0 }
            try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
            try write(["completed": true, "diagnostic_only": true, "cpu_only_process": true,
                "materialized_cpu_projection_replay_bit_identical": exact,
                "primitive_fixture_sha256": fixtureSHA256, "rows": try object(rows),
                "wall_seconds": Date().timeIntervalSince(began),
                "scope": "CPU materialization and accumulation controls; no inference clearance"],
                to: f.output.appendingPathComponent("report.json"))
            guard exact else { throw Failure.output }
        }
    }

    private static func validate(_ arrays: [String: MLXArray], model: SpeechDecoder) throws {
        var required = Set<String>()
        var moduleCount = 0
        for (name, module) in primitives(model) {
            moduleCount += 1
            let inputShape: [Int], outputShape: [Int], dtype: DType
            if let layer = module as? Linear {
                let head = name == "speech_head"
                inputShape = head ? [2, layer.shape.1] : [2, 1, layer.shape.1]
                outputShape = head ? [2, layer.shape.0] : [2, 1, layer.shape.0]
                dtype = head ? .float32 : .float16
            } else if let layer = module as? RMSNorm {
                inputShape = [2, 1, layer.weight.size]; outputShape = inputShape; dtype = .float32
            } else { throw Failure.fixture }
            for (suffix, shape) in [("input", inputShape), ("output", outputShape)] {
                let key = name + "." + suffix; required.insert(key)
                guard let array = arrays[key], array.shape == shape, array.dtype == dtype else { throw Failure.fixture }
            }
        }
        guard moduleCount == 272 else { throw Failure.fixture }
        for i in 0..<30 {
            for suffix in ["attention.query", "attention.key", "attention.value", "attention.output", "mlp.activated"] {
                let key = "tfmr.layers.\(i)." + suffix; required.insert(key)
                let shape = suffix == "mlp.activated" ? [2, 1, 4096]
                    : (suffix == "attention.key" || suffix == "attention.value") ? [2, 16, 96, 64] : [2, 16, 1, 64]
                guard let array = arrays[key], array.shape == shape, array.dtype == .float32 else { throw Failure.fixture }
            }
        }
        guard arrays.count == 694, Set(arrays.keys) == required else { throw Failure.fixture }
        for array in arrays.values {
            try ChatterboxMLXRenderer.healthy()
            guard all(isFinite(array)).item(Bool.self) else { throw Failure.fixture }
        }
    }

    /// RoPE modules are also leaves; this stage measures linear/norm modules
    /// explicitly, while positional primitives have their own pinned replay.
    private static func primitives(_ model: SpeechDecoder) -> [(String, Module)] {
        model.leafModules().flattened().filter { $0.1 is Linear || $0.1 is RMSNorm }
    }

    private static func restore(_ arrays: [String: MLXArray], offset: Int) throws -> [KVCache] {
        try (0..<30).map { index in
            try ChatterboxMLXRenderer.healthy()
            let stem = offset == 93 ? "es.prefill.layer.\(index)" : "layer.\(index)"
            guard let k = arrays[stem + ".keys"], let v = arrays[stem + ".values"] else { throw Failure.fixture }
            return try KVCache.restoringFixedFixture(keys: k, values: v, expectedOffset: offset)
        }
    }
    private static func exact(_ output: MLXArray, _ target: MLXArray) throws {
        let a = output.asArray(Float.self), b = target.asArray(Float.self)
        guard a.count == 16_388, b.count == a.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite),
            zip(a, b).allSatisfy({ $0.bitPattern == $1.bitPattern }) else { throw Failure.output }
    }
    private static func row(_ module: String, _ kind: String, _ policy: String,
                            _ output: MLXArray, _ expected: MLXArray) throws -> Row {
        eval(output)
        guard output.shape == expected.shape, output.dtype == expected.dtype else { throw Failure.output }
        let a = output.asType(.float32).asArray(Float.self), b = expected.asType(.float32).asArray(Float.self)
        guard a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { throw Failure.output }
        var maximum: Float = 0, squared = 0.0, norm = 0.0, bits = 0
        for (x, y) in zip(a, b) {
            maximum = max(maximum, abs(x - y)); squared += Double(x - y) * Double(x - y); norm += Double(y) * Double(y)
            if x.bitPattern != y.bitPattern { bits += 1 }
        }
        let halfA = output.asType(.float16).asArray(Float16.self), halfB = expected.asType(.float16).asArray(Float16.self)
        let half = zip(halfA, halfB).filter { $0.bitPattern != $1.bitPattern }.count
        let head = module == "speech_head" ? try ChatterboxQ8FixedFixtureDiagnostic.compare(a, b, stage: "sameInputHead") : nil
        return Row(module: module, kind: kind, policy: policy,
            difference: Difference(count: a.count, maximumAbsoluteError: maximum,
                relativeL2: sqrt(squared / max(norm, 1e-30)), unequalStoredBits: bits, unequalHalfRoundedBits: half),
            directHeadComparison: head)
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func write(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
#endif
