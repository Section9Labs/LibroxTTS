#if os(macOS)
import Foundation
import MLX
import MLXNN
import CryptoKit

/// Original -> deferred observation -> eager observation. The observers never
/// replace an operand, its dtype/strides, or an arithmetic operation.
enum AssemblyNativeControls {
    struct Files {
        let inputs: URL, oracle: URL, cpu93: URL, cpu95: URL, output: URL
        let caseID: String
    }
    static func run(_ f: Files, loadModel: () throws -> SpeechDecoder) throws {
        guard f.caseID == "regression" || ReferenceAssemblyInputs.lengths[f.caseID] != nil,
            !FileManager.default.fileExists(atPath: f.output.path) else { throw IndependentReferenceBackbone.Failure.identity }
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        var report: [String: Any] = ["completed": false, "case": f.caseID,
            "mode": "cpu-original-trace-eager-control", "production_clearance": false,
            "input_vectors_sha256": ReferenceAssemblyInputs.sha256]
        var stage = "preparation"
        do {
            try Device.withDefaultDevice(.cpu) {
                let budget = CertifiedHalfProjection.Budget()
                let fixture: [String: MLXArray], cpu93: [String: MLXArray], cpu95: [String: MLXArray]
                let input: ReferenceAssemblyInputs.Case?
                if f.caseID == "regression" {
                    fixture = try pinnedArrays(f.oracle, sha: "8f7b5d2a6437c23cfa753f0ac25e2f23f296ca32f3e91b98b3f6219b26325b44", budget: budget)
                    cpu93 = try pinnedArrays(f.cpu93, sha: "59e0cbdab848feb2977359ac8a8e90e0bd0dc54a0fafa312f86fd5f7c7d01f6f", budget: budget)
                    cpu95 = try pinnedArrays(f.cpu95, sha: "e3155186f9f00f2c1c8409c35f2532bd6ea29c81798256bac68b61f383adc125", budget: budget)
                    input = nil
                } else {
                    input = try ReferenceAssemblyInputs.load(f.inputs, id: f.caseID, budget: budget)
                    fixture = [:]; cpu93 = [:]; cpu95 = [:]
                }
                var baseline: [String: [String: Any]] = [:], traced: [String: [String: Any]] = [:]
                var armReports: [[String: Any]] = [], raw: [String: MLXArray] = [:]
                var stageFiles: [[String: Any]] = []
                for mode in ["original", "traced", "eager"] {
                    try budget.check()
                    let model = try loadModel()
                    let recorder = AssemblyBoundaryRecorder(eager: mode == "eager", budget: budget)
                    if mode != "original" {
                        model.transformer.diagnosticObserveBoundaries(recorder.observe)
                        let modules: [(String, Module)] = model.leafModules().flattened().compactMap { name, module in
                            guard let linear = module as? Linear else { return nil }
                            return (name, AssemblyObservedLinear(linear, name: name, recorder: recorder))
                        }
                        guard modules.count == 211 else { throw IndependentReferenceBackbone.Failure.shape }
                        model.update(modules: ModuleChildren.unflattened(modules))
                    }
                    var entries: [[String: Any]] = [], traceEntries: [[String: Any]] = []
                    func execute(_ name: String, _ embeddings: MLXArray, cache: [KVCache], expected: MLXArray? = nil) throws {
                        stage = mode + "." + name
                        try ReferenceAssemblyStudy.write(["state": "running", "stage": stage, "case": f.caseID], f.output.appendingPathComponent("status.json"))
                        try recorder.begin()
                        let logits = model.logits(embeddings, cache: cache)
                        let observations = try recorder.finish(logits)
                        let actual = logits.asArray(Float.self)
                        guard actual.count == 16388, actual.allSatisfy(\.isFinite) else { throw IndependentReferenceBackbone.Failure.shape }
                        var stageRaw: [String: MLXArray] = ["actual": MLXArray(actual, [2, 8194])]
                        var oracleMatches = true
                        if let expected {
                            guard expected.dtype == .float32, expected.shape == [2, 8194] else { throw IndependentReferenceBackbone.Failure.shape }
                            let wanted = expected.asArray(Float.self)
                            oracleMatches = wanted.map(\.bitPattern) == actual.map(\.bitPattern)
                            stageRaw["expected"] = MLXArray(wanted, [2, 8194])
                        }
                        let rawFile = f.output.appendingPathComponent("stage-\(stage)-logits.safetensors")
                        try save(arrays: stageRaw, metadata: ["scope": "Unaccepted control outcome, including failed comparisons"], url: rawFile, stream: .cpu)
                        stageFiles.append(["stage": stage, "raw_file": rawFile.lastPathComponent,
                            "raw_sha256": try ChatterboxMLXRenderer.digest(rawFile), "oracle_bits_identical": oracleMatches])
                        report["stage_files"] = stageFiles; report["active_stage"] = stage
                        try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
                        var cacheRows: [[String: Any]] = []
                        guard cache.count == 30, let offset = cache.first?.offset,
                            cache.allSatisfy({ $0.offset == offset }) else { throw IndependentReferenceBackbone.Failure.cache }
                        for (i, c) in cache.enumerated() {
                            try budget.check()
                            let snapshot = try c.diagnosticSnapshot(expectedOffset: offset)
                            cacheRows.append(["layer": i, "offset": offset, "capacity": snapshot.capacity,
                                "keys_sha256": ReferenceCacheEvidence.hash(snapshot.keys),
                                "values_sha256": ReferenceCacheEvidence.hash(snapshot.values)])
                        }
                        let result: [String: Any] = ["name": name, "logits_sha256": ReferenceCacheEvidence.hash(actual), "cache": cacheRows]
                        entries.append(result); raw[mode + "." + name] = MLXArray(actual, [2, 8194])
                        let trace: [String: Any] = ["name": name, "boundaries": observations]
                        var resultMatches = true, traceMatches = true
                        if mode == "original" { baseline[name] = result }
                        else {
                            resultMatches = try baseline[name].map { try same(result, $0) } ?? false
                            traceEntries.append(trace)
                            if mode == "traced" { traced[name] = trace }
                            else { traceMatches = try traced[name].map { try same(trace, $0) } ?? false }
                        }
                        var evidence: [String: Any] = ["stage": stage, "actual": result, "trace": trace,
                            "original_logits_cache_match": resultMatches, "trace_eager_match": traceMatches,
                            "oracle_bits_identical": oracleMatches]
                        if let wanted = baseline[name] { evidence["expected_original"] = wanted }
                        if let wanted = traced[name] { evidence["expected_trace"] = wanted }
                        let evidenceFile = f.output.appendingPathComponent("stage-\(stage)-evidence.json")
                        try ReferenceAssemblyStudy.write(evidence, evidenceFile)
                        stageFiles[stageFiles.count - 1]["evidence_file"] = evidenceFile.lastPathComponent
                        stageFiles[stageFiles.count - 1]["evidence_sha256"] = try ChatterboxMLXRenderer.digest(evidenceFile)
                        report["stage_files"] = stageFiles
                        try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
                        guard oracleMatches, resultMatches, traceMatches,
                            mode == "original" || observations.count == AssemblyControlGate.boundaryNames.count
                        else { throw IndependentReferenceBackbone.Failure.identity }
                        try budget.check()
                    }
                    if let input {
                        let cache = (0..<30).map { _ in KVCache() }
                        try execute("prefill", MLXArray(input.prefix, [2, input.length, 1024]), cache: cache)
                        for step in 0..<8 { try execute("decode.\(step)", MLXArray(input.continuations[step], [2, 1, 1024]), cache: cache) }
                    } else {
                        for language in ["en", "es"] {
                            let cache = (0..<30).map { _ in KVCache() }
                            for step in 0...8 {
                                let key = language + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                                guard let x = fixture[key + ".input"], let y = fixture[key + ".logits"] else { throw IndependentReferenceBackbone.Failure.shape }
                                try execute("native." + key, x, cache: cache, expected: y)
                            }
                        }
                        for offset in [93, 95] {
                            let source = offset == 93 ? cpu93 : cpu95
                            let cache = try (0..<30).map { index -> KVCache in
                                let prefix = offset == 93 ? "es.prefill.layer.\(index)" : "layer.\(index)"
                                guard let k = source[prefix + ".keys"], let v = source[prefix + ".values"] else { throw IndependentReferenceBackbone.Failure.shape }
                                return try KVCache.restoringFixedFixture(keys: k, values: v, expectedOffset: offset)
                            }
                            for step in (offset - 93)..<3 {
                                let key = "es.decode.\(step)"
                                guard let x = fixture[key + ".input"], let y = fixture[key + ".logits"] else { throw IndependentReferenceBackbone.Failure.shape }
                                try execute("cpu\(offset)." + key, x, cache: cache, expected: y)
                            }
                        }
                    }
                    let count = input == nil ? 22 : 9
                    guard entries.count == count, mode == "original" || traceEntries.count == count else { throw IndependentReferenceBackbone.Failure.shape }
                    armReports.append(["mode": mode, "conditions": entries, "trace": traceEntries])
                    report["arms"] = armReports
                    try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
                    try budget.check()
                    model.transformer.diagnosticObserveBoundaries(nil)
                    ChatterboxMLXRenderer.trimUnusedMemory()
                }
                report["arms"] = armReports; report["conditions"] = baseline.count
                report["all_trace_boundaries_bit_identical"] = true
                report["all_original_traced_eager_logits_caches_bit_identical"] = true
                report["old22_bit_identical"] = f.caseID == "regression"
                try budget.check()
                let file = f.output.appendingPathComponent("control-logits.safetensors")
                try save(arrays: raw, metadata: ["scope": "Original/eager diagnostic controls only"], url: file, stream: .cpu)
                report["raw_sha256"] = try ChatterboxMLXRenderer.digest(file)
                try ReferenceAssemblyStudy.write(["state": "complete", "report_commit_required": true], f.output.appendingPathComponent("status.json"))
                try budget.check(); report["completed"] = true
                try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
            }
        } catch {
            report["completed"] = false; report["failed_stage"] = stage; report["error"] = String(describing: error)
            try? ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
            try? ReferenceAssemblyStudy.write(["state": "terminal_failure", "stage": stage], f.output.appendingPathComponent("status.json"))
            throw error
        }
    }
    private static func same(_ a: [String: Any], _ b: [String: Any]) throws -> Bool {
        try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
    }
    static func pinnedArrays(_ file: URL, sha: String, budget: CertifiedHalfProjection.Budget) throws -> [String: MLXArray] {
        try budget.check()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...134_217_728).contains(size) else { throw IndependentReferenceBackbone.Failure.shape }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: size * 3 + 1_073_741_824)
        let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
        guard let data = try h.read(upToCount: size + 1), data.count == size,
            try h.read(upToCount: 1)?.isEmpty != false,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha
        else { throw IndependentReferenceBackbone.Failure.identity }
        try budget.check(); return try loadArrays(data: data, stream: .cpu)
    }
}

private final class AssemblyBoundaryRecorder {
    private let eager: Bool, budget: CertifiedHalfProjection.Budget
    private var arrays: [String: MLXArray] = [:], hashes: [String: Any] = [:], failure: Error?
    init(eager: Bool, budget: CertifiedHalfProjection.Budget) { self.eager = eager; self.budget = budget }
    func begin() throws {
        if let failure { throw failure }
        arrays.removeAll(); hashes.removeAll(); try budget.check()
    }
    func observe(_ name: String, _ array: MLXArray) {
        guard failure == nil else { return }
        do {
            try budget.check()
            guard arrays[name] == nil, hashes[name] == nil else { throw IndependentReferenceBackbone.Failure.shape }
            if eager { hashes[name] = try fingerprint(array) }
            else { arrays[name] = array }
        } catch { failure = error }
    }
    func finish(_ logits: MLXArray) throws -> [String: Any] {
        if let failure { throw failure }
        try budget.check(); eval(logits); try budget.check()
        for (name, array) in arrays { hashes[name] = try fingerprint(array) }
        arrays.removeAll()
        return hashes
    }
    private func fingerprint(_ array: MLXArray) throws -> [String: Any] {
        try budget.check()
        guard [.float16, .float32].contains(array.dtype), array.size > 0,
            all(isFinite(array)).item(Bool.self) else { throw IndependentReferenceBackbone.Failure.nonfinite }
        let strides = array.asData(access: .noCopy).strides
        let data = array.asData(access: .copy).data
        try budget.check()
        return ["dtype": array.dtype == .float16 ? "F16" : "F32", "shape": array.shape,
            "strides_after_evaluation": strides,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
}

private final class AssemblyObservedLinear: Linear {
    private let name: String, recorder: AssemblyBoundaryRecorder
    init(_ original: Linear, name: String, recorder: AssemblyBoundaryRecorder) {
        self.name = name; self.recorder = recorder
        super.init(weight: original.weight, bias: original.bias)
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        recorder.observe(name + ".input", x)
        let y = super.callAsFunction(x)
        recorder.observe(name + ".output", y)
        return y
    }
}
#endif
