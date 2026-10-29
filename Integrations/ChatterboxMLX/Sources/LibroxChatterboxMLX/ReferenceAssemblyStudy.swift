#if os(macOS)
import Foundation
import MLX
import CryptoKit

enum ReferenceAssemblyInputs {
    static let sha256 = "2d20b5932df08b022cbd95e5713de5f5f1c0b15fcebde04801f42b6a0584baf7"
    static let lengths = ["en-short": 80, "en-boundary": 251, "en-long": 501,
        "es-short": 87, "es-boundary": 252, "es-long": 503]
    struct Case {
        let id: String, length: Int, prefix: [Float], continuations: [[Float]]
        func chunk(start: Int, count: Int) throws -> [Float] {
            guard start >= 0, count > 0, start + count <= length else { throw IndependentReferenceBackbone.Failure.shape }
            return (0..<2).flatMap { lane in
                Array(prefix[((lane * length + start) * 1024)..<((lane * length + start + count) * 1024)])
            }
        }
    }
    static func load(_ file: URL, id: String, budget: CertifiedHalfProjection.Budget) throws -> Case {
        try budget.check()
        guard let length = lengths[id] else { throw IndependentReferenceBackbone.Failure.shape }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: 100_000_000 + 1_073_741_824)
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: 14_114_142), bytes.count == 14_114_141,
            try handle.read(upToCount: 1)?.isEmpty != false,
            SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw IndependentReferenceBackbone.Failure.identity }
        let arrays = try loadArrays(data: bytes, stream: .cpu)
        let expectedNames = Set(lengths.keys.flatMap { [$0 + ".prefix", $0 + ".continuations", $0 + ".text_ids"] })
        guard Set(arrays.keys) == expectedNames else { throw IndependentReferenceBackbone.Failure.shape }
        for (name, count) in lengths {
            guard let p = arrays[name + ".prefix"], p.shape == [2, count, 1024], p.dtype == .float32,
                let c = arrays[name + ".continuations"], c.shape == [8, 2, 1, 1024], c.dtype == .float32,
                let ids = arrays[name + ".text_ids"], ids.shape == [count - 36], ids.dtype == .int32,
                p.asArray(Float.self).allSatisfy(\.isFinite), c.asArray(Float.self).allSatisfy(\.isFinite)
            else { throw IndependentReferenceBackbone.Failure.shape }
            try budget.check()
        }
        let prefix = arrays[id + ".prefix"]!.asArray(Float.self)
        let all = arrays[id + ".continuations"]!.asArray(Float.self)
        let result = Case(id: id, length: length, prefix: prefix,
            continuations: (0..<8).map { Array(all[($0 * 2048)..<(($0 + 1) * 2048)]) })
        try budget.check(); return result
    }
}

/// Stores a full initial cache plus verified append-only deltas. Every stage's
/// full active cache gets an independent hash; no unrecorded prefix mutation is
/// allowed. This retains exact reconstructible bits without copying a long
/// unchanged prefill to SSD another eight times.
final class ReferenceCacheEvidence {
    private var previous: [(keys: [Float16], values: [Float16])]?
    private var previousOffset = 0
    private(set) var stages: [[String: Any]] = []
    private let output: URL, budget: CertifiedHalfProjection.Budget
    init(output: URL, budget: CertifiedHalfProjection.Budget) { self.output = output; self.budget = budget }
    static func hash<T>(_ values: [T]) -> String {
        var hash = SHA256()
        values.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func capture(_ snapshots: [(keys: [Float16], values: [Float16])], offset: Int, stage: String) throws {
        try budget.check()
        guard snapshots.count == 30, offset > previousOffset, offset <= 1536,
            previous == nil || offset == previousOffset + 1 else { throw IndependentReferenceBackbone.Failure.cache }
        var arrays: [String: MLXArray] = [:], hashes: [[String: Any]] = []
        let delta = offset - previousOffset
        for layer in 0..<30 {
            try budget.check()
            let snapshot = snapshots[layer]
            guard snapshot.keys.count == 32 * offset * 64, snapshot.values.count == snapshot.keys.count,
                snapshot.keys.allSatisfy(\.isFinite), snapshot.values.allSatisfy(\.isFinite)
            else { throw IndependentReferenceBackbone.Failure.cache }
            for (name, actual) in [("keys", snapshot.keys), ("values", snapshot.values)] {
                var tail: [Float16] = []; tail.reserveCapacity(32 * delta * 64)
                let old = previous.map { name == "keys" ? $0[layer].keys : $0[layer].values }
                for head in 0..<32 {
                    try budget.check()
                    let start = head * offset * 64
                    if let old {
                        for i in 0..<(previousOffset * 64) {
                            guard actual[start + i].bitPattern == old[head * previousOffset * 64 + i].bitPattern
                            else { throw IndependentReferenceBackbone.Failure.cache }
                        }
                    }
                    tail.append(contentsOf: actual[(start + previousOffset * 64)..<(start + offset * 64)])
                }
                arrays["layer.\(layer).\(name)"] = MLXArray(tail, [2, 16, delta, 64])
                hashes.append(["layer": layer, "kind": name, "active_half_count": actual.count,
                    "active_sha256": Self.hash(actual), "delta_sha256": Self.hash(tail)])
            }
        }
        let file = output.appendingPathComponent("cache-\(stages.count).safetensors")
        let free = try FileManager.default.attributesOfFileSystem(forPath: output.path)[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value >= Int64(32 * delta * 64 * 2 * 60 + 1_073_741_824)
        else { throw IndependentReferenceBackbone.Failure.shape }
        try budget.check()
        try save(arrays: arrays, metadata: ["scope": "Exact reconstructible diagnostic cache; no app oracle"], url: file, stream: .cpu)
        stages.append(["stage": stage, "offset": offset, "delta_rows": delta, "prefix_unchanged": previous != nil,
            "file": file.lastPathComponent, "file_sha256": try ChatterboxMLXRenderer.digest(file), "tensors": hashes])
        try ReferenceAssemblyStudy.write(["completed": false, "cache_stages": stages], output.appendingPathComponent("cache-evidence-index.json"))
        previous = snapshots; previousOffset = offset
        try budget.check()
    }
}

enum ReferenceAssemblyStudy {
    struct Files {
        let weights: URL, rope: URL, sigmoid: URL, inputs: URL, parent: URL, chunk: URL
        let script: URL, python: URL, output: URL
        let regressionControl: URL, caseControl: URL, oldOracle: URL
        let regressionControlSHA256: String, caseControlSHA256: String
        let runtimeMetallibSHA256: String
        let caseID: String, arm: String
    }
    static func run(_ f: Files) throws {
        guard ["reference-full", "reference-chunks"].contains(f.arm),
            !FileManager.default.fileExists(atPath: f.output.path),
            try ChatterboxMLXRenderer.digest(f.parent) == ReferenceHoldoutPreparation.parentSHA256,
            try ChatterboxMLXRenderer.digest(f.chunk) == ReferenceHoldoutPreparation.chunkSHA256
        else { throw IndependentReferenceBackbone.Failure.identity }
        let budget = CertifiedHalfProjection.Budget()
        let oldBinding = try AssemblyControlGate.verify(f.regressionControl, sha256: f.regressionControlSHA256, caseID: "regression", oracle: f.oldOracle, budget: budget)
        let caseBinding = try AssemblyControlGate.verify(f.caseControl, sha256: f.caseControlSHA256, caseID: f.caseID, oracle: nil, budget: budget)
        guard oldBinding["runtime_metallib_sha256"] as? String == f.runtimeMetallibSHA256,
            caseBinding["runtime_metallib_sha256"] as? String == f.runtimeMetallibSHA256
        else { throw IndependentReferenceBackbone.Failure.identity }
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        var report: [String: Any] = ["completed": false, "case": f.caseID, "arm": f.arm,
            "input_vectors_sha256": ReferenceAssemblyInputs.sha256,
            "production_clearance": false, "audio_generated": false, "independent_own_cache": true,
            "consumed_native_controls": [oldBinding, caseBinding], "runtime_metallib_sha256": f.runtimeMetallibSHA256]
        var stage = "preparation"
        do {
            try Device.withDefaultDevice(.cpu) {
                let input = try ReferenceAssemblyInputs.load(f.inputs, id: f.caseID, budget: budget)
                let resolver = try ReferenceExactResolver(script: f.script, python: f.python, directory: f.output, budget: budget)
                let model = try IndependentReferenceBackbone(weights: f.weights, rope: f.rope, sigmoid: f.sigmoid,
                    budget: budget, resolver: resolver)
                let evidence = ReferenceCacheEvidence(output: f.output, budget: budget)
                var outputs: [String: MLXArray] = [:], stages: [[String: Any]] = []
                func record(_ logits: [Float], name: String) throws {
                    try budget.check()
                    guard logits.count == 16388, logits.allSatisfy(\.isFinite) else { throw IndependentReferenceBackbone.Failure.shape }
                    outputs[name] = MLXArray(logits, [2, 8194])
                    let raw = f.output.appendingPathComponent("stage-\(stages.count)-logits.safetensors")
                    try save(arrays: ["logits": outputs[name]!], metadata: ["scope": "Unaccepted per-stage diagnostic evidence"], url: raw, stream: .cpu)
                    let leaders = (0..<2).map { lane in
                        let start = lane * 8194
                        return (0..<8194).max { logits[start + $0] < logits[start + $1] }!
                    }
                    stages.append(["name": name, "logits_sha256": ReferenceCacheEvidence.hash(logits),
                        "raw_file": raw.lastPathComponent, "raw_sha256": try ChatterboxMLXRenderer.digest(raw),
                        "leaders": leaders, "cache_offset": model.offset])
                    report["stages"] = stages
                    try write(report, f.output.appendingPathComponent("report.json"))
                    try evidence.capture(model.snapshot(), offset: model.offset, stage: name)
                    report["cache_evidence"] = evidence.stages
                    try write(report, f.output.appendingPathComponent("report.json"))
                }
                stage = "prefill"
                try write(["state": "running", "stage": stage, "case": f.caseID, "arm": f.arm], f.output.appendingPathComponent("status.json"))
                let chunk = f.arm == "reference-full" ? input.length : 64
                var position = 0, prefill: [Float] = []
                while position < input.length {
                    let count = min(chunk, input.length - position)
                    guard model.offset == position else { throw IndependentReferenceBackbone.Failure.cache }
                    prefill = try model.logits(input.chunk(start: position, count: count), rows: count)
                    position += count
                }
                try record(prefill, name: "prefill")
                for step in 0..<8 {
                    stage = "decode.\(step)"
                    try write(["state": "running", "stage": stage, "case": f.caseID, "arm": f.arm], f.output.appendingPathComponent("status.json"))
                    guard model.offset == input.length + step else { throw IndependentReferenceBackbone.Failure.cache }
                    try record(model.logits(input.continuations[step], rows: 1), name: stage)
                }
                try budget.check()
                let file = f.output.appendingPathComponent("diagnostic-logits.safetensors")
                try save(arrays: outputs, metadata: ["scope": "Independent assembled reference; not an app oracle"], url: file, stream: .cpu)
                report["logits_sha256"] = try ChatterboxMLXRenderer.digest(file)
                report["stages"] = stages; report["cache_evidence"] = evidence.stages
                report["forward_calls"] = model.forwards; report["actual_maximum_position"] = input.length + 7
                report["certified_outputs"] = model.statistics.certified; report["exact128_outputs"] = model.statistics.exact128
                report["bigint_outputs"] = model.statistics.bigint; report["resolver_calls"] = resolver.calls
                report["prefill_rows"] = input.length; report["prefix_chunk_rows"] = chunk
                try budget.check()
                try write(["state": "complete", "report_commit_required": true, "production_clearance": false], f.output.appendingPathComponent("status.json"))
                try budget.check(); report["completed"] = true
                try write(report, f.output.appendingPathComponent("report.json"))
            }
        } catch {
            report["completed"] = false; report["failed_stage"] = stage; report["error"] = String(describing: error)
            try? write(report, f.output.appendingPathComponent("report.json"))
            try? write(["state": "terminal_failure", "stage": stage, "error": String(describing: error)], f.output.appendingPathComponent("status.json"))
            throw error
        }
    }
    static func write(_ object: [String: Any], _ file: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}

enum AssemblyControlGate {
    private struct Receipt: Decodable {
        struct Cache: Decodable, Equatable {
            let layer: Int, offset: Int, capacity: Int
            let keys_sha256: String, values_sha256: String
        }
        struct Condition: Decodable, Equatable { let name: String, logits_sha256: String, cache: [Cache] }
        struct Boundary: Decodable, Equatable {
            let dtype: String, shape: [Int], strides_after_evaluation: [Int], sha256: String
        }
        struct Trace: Decodable { let name: String, boundaries: [String: Boundary] }
        struct Arm: Decodable { let mode: String, conditions: [Condition], trace: [Trace] }
        let completed: Bool, mode: String, `case`: String, conditions: Int
        let input_vectors_sha256: String, all_trace_boundaries_bit_identical: Bool
        let all_original_traced_eager_logits_caches_bit_identical: Bool, old22_bit_identical: Bool
        let raw_sha256: String
        let runtime_metallib_sha256: String
        let arms: [Arm]
    }
    static var boundaryNames: Set<String> {
        var names: Set<String> = ["tfmr.norm.input", "tfmr.norm.output", "speech_head.input", "speech_head.output"]
        for layer in 0..<30 {
            let prefix = "tfmr.layers.\(layer)."
            for name in ["input_layernorm", "post_attention_layernorm"] {
                names.insert(prefix + name + ".input"); names.insert(prefix + name + ".output")
            }
            for name in ["attention_residual", "mlp_residual", "attention.query", "attention.key", "attention.value", "attention.output", "mlp.activated"] {
                names.insert(prefix + name)
            }
            for name in ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj", "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj"] {
                names.insert(prefix + name + ".input"); names.insert(prefix + name + ".output")
            }
        }
        return names
    }
    static func verify(_ file: URL, sha256: String, caseID: String, oracle: URL?,
                       budget: CertifiedHalfProjection.Budget) throws -> [String: Any] {
        try budget.check()
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 16_777_217), data.count <= 16_777_216,
            try handle.read(upToCount: 1)?.isEmpty != false,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw IndependentReferenceBackbone.Failure.identity }
        let report = try JSONDecoder().decode(Receipt.self, from: data)
        let expected = caseID == "regression" ? GPUFactorStudy.conditionKeys : Set(["prefill"] + (0..<8).map { "decode.\($0)" })
        guard report.completed, report.mode == "cpu-original-trace-eager-control", report.case == caseID,
            report.conditions == expected.count, report.input_vectors_sha256 == ReferenceAssemblyInputs.sha256,
            report.all_trace_boundaries_bit_identical, report.all_original_traced_eager_logits_caches_bit_identical,
            report.old22_bit_identical == (caseID == "regression"),
            report.arms.map(\.mode) == ["original", "traced", "eager"]
        else { throw IndependentReferenceBackbone.Failure.identity }
        let rawFile = file.deletingLastPathComponent().appendingPathComponent("control-logits.safetensors")
        let raw = try AssemblyNativeControls.pinnedArrays(rawFile, sha: report.raw_sha256, budget: budget)
        let keys = Set(report.arms.flatMap { arm in expected.map { arm.mode + "." + $0 } })
        guard Set(raw.keys) == keys else { throw IndependentReferenceBackbone.Failure.shape }
        let old: [String: MLXArray]
        if caseID == "regression" {
            guard let oracle else { throw IndependentReferenceBackbone.Failure.identity }
            old = try AssemblyNativeControls.pinnedArrays(oracle,
                sha: "8f7b5d2a6437c23cfa753f0ac25e2f23f296ca32f3e91b98b3f6219b26325b44", budget: budget)
        } else { old = [:] }
        var baseline: [String: Receipt.Condition] = [:], traced: [String: [String: Receipt.Boundary]] = [:]
        for arm in report.arms {
            guard arm.conditions.count == expected.count, Set(arm.conditions.map(\.name)) == expected,
                arm.trace.count == (arm.mode == "original" ? 0 : expected.count),
                arm.mode == "original" || Set(arm.trace.map(\.name)) == expected
            else { throw IndependentReferenceBackbone.Failure.shape }
            for condition in arm.conditions {
                try budget.check()
                guard let values = raw[arm.mode + "." + condition.name], values.dtype == .float32,
                    values.shape == [2, 8194] else { throw IndependentReferenceBackbone.Failure.shape }
                let floats = values.asArray(Float.self)
                guard floats.allSatisfy(\.isFinite), ReferenceCacheEvidence.hash(floats) == condition.logits_sha256,
                    condition.cache.count == 30, condition.cache.map(\.layer) == Array(0..<30),
                    let offset = condition.cache.first?.offset, (1...1536).contains(offset),
                    condition.cache.allSatisfy({ $0.offset == offset && $0.capacity >= offset &&
                        $0.keys_sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil &&
                        $0.values_sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil })
                else { throw IndependentReferenceBackbone.Failure.identity }
                if caseID == "regression" {
                    let key = condition.name.hasPrefix("native.") ? String(condition.name.dropFirst(7)) : String(condition.name.dropFirst(6))
                    guard let target = old[key + ".logits"], target.dtype == .float32, target.shape == [2, 8194],
                        floats.map(\.bitPattern) == target.asArray(Float.self).map(\.bitPattern)
                    else { throw IndependentReferenceBackbone.Failure.identity }
                }
                if arm.mode == "original" { baseline[condition.name] = condition }
                else { guard baseline[condition.name] == condition else { throw IndependentReferenceBackbone.Failure.identity } }
            }
            for trace in arm.trace {
                try budget.check()
                guard Set(trace.boundaries.keys) == boundaryNames, trace.boundaries.values.allSatisfy({
                    ["F16", "F32"].contains($0.dtype) && !$0.shape.isEmpty && $0.shape.allSatisfy({ $0 > 0 && $0 <= 8194 }) &&
                    $0.shape.count == $0.strides_after_evaluation.count &&
                    $0.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                }) else { throw IndependentReferenceBackbone.Failure.shape }
                if arm.mode == "traced" { traced[trace.name] = trace.boundaries }
                else { guard traced[trace.name] == trace.boundaries else { throw IndependentReferenceBackbone.Failure.identity } }
            }
        }
        try budget.check()
        return ["case": caseID, "receipt_sha256": sha256, "raw_sha256": report.raw_sha256,
            "conditions": expected.count, "boundaries_per_stage": boundaryNames.count,
            "runtime_metallib_sha256": report.runtime_metallib_sha256]
    }
}
#endif
