#if os(macOS)
import Foundation
import CryptoKit
import MLX

/// One fixed, preregistered policy per fresh process. A diagnostic result never
/// creates a renderer, clears a failed profile, or substitutes an app oracle.
enum AssembledGPUCandidate {
    static let preregistrationSHA256 = "4d4868de336c5837c911302fc41ee562a1d4ff6d5704d0214f96bee39a6bcf38"
    struct Files {
        let weights: URL, rope: URL, inputs: URL, output: URL, preregistration: URL
        let programReport: URL, referenceReport: URL, pairReport: URL, qualificationSeal: URL
        let programSHA256: String, referenceSHA256: String, pairSHA256: String, qualificationSHA256: String
        let runtimeSHA256: String, caseID: String
    }
    static func run(_ f: Files) throws {
        let budget = CertifiedHalfProjection.Budget()
        guard !FileManager.default.fileExists(atPath: f.output.path),
            try ChatterboxMLXRenderer.digest(f.preregistration) == preregistrationSHA256,
            let length = ReferenceAssemblyInputs.lengths[f.caseID]
        else { throw IndependentReferenceBackbone.Failure.identity }
        let program = try pinnedJSON(f.programReport, sha: f.programSHA256, budget: budget)
        let reference = try pinnedJSON(f.referenceReport, sha: f.referenceSHA256, budget: budget)
        let pair = try pinnedJSON(f.pairReport, sha: f.pairSHA256, budget: budget)
        let seal = try pinnedJSON(f.qualificationSeal, sha: f.qualificationSHA256, budget: budget)
        guard seal["completed"] as? Bool == true, seal["schema"] as? Int == 1,
            seal["scope"] as? String == "assembled-reference-artifact-qualification",
            seal["program_report_sha256"] as? String == f.programSHA256,
            seal["input_vectors_sha256"] as? String == ReferenceAssemblyInputs.sha256,
            seal["runtime_metallib_sha256"] as? String == f.runtimeSHA256,
            seal["full_logit_comparisons"] as? Int == 54, seal["gpu_candidate_comparisons"] as? Int == 0,
            let sealCases = seal["cases"] as? [[String: Any]], sealCases.count == 6,
            Set(sealCases.compactMap({ $0["case"] as? String })) == Set(ReferenceAssemblyInputs.lengths.keys),
            sealCases.allSatisfy({ row in
                guard let id = row["case"] as? String else { return false }
                return row["prefix_length"] as? Int == ReferenceAssemblyInputs.lengths[id] &&
                    row["verified_logits"] as? Int == 9 && row["verified_cache_stages"] as? Int == 9
            }), let selectedSeal = sealCases.first(where: { $0["case"] as? String == f.caseID }),
            selectedSeal["full_reference_report_sha256"] as? String == f.referenceSHA256,
            selectedSeal["pair_report_sha256"] as? String == f.pairSHA256
        else { throw IndependentReferenceBackbone.Failure.identity }
        let expectedFinished = Set(ReferenceAssemblyInputs.lengths.keys.flatMap { name in
            ["native-controls", "reference-full", "reference-chunks"].map { name + "|" + $0 }
        })
        guard program["completed"] as? Bool == true, program["reference_cases"] as? Int == 6,
            program["full_chunk_comparisons"] as? Int == 54, program["gpu_candidate_comparisons"] as? Int == 0,
            let finished = program["finished"] as? [[String: Any]], finished.count == 18,
            Set(finished.compactMap { entry -> String? in
                guard let name = entry["case"] as? String, let stage = entry["stage"] as? String else { return nil }
                return name + "|" + stage
            }) == expectedFinished,
            finished.contains(where: { $0["case"] as? String == f.caseID && $0["stage"] as? String == "reference-full" &&
                $0["report_sha256"] as? String == f.referenceSHA256 }),
            finished.contains(where: { $0["case"] as? String == f.caseID && $0["stage"] as? String == "reference-chunks" &&
                $0["report_sha256"] as? String == selectedSeal["chunk_reference_report_sha256"] as? String }),
            reference["completed"] as? Bool == true, reference["case"] as? String == f.caseID,
            reference["arm"] as? String == "reference-full", reference["input_vectors_sha256"] as? String == ReferenceAssemblyInputs.sha256,
            reference["runtime_metallib_sha256"] as? String == f.runtimeSHA256,
            reference["prefill_rows"] as? Int == length, reference["prefix_chunk_rows"] as? Int == length,
            reference["forward_calls"] as? Int == 9, reference["actual_maximum_position"] as? Int == length + 7,
            pair["completed"] as? Bool == true, pair["case"] as? String == f.caseID,
            pair["full_chunk_logits_bit_identical"] as? Bool == true,
            pair["all_active_cache_bits_reconstructed_and_identical"] as? Bool == true,
            pair["logits_compared"] as? Int == 9, pair["cache_stages"] as? Int == 9,
            pair["maximum_offset"] as? Int == length + 8,
            f.pairReport.deletingLastPathComponent().standardizedFileURL == f.programReport.deletingLastPathComponent().standardizedFileURL,
            f.pairReport.lastPathComponent == f.caseID + "-full-chunk-comparison.json",
            let rawSHA = reference["logits_sha256"] as? String,
            selectedSeal["reference_logits_sha256"] as? String == rawSHA,
            let stages = reference["stages"] as? [[String: Any]], stages.count == 9
        else { throw IndependentReferenceBackbone.Failure.identity }
        let expectedNames = ["prefill"] + (0..<8).map { "decode.\($0)" }
        guard stages.compactMap({ $0["name"] as? String }) == expectedNames,
            stages.enumerated().allSatisfy({ $0.element["cache_offset"] as? Int == length + $0.offset })
        else { throw IndependentReferenceBackbone.Failure.shape }
        let targets = try AssemblyNativeControls.pinnedArrays(f.referenceReport.deletingLastPathComponent()
            .appendingPathComponent("diagnostic-logits.safetensors"), sha: rawSHA, budget: budget)
        guard Set(targets.keys) == Set(expectedNames) else { throw IndependentReferenceBackbone.Failure.shape }
        for stage in stages {
            guard let name = stage["name"] as? String, let target = targets[name], target.dtype == .float32,
                target.shape == [2, 8194], ReferenceCacheEvidence.hash(target.asArray(Float.self)) == stage["logits_sha256"] as? String
            else { throw IndependentReferenceBackbone.Failure.identity }
        }
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        var report: [String: Any] = ["completed": false, "case": f.caseID, "gpu_only_model_forward": true,
            "policy": "canonicalQ8Decode-nativePrefill-independentHalfRoPE-v01", "production_clearance": false,
            "audio_generated": false, "decoder_only_not_full_audio_rtf": true,
            "runtime_metallib_sha256": f.runtimeSHA256, "input_vectors_sha256": ReferenceAssemblyInputs.sha256,
            "preregistration_sha256": preregistrationSHA256,
            "qualification_program_sha256": f.programSHA256, "reference_report_sha256": f.referenceSHA256,
            "qualification_seal_sha256": f.qualificationSHA256,
            "full_chunk_pair_sha256": f.pairSHA256, "reference_logits_sha256": rawSHA]
        var stage = "preparation"
        do {
            // CPU activity above only decoded stored data. No CPU model forward
            // or compiled CPU SiLU has occurred in this fresh candidate process.
            try Device.withDefaultDevice(.gpu) {
                let input = try ReferenceAssemblyInputs.load(f.inputs, id: f.caseID, budget: budget)
                let table = try ReferencePinnedBytes.load(f.rope, count: 196736,
                    sha256: "1d58a8abbe8e7f9c668cbc3d3b53bee8563e43f7cdb4cb8b758100f7ec664ca9", budget: budget)
                func halves(_ start: Int) -> [Float16] {
                    table.withUnsafeBytes { p in (0..<49152).map {
                        Float16(bitPattern: UInt16(littleEndian: p.loadUnaligned(fromByteOffset: start + $0 * 2, as: UInt16.self)))
                    } }
                }
                let rotation = DiagnosticHalfRoPE(cosines: MLXArray(halves(128), [1536, 32]),
                    sines: MLXArray(halves(128 + 49152 * 2), [1536, 32]))
                try budget.check()
                let model = try Q8DecoderWeights.load(from: f.weights, canonicalHalf: true, useNativePrefill: true)
                model.transformer.diagnosticReplaceRoPE { x, offset in rotation(x, offset: offset) }
                let cache = (0..<30).map { _ in KVCache() }
                let evidence = ReferenceCacheEvidence(output: f.output, budget: budget)
                var comparisons: [ChatterboxQ8FixedFixtureDiagnostic.Comparison] = [], raw: [String: MLXArray] = [:]
                var times: [[String: Any]] = []
                for (index, name) in expectedNames.enumerated() {
                    stage = name; try budget.check()
                    let x = index == 0 ? MLXArray(input.prefix, [2, length, 1024]) : MLXArray(input.continuations[index - 1], [2, 1, 1024])
                    let began = Date()
                    let logits = model.logits(x, cache: cache); eval(logits)
                    let elapsed = Date().timeIntervalSince(began)
                    try budget.check()
                    let file = f.output.appendingPathComponent("stage-\(index)-actual-expected.safetensors")
                    times.append(["stage": name, "decoder_forward_seconds": elapsed, "raw_file": file.lastPathComponent,
                        "actual_shape": logits.shape, "actual_dtype": String(describing: logits.dtype)])
                    report["stage_times"] = times
                    try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
                    // Save the real shape/dtype and even NaN/Inf bits BEFORE
                    // compare() can reject them. Never reshape malformed output.
                    try save(arrays: ["actual": logits, "expected": targets[name]!],
                        metadata: ["scope": "Unaccepted fixed GPU diagnostic outcome, including malformed values"], url: file, stream: .cpu)
                    times[times.count - 1]["raw_sha256"] = try ChatterboxMLXRenderer.digest(file)
                    report["stage_times"] = times
                    try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
                    guard logits.dtype == .float32, logits.shape == [2, 8194] else { throw IndependentReferenceBackbone.Failure.shape }
                    let actual = logits.asArray(Float.self), expected = targets[name]!.asArray(Float.self)
                    let comparison = try ChatterboxQ8FixedFixtureDiagnostic.compare(actual, expected, stage: name)
                    comparisons.append(comparison); raw[name] = MLXArray(actual, [2, 8194])
                    report["comparisons"] = try object(comparisons); report["stage_times"] = times
                    try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
                    let offset = length + index
                    let snapshots = try cache.map { c -> (keys: [Float16], values: [Float16]) in
                        let snapshot = try c.diagnosticSnapshot(expectedOffset: offset)
                        return (snapshot.keys, snapshot.values)
                    }
                    try evidence.capture(snapshots, offset: offset, stage: name)
                    report["cache_evidence"] = evidence.stages
                    try ReferenceAssemblyStudy.write(report, f.output.appendingPathComponent("report.json"))
                }
                let file = f.output.appendingPathComponent("gpu-diagnostic-logits.safetensors")
                try save(arrays: raw, metadata: ["scope": "GPU candidate; never an app oracle"], url: file, stream: .cpu)
                report["raw_sha256"] = try ChatterboxMLXRenderer.digest(file)
                report["passes_all_unchanged_criteria"] = comparisons.count == 9 && comparisons.allSatisfy(\.passesOriginalCriteria)
                report["peak_mlx_bytes"] = Memory.peakMemory
                try ReferenceAssemblyStudy.write(["state": "complete", "report_commit_required": true,
                    "production_clearance": false], f.output.appendingPathComponent("status.json"))
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
    private static func pinnedJSON(_ file: URL, sha: String, budget: CertifiedHalfProjection.Budget) throws -> [String: Any] {
        try budget.check()
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 16_777_217), (1...16_777_216).contains(data.count),
            try handle.read(upToCount: 1)?.isEmpty != false,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha,
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw IndependentReferenceBackbone.Failure.identity }
        try budget.check(); return result
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
#endif
