#if os(macOS)
import Foundation
import MLX
import MLXNN

/// A sealed, offline CPU experiment. Never writes an app oracle or selects a
/// renderer profile; every existing gate and artifact stays immutable.
enum ProjectionCounterfactual {
    static let controlsSHA256 = "4894bb8b3b13b32cfa1ec7eb1c16927206dc725adfc134a0e2e7fd459279c1af"
    enum Failure: Error { case identity, fixture, control(String) }
    private struct ArmResult {
        let report: [String: Any]
        let outputs: [String: [Float]]
        let cacheIdentical: Bool
    }
    static func run(_ f: PrimitiveDiagnostic.Files, preregistration: URL, controls: URL,
                    loadCPUModel: () throws -> SpeechDecoder) throws {
        try PrimitiveDiagnostic.identities(f)
        guard try ChatterboxMLXRenderer.digest(preregistration) == CertifiedProjectionStudy.preregistrationSHA256,
            try ChatterboxMLXRenderer.digest(controls) == controlsSHA256 else { throw Failure.identity }
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        var report: [String: Any] = ["diagnostic_only": true, "cpu_only_process": true,
            "production_clearance": false, "completed": false, "arms": []]
        var activeArm = "preparation"
        do {
            try Device.withDefaultDevice(.cpu) {
                let fixtures = try loadArrays(url: f.oracle)
                let cpu93 = try loadArrays(url: f.cpu93), cpu95 = try loadArrays(url: f.cpu95)
                try DiagnosticRoPEFixture.validate(cpu95)
                let budget = CertifiedHalfProjection.Budget()
                var arms: [[String: Any]] = [], baseline: [String: [Float]] = [:]
                for name in ["original", "eagerNative", "certified"] {
                    activeArm = name
                    try write(["state": "running", "arm": name], to: f.output.appendingPathComponent("status.json"))
                    let result = try runArm(name, fixture: fixtures, cpu93: cpu93, cpu95: cpu95,
                        budget: budget, loadCPUModel: loadCPUModel)
                    if name == "original" {
                        guard result.report["all_original_reference_bits_identical"] as? Bool == true,
                            result.cacheIdentical else { throw Failure.control("original baseline") }
                        baseline = result.outputs
                    } else if name == "eagerNative" {
                        let exact = sameOutputs(baseline, result.outputs)
                        guard exact, result.cacheIdentical else { throw Failure.control("eager-native materialization") }
                        report["eager_native_matches_original_all_conditions_bitwise"] = true
                    }
                    var armReport = result.report
                    try budget.check()
                    let file = f.output.appendingPathComponent(name + "-diagnostic-logits.safetensors")
                    let tensors = result.outputs.mapValues { MLXArray($0, [2, 8194]) }
                    try save(arrays: tensors, metadata: ["scope": "diagnostic counterfactual logits; not an app oracle",
                        "arm": name, "old_oracle_sha256": ChatterboxMLXRenderer.DecoderProfile.q8CanonicalHalfV2.oracleSHA256], url: file)
                    armReport["diagnostic_logits_sha256"] = try ChatterboxMLXRenderer.digest(file)
                    try budget.check()
                    arms.append(armReport); report["arms"] = arms
                    try write(report, to: f.output.appendingPathComponent("report.json"))
                    ChatterboxMLXRenderer.trimUnusedMemory()
                }
                try budget.check()
                report["full_model_counterfactual_executed"] = true
                report["old_oracle_unchanged"] = true
                report["preregistration_sha256"] = CertifiedProjectionStudy.preregistrationSHA256
                report["implementation_controls_sha256"] = controlsSHA256
                // The atomic success report is the final commit operation.
                // Status alone never qualifies an experiment as complete.
                try write(["state": "complete", "report_commit_required": true, "production_clearance": false],
                    to: f.output.appendingPathComponent("status.json"))
                try budget.check()
                report["completed"] = true
                try write(report, to: f.output.appendingPathComponent("report.json"))
            }
        } catch {
            // No failed arm's logits are evaluated/accepted or written by this
            // runner. Previously successful controls remain preserved.
            report["completed"] = false
            report["failed_arm"] = activeArm; report["error"] = String(describing: error)
            try? write(report, to: f.output.appendingPathComponent("report.json"))
            try? write(["state": "terminal_failure", "arm": activeArm, "error": String(describing: error)],
                to: f.output.appendingPathComponent("status.json"))
            throw error
        }
    }

    @inline(never)
    private static func runArm(_ name: String, fixture: [String: MLXArray], cpu93: [String: MLXArray],
                               cpu95: [String: MLXArray], budget: CertifiedHalfProjection.Budget,
                               loadCPUModel: () throws -> SpeechDecoder) throws -> ArmResult {
        try budget.check()
        try ChatterboxMLXRenderer.healthy(minimumAvailable: 3 * 1_024 * 1_024 * 1_024)
        let began = Date(), model = try loadCPUModel()
        let state: ProjectionArm?
        if name == "original" { state = nil }
        else {
            guard let mode = ProjectionArm.Mode(rawValue: name) else { throw Failure.fixture }
            let arm = ProjectionArm(mode: mode, budget: budget)
            let modules = try model.leafModules().flattened().compactMap { path, module -> (String, Module)? in
                guard path.hasPrefix("tfmr.layers."), let layer = module as? Linear else { return nil }
                return (path, try OfflineProjectionLinear(layer, name: path, arm: arm))
            }
            guard modules.count == 210 else { throw Failure.fixture }
            model.update(modules: ModuleChildren.unflattened(modules)); state = arm
        }
        var outputs: [String: [Float]] = [:], comparisons: [ChatterboxQ8FixedFixtureDiagnostic.Comparison] = []
        var drift: [[String: Any]] = [], referenceExact = true
        func execute(_ stem: String, condition: String, caches: [KVCache]) throws {
            try budget.check()
            guard let input = fixture[stem + ".input"], let expected = fixture[stem + ".logits"] else { throw Failure.fixture }
            let tag = condition + "." + stem
            let logits: MLXArray
            if let state {
                state.stage = tag
                // Mandatory failure boundary precedes all caller evaluation,
                // comparisons, cache snapshots and output artifact writes.
                logits = try state.evaluate { model.logits(input, cache: caches) }
            } else { logits = model.logits(input, cache: caches); eval(logits); try budget.check() }
            let a = logits.asArray(Float.self), b = expected.asArray(Float.self)
            let comparison = try ChatterboxQ8FixedFixtureDiagnostic.compare(a, b, stage: tag)
            referenceExact = referenceExact && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
            outputs[tag] = a; comparisons.append(comparison)
        }
        for language in ["en", "es"] {
            let cache = (0..<30).map { _ in KVCache() }
            for step in 0...8 {
                let stem = language + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                try execute(stem, condition: "native", caches: cache)
                if language == "es", step == 0 || step == 2 {
                    let offset = step == 0 ? 93 : 95
                    drift.append(try cacheDrift(cache, offset: offset, source: offset == 93 ? cpu93 : cpu95, budget: budget))
                }
            }
        }
        for offset in [93, 95] {
            let source = offset == 93 ? cpu93 : cpu95
            let cache = try (0..<30).map { index -> KVCache in
                try budget.check()
                let stem = offset == 93 ? "es.prefill.layer.\(index)" : "layer.\(index)"
                guard let k = source[stem + ".keys"], let v = source[stem + ".values"] else { throw Failure.fixture }
                return try KVCache.restoringFixedFixture(keys: k, values: v, expectedOffset: offset)
            }
            for step in (offset - 93)..<3 { try execute("es.decode.\(step)", condition: "cpu\(offset)", caches: cache) }
        }
        let cacheExact = drift.allSatisfy { ($0["unequal_half_bits"] as? Int) == 0 }
        var armReport: [String: Any] = ["name": name, "comparisons": try object(comparisons),
            "cache_drift": drift, "all_original_reference_bits_identical": referenceExact,
            "wall_seconds": Date().timeIntervalSince(began), "conditions": outputs.count]
        if let state {
            if let failure = state.failure { throw failure }
            armReport["projection_calls"] = state.completedHelpers
            armReport["accepted_logit_evaluations"] = state.acceptedEvaluations
            armReport["certified_projection_outputs"] = state.certifiedOutputs
            armReport["exact_fallback_outputs"] = state.exactFallbackOutputs
            armReport["boundary_cases"] = try object(state.boundaries)
        }
        guard outputs.count == 22 else { throw Failure.fixture }
        return ArmResult(report: armReport, outputs: outputs, cacheIdentical: cacheExact)
    }

    private static func cacheDrift(_ caches: [KVCache], offset: Int, source: [String: MLXArray],
                                   budget: CertifiedHalfProjection.Budget) throws -> [String: Any] {
        var unequal = 0, total = 0, maximum = 0.0, squared = 0.0, norm = 0.0
        for (index, cache) in caches.enumerated() {
            try budget.check()
            let snapshot = try cache.fixedFixtureSnapshot(expectedOffset: offset)
            let stem = offset == 93 ? "es.prefill.layer.\(index)" : "layer.\(index)"
            for (suffix, actual) in [("keys", snapshot.keys), ("values", snapshot.values)] {
                guard let target = source[stem + "." + suffix] else { throw Failure.fixture }
                let expected = target.asArray(Float16.self)
                guard actual.count == expected.count else { throw Failure.fixture }
                total += actual.count
                for (a, b) in zip(actual, expected) {
                    if a.bitPattern != b.bitPattern { unequal += 1 }
                    let d = Double(a) - Double(b)
                    maximum = max(maximum, abs(d)); squared += d * d; norm += Double(b) * Double(b)
                }
            }
        }
        return ["offset": offset, "count": total, "unequal_half_bits": unequal,
            "maximum_absolute_error": maximum, "relative_l2": sqrt(squared / max(norm, 1e-30))]
    }
    private static func sameOutputs(_ a: [String: [Float]], _ b: [String: [Float]]) -> Bool {
        Set(a.keys) == Set(b.keys) && a.allSatisfy { key, values in
            guard let other = b[key], values.count == other.count else { return false }
            return zip(values, other).allSatisfy { $0.bitPattern == $1.bitPattern }
        }
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func write(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
#endif
