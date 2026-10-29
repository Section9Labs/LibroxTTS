#if os(macOS)
import Foundation
import MLX
import MLXNN

/// Certification stage only; the preregistered full-model intervention is a
/// separate future stage. No outputs become an oracle or inference profile.
enum CertifiedProjectionStudy {
    static let preregistrationSHA256 = "c494e0df06d05574edb78000c1290ea85e265f21909a038807f923d0ac522471"
    static let exactReportSHA256 = "bb5a8dc2cc486525d535c5a2333c59bb8e843e64c1de3607b4ed49802a11da7c"
    enum Failure: Error { case identity, fixture, comparison(String) }
    private struct ExactReport: Decodable {
        let cases: [Sample]
        struct Sample: Decodable { let module: String; let row: Int; let lane: Int; let exact: UInt16 }
    }
    static func run(_ f: PrimitiveDiagnostic.Files, preregistration: URL, exactReport: URL,
                    loadCPUModel: () throws -> SpeechDecoder) throws {
        try PrimitiveDiagnostic.identities(f)
        guard try ChatterboxMLXRenderer.digest(preregistration) == preregistrationSHA256,
            try ChatterboxMLXRenderer.digest(f.primitives) == PrimitiveDiagnostic.fixtureSHA256,
            try exactReport.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 16 * 1024 * 1024,
            try ChatterboxMLXRenderer.digest(exactReport) == exactReportSHA256 else { throw Failure.identity }
        let expected = try JSONDecoder().decode(ExactReport.self, from: Data(contentsOf: exactReport))
        guard expected.cases.count == 13_440 else { throw Failure.fixture }
        let grouped = Dictionary(grouping: expected.cases, by: \.module)
        let began = Date()
        try Device.withDefaultDevice(.cpu) {
            let model = try loadCPUModel()
            let source = try loadArrays(url: f.primitives)
            try PrimitiveDiagnostic.validate(source, model: model)
            let budget = CertifiedHalfProjection.Budget()
            var outputs: [String: MLXArray] = [:], rows: [[String: Any]] = []
            var certified = 0, fallback = 0, matched = 0, nativeExact = 0
            let modules = model.leafModules().flattened().filter {
                $0.0.hasPrefix("tfmr.layers.") && $0.1 is Linear
            }.sorted { $0.0 < $1.0 }
            guard modules.count == 210, Set(grouped.keys) == Set(modules.map(\.0)) else { throw Failure.fixture }
            for (name, module) in modules {
                try budget.check()
                guard let layer = module as? Linear, let input = source[name + ".input"],
                    let target = source[name + ".output"], let samples = grouped[name] else { throw Failure.fixture }
                let n = layer.shape.0
                let native = layer(input); eval(native)
                let a = native.asArray(Float16.self), b = target.asArray(Float16.self)
                guard a.count == b.count, zip(a, b).allSatisfy({ $0.bitPattern == $1.bitPattern })
                else { throw Failure.comparison("native CPU materialization: \(name)") }
                nativeExact += a.count
                let membership = Set(ExactDotExport.rows(n).flatMap { row in [Int(row), n + Int(row)] })
                guard samples.count == 64,
                    samples.allSatisfy({ [0, 1].contains($0.lane) && (0..<n).contains($0.row) }),
                    Set(samples.map { $0.lane * n + $0.row }) == membership else { throw Failure.fixture }
                let result = try CertifiedHalfProjection.evaluate(input: input, weight: layer.weight, budget: budget)
                for sample in samples {
                    let bits = result.values[sample.lane * n + sample.row].bitPattern
                    // Exact-zero contract is +0; preserve signed-zero differences.
                    guard bits == sample.exact else {
                        throw Failure.comparison("\(name) row\(sample.row) lane\(sample.lane) expected\(sample.exact) actual\(bits)")
                    }
                    matched += 1
                }
                certified += result.statistics.certified; fallback += result.statistics.exactFallback
                guard result.boundaries.count == result.statistics.exactFallback else { throw Failure.comparison("boundary audit count") }
                rows.append(["module": name, "certified": result.statistics.certified,
                    "exact_fallback": result.statistics.exactFallback, "outputs": result.statistics.outputs,
                    "boundary_cases": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.boundaries))])
                outputs[name] = MLXArray(result.values, result.shape)
            }
            guard matched == 13_440, nativeExact == 798_720, certified + fallback == 798_720
            else { throw Failure.comparison("certification counts") }
            try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
            let file = f.output.appendingPathComponent("diagnostic-projections.safetensors")
            try save(arrays: outputs, metadata: ["scope": "certified projection samples only; not an oracle or profile",
                "preregistration_sha256": preregistrationSHA256, "exact_report_sha256": exactReportSHA256], url: file)
            let report: [String: Any] = ["completed": true, "diagnostic_only": true, "cpu_only_process": true,
                "exact_integer_samples_matched": matched, "original_cpu_half_outputs_bit_identical": nativeExact,
                "certified_outputs": certified, "exact_fallback_outputs": fallback, "matrices": rows,
                "preregistration_sha256": preregistrationSHA256, "exact_report_sha256": exactReportSHA256,
                "output_sha256": try ChatterboxMLXRenderer.digest(file), "wall_seconds": Date().timeIntervalSince(began),
                "full_model_counterfactual_executed": false, "production_clearance": false,
                "assumptions": "CPU IEEE binary64 BLAS accumulation; half products exact; gamma_K error bound with directed inflation; ambiguous half bins use Int128 exact sums"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: f.output.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
#endif
