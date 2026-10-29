#if os(macOS)
import Foundation
import MLX

/// Independent targets for a NEW, explicitly versioned profile. Old fixture
/// inputs are consumed verbatim; their old logit targets are never substituted
/// into the evaluator, and no native cache or GPU output enters this trajectory.
enum SemanticStartupReference {
    static let registrationSHA256 = "e069c244913c1128e46c13d6f504d108313bf31500b347107a27a537dfdfed8d"
    static let inputSHA256 = "8f7b5d2a6437c23cfa753f0ac25e2f23f296ca32f3e91b98b3f6219b26325b44"
    static let stems = ["en", "es"].flatMap { l in [l + ".prefill"] + (0..<8).map { l + ".decode.\($0)" } }
    static func inputs(_ file: URL, budget: CertifiedHalfProjection.Budget) throws -> [String: MLXArray] {
        let arrays = try AssemblyNativeControls.pinnedArrays(file, sha: inputSHA256, budget: budget)
        guard Set(arrays.keys) == Set(stems.flatMap { [$0 + ".input", $0 + ".logits"] })
        else { throw IndependentReferenceBackbone.Failure.shape }
        for stem in stems {
            guard let x = arrays[stem + ".input"], x.dtype == .float32, x.ndim == 3,
                x.dim(0) == 2, x.dim(2) == 1024,
                stem.hasSuffix("prefill") ? (1...512).contains(x.dim(1)) : x.dim(1) == 1,
                x.asArray(Float.self).allSatisfy(\.isFinite)
            else { throw IndependentReferenceBackbone.Failure.shape }
            try budget.check()
        }
        return arrays.filter { $0.key.hasSuffix(".input") }
    }
    static func run(weights: URL, oldInputs: URL, rope: URL, sigmoid: URL, script: URL,
                    python: URL, registration: URL, runtimeSHA256: String, output: URL) throws {
        guard !FileManager.default.fileExists(atPath: output.path),
            try ChatterboxMLXRenderer.digest(registration) == registrationSHA256
        else { throw IndependentReferenceBackbone.Failure.identity }
        let budget = CertifiedHalfProjection.Budget()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var report: [String: Any] = ["completed": false, "scope": "independent-semantic-startup-reference-v01",
            "original_input_source_sha256": inputSHA256, "registration_sha256": registrationSHA256,
            "runtime_metallib_sha256": runtimeSHA256, "gpu_targets_or_injected_caches": false,
            "audio_or_phone_clearance": false, "old_references_unchanged": true]
        var currentStage = "preparation"
        do {
            try Device.withDefaultDevice(.cpu) {
                let source = try inputs(oldInputs, budget: budget)
                let resolver = try ReferenceExactResolver(script: script, python: python, directory: output, budget: budget)
                var arrays = source, stages: [[String: Any]] = []
                for language in ["en", "es"] {
                    let model = try IndependentReferenceBackbone(weights: weights, rope: rope, sigmoid: sigmoid,
                        budget: budget, resolver: resolver)
                    let dir = output.appendingPathComponent(language)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                    let cache = ReferenceCacheEvidence(output: dir, budget: budget)
                    for stem in stems.filter({ $0.hasPrefix(language + ".") }) {
                        currentStage = stem
                        try budget.check()
                        let input = source[stem + ".input"]!
                        let result = try model.logits(input.asArray(Float.self), rows: input.dim(1))
                        guard result.count == 16388, result.allSatisfy(\.isFinite) else { throw IndependentReferenceBackbone.Failure.nonfinite }
                        arrays[stem + ".logits"] = MLXArray(result, [2, 8194])
                        let stageFile = output.appendingPathComponent(stem + ".safetensors")
                        try save(arrays: ["input": input, "logits": arrays[stem + ".logits"]!],
                            metadata: ["scope": "Independent stage evidence; pending complete reference"], url: stageFile, stream: .cpu)
                        let stageSHA = try ChatterboxMLXRenderer.digest(stageFile)
                        stages.append(["stage": stem, "input_sha256": ReferenceCacheEvidence.hash(input.asArray(Float.self)),
                            "logits_sha256": ReferenceCacheEvidence.hash(result), "cache_offset": model.offset, "raw_file": stageFile.lastPathComponent, "raw_sha256": stageSHA,
                            "leaders": (0..<2).map { l in (0..<8194).max { result[l * 8194 + $0] < result[l * 8194 + $1] }! }])
                        report["stages"] = stages
                        try ReferenceAssemblyStudy.write(report, output.appendingPathComponent("report.json"))
                        try cache.capture(model.snapshot(), offset: model.offset, stage: stem)
                    }
                    report[language + "_cache_evidence"] = cache.stages
                    report[language + "_certified"] = model.statistics.certified
                    report[language + "_exact128"] = model.statistics.exact128
                    report[language + "_bigint"] = model.statistics.bigint
                }
                try budget.check()
                let file = output.appendingPathComponent("semantic-startup-reference-v01.safetensors")
                try save(arrays: arrays, metadata: ["scope": "Independent semantic reference v01; separate from old V1/V2 oracle"], url: file, stream: .cpu)
                report["output_sha256"] = try ChatterboxMLXRenderer.digest(file)
                report["rope_sha256"] = try ChatterboxMLXRenderer.digest(rope)
                report["weights_sha256"] = try ChatterboxMLXRenderer.digest(weights)
                report["stage_count"] = stages.count; report["resolver_calls"] = resolver.calls
                try budget.check(); report["completed"] = true
                try ReferenceAssemblyStudy.write(report, output.appendingPathComponent("report.json"))
            }
        } catch {
            report["completed"] = false; report["failed_stage"] = currentStage; report["error"] = String(describing: error)
            try? ReferenceAssemblyStudy.write(report, output.appendingPathComponent("report.json"))
            throw error
        }
    }
}
#endif
