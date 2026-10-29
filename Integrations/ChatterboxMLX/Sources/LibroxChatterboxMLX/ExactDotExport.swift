#if os(macOS)
import Foundation
import MLX
import MLXNN

/// Exports only the predetermined public-fixture samples. Backend calls retain
/// their original full shapes; row selection happens after materialization.
enum ExactDotExport {
    static let preregistrationSHA256 = "78989cdfc90d052a8b196208c24b94138985118d076d59811480ca9100c5a059"
    static let cpuArtifactSHA256 = "4e7888d2af62f91037b82ad4ea24b44c3f5475305eafb5ff813fb788d87d28b7"
    enum Failure: Error { case identity, fixture, output }

    static func rows(_ n: Int) -> [Int32] {
        precondition(n >= 32)
        return (0..<32).map { Int32($0 * (n - 1) / 31) }
    }
    private static func snapshot(_ a: MLXArray) throws -> MLXArray {
        guard a.dtype == .float16, all(isFinite(a)).item(Bool.self) else { throw Failure.output }
        return MLXArray(a.asArray(Float16.self), a.shape)
    }
    private static func selected(_ a: MLXArray, n: Int, indices: MLXArray) throws -> MLXArray {
        guard a.shape == [2, 1, n], a.dtype == .float16 else { throw Failure.output }
        eval(a)
        return try snapshot(a.reshaped(2, n)[0..., indices])
    }
    private static func check(_ f: PrimitiveDiagnostic.Files, preregistration: URL) throws {
        try PrimitiveDiagnostic.identities(f)
        guard try ChatterboxMLXRenderer.digest(f.primitives) == PrimitiveDiagnostic.fixtureSHA256,
            try ChatterboxMLXRenderer.digest(preregistration) == preregistrationSHA256
        else { throw Failure.identity }
    }

    static func cpu(_ f: PrimitiveDiagnostic.Files, preregistration: URL,
                    loadCPUModel: () throws -> SpeechDecoder) throws {
        try check(f, preregistration: preregistration)
        let began = Date()
        try Device.withDefaultDevice(.cpu) {
            let model = try loadCPUModel()
            let source = try loadArrays(url: f.primitives)
            try PrimitiveDiagnostic.validate(source, model: model)
            var arrays: [String: MLXArray] = [:]
            var matrices = 0, exactCount = 0
            for (name, module) in model.leafModules().flattened().sorted(by: { $0.0 < $1.0 }) {
                guard name.hasPrefix("tfmr.layers."), let layer = module as? Linear else { continue }
                try ChatterboxMLXRenderer.healthy()
                let (n, k) = layer.shape
                guard let input = source[name + ".input"], let expected = source[name + ".output"],
                    input.shape == [2, 1, k], layer.weight.dtype == .float16 else { throw Failure.fixture }
                let native = layer(input)
                let fp32 = matmul(input.asType(.float32), layer.weight.asType(.float32).T).asType(.float16)
                eval(native, fp32)
                let a = native.asArray(Float16.self), b = expected.asArray(Float16.self)
                guard a.count == b.count, zip(a, b).allSatisfy({ $0.bitPattern == $1.bitPattern }) else { throw Failure.output }
                exactCount += a.count
                let ids = rows(n), indices = MLXArray(ids)
                arrays[name + ".row_ids"] = indices
                arrays[name + ".input"] = try snapshot(input)
                arrays[name + ".weights"] = try snapshot(layer.weight[indices, 0...])
                arrays[name + ".cpu_half"] = try selected(native, n: n, indices: indices)
                arrays[name + ".cpu_f32"] = try selected(fp32, n: n, indices: indices)
                matrices += 1
            }
            guard matrices == 210, arrays.count == 1050, exactCount == 798_720 else { throw Failure.output }
            try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
            let file = f.output.appendingPathComponent("operands.safetensors")
            try save(arrays: arrays, metadata: ["scope": "preregistered public FP16 exact-dot sample only",
                "source_primitive_sha256": PrimitiveDiagnostic.fixtureSHA256,
                "preregistration_sha256": preregistrationSHA256,
                "cpu_full_shape_half_outputs_bit_identical": String(exactCount)], url: file)
            try write(["completed": true, "cpu_only_process": true, "matrices": matrices,
                "scalar_samples": 13_440, "cpu_full_shape_half_outputs_bit_identical": exactCount,
                "artifact_sha256": try ChatterboxMLXRenderer.digest(file),
                "preregistration_sha256": preregistrationSHA256,
                "wall_seconds": Date().timeIntervalSince(began)], to: f.output.appendingPathComponent("report.json"))
        }
    }

    static func gpu(_ f: PrimitiveDiagnostic.Files, preregistration: URL, cpuArtifact: URL) throws {
        try check(f, preregistration: preregistration)
        guard try ChatterboxMLXRenderer.digest(cpuArtifact) == cpuArtifactSHA256 else { throw Failure.identity }
        let began = Date()
        try Device.withDefaultDevice(.gpu) {
            let model = try Q8DecoderWeights.load(from: f.weights, canonicalHalf: true)
            let source = try loadArrays(url: cpuArtifact)
            let modules = model.leafModules().flattened().filter { $0.1 is CanonicalQ8Linear }.sorted { $0.0 < $1.0 }
            guard modules.count == 210 else { throw Failure.fixture }
            var required = Set<String>(), arrays: [String: MLXArray] = [:]
            var checkedWeights = 0
            for (name, module) in modules {
                try ChatterboxMLXRenderer.healthy()
                guard let layer = module as? CanonicalQ8Linear else { throw Failure.fixture }
                let (n, k) = layer.shape
                let ids = rows(n), indices = MLXArray(ids)
                for (suffix, shape, dtype) in [("row_ids", [32], DType.int32), ("input", [2, 1, k], .float16),
                    ("weights", [32, k], .float16), ("cpu_half", [2, 32], .float16), ("cpu_f32", [2, 32], .float16)] {
                    let key = name + "." + suffix; required.insert(key)
                    guard let a = source[key], a.shape == shape, a.dtype == dtype,
                        all(isFinite(a)).item(Bool.self) else { throw Failure.fixture }
                }
                guard source[name + ".row_ids"]!.asArray(Int32.self) == ids else { throw Failure.fixture }
                let input = source[name + ".input"]!
                let dense = layer.reconstructedWeights(); eval(dense)
                let actual = dense[indices, 0...].asArray(Float16.self)
                let expected = source[name + ".weights"]!.asArray(Float16.self)
                guard actual.count == expected.count, zip(actual, expected).allSatisfy({ $0.bitPattern == $1.bitPattern })
                else { throw Failure.output }
                checkedWeights += actual.count
                // Keep N and K intact through every backend call.
                arrays[name + ".gpu_packed"] = try selected(layer(input), n: n, indices: indices)
                arrays[name + ".gpu_half"] = try selected(matmul(input, dense.T), n: n, indices: indices)
                arrays[name + ".gpu_f32"] = try selected(
                    matmul(input.asType(.float32), dense.asType(.float32).T).asType(.float16), n: n, indices: indices)
            }
            guard Set(source.keys) == required, arrays.count == 630 else { throw Failure.fixture }
            try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
            let file = f.output.appendingPathComponent("paired-outputs.safetensors")
            try save(arrays: arrays, metadata: ["scope": "preregistered full-shape GPU projection outputs only",
                "cpu_artifact_sha256": cpuArtifactSHA256, "preregistration_sha256": preregistrationSHA256], url: file)
            try write(["completed": true, "gpu_only_process": true, "matrices": modules.count,
                "scalar_samples": 13_440, "sampled_weight_bits_verified": checkedWeights,
                "artifact_sha256": try ChatterboxMLXRenderer.digest(file),
                "cpu_artifact_sha256": cpuArtifactSHA256,
                "wall_seconds": Date().timeIntervalSince(began)], to: f.output.appendingPathComponent("report.json"))
        }
    }
    private static func write(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
#endif
