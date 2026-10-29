#if os(macOS)
import Foundation
import MLX

/// One arm per fresh process. No CPU model forward, production profile or
/// oracle selection. The four-arm negative controls are checked separately.
enum GPUFactorStudy {
    static let preregistrationSHA256 = "db069845ed6b59943481c7affa1d7e67d70e829e52f3b49e5a3d3431e40f84e6"
    static let certifiedSHA256 = "e0428ba766d0ae0fc964660b3198db4d1ba4511eecdfcb7e93e12c6e9fc0ea7e"
    enum Failure: Error { case identity, fixture }
    enum Arm: String, CaseIterable {
        case nativePrefillNativeRoPE, densePrefillNativeRoPE
        case nativePrefillHalfRoPE, densePrefillHalfRoPE
        var nativePrefill: Bool { self == .nativePrefillNativeRoPE || self == .nativePrefillHalfRoPE }
        var halfRoPE: Bool { self == .nativePrefillHalfRoPE || self == .densePrefillHalfRoPE }
    }
    static var conditionKeys: Set<String> {
        var keys = Set<String>()
        for language in ["en", "es"] {
            keys.insert("native.\(language).prefill")
            for i in 0..<8 { keys.insert("native.\(language).decode.\(i)") }
        }
        for i in 0..<3 { keys.insert("cpu93.es.decode.\(i)") }
        keys.insert("cpu95.es.decode.2")
        return keys
    }
    static func run(_ f: PrimitiveDiagnostic.Files, preregistration: URL, arm name: String,
                    certified: URL) throws {
        try PrimitiveDiagnostic.identities(f)
        guard let arm = Arm(rawValue: name),
            try ChatterboxMLXRenderer.digest(preregistration) == preregistrationSHA256,
            try ChatterboxMLXRenderer.digest(certified) == certifiedSHA256 else { throw Failure.identity }
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        var report: [String: Any] = ["diagnostic_only": true, "production_clearance": false,
            "completed": false, "arm": name, "pid": ProcessInfo.processInfo.processIdentifier,
            "gpu_only_model_forward": true, "preregistration_sha256": preregistrationSHA256,
            "certified_diagnostic_sha256": certifiedSHA256,
            "prefill": arm.nativePrefill ? "nativeQuantized" : "canonicalHalfDenseFP32",
            "rope": arm.halfRoPE ? "pinnedCPUHalfTable" : "nativeGPU",
            "decode": "unchangedCanonicalTwoRowV2", "offline_dense_memory_not_mobile_evidence": true]
        do {
            try Device.withDefaultDevice(.gpu) {
                let began = Date(), budget = CertifiedHalfProjection.Budget()
                let fixture = try loadArrays(url: f.oracle), target = try loadArrays(url: certified)
                guard Set(target.keys) == conditionKeys,
                    target.values.allSatisfy({ $0.shape == [2, 8194] && $0.dtype == .float32 }) else { throw Failure.fixture }
                let cpu93 = try loadArrays(url: f.cpu93), cpu95 = try loadArrays(url: f.cpu95)
                try DiagnosticRoPEFixture.validate(cpu95)
                try budget.check()
                let model = try Q8DecoderWeights.load(from: f.weights, canonicalHalf: true, useNativePrefill: arm.nativePrefill)
                if arm.halfRoPE {
                    guard let c = cpu95["rope.cosines"], let s = cpu95["rope.sines"] else { throw Failure.fixture }
                    let rope = DiagnosticHalfRoPE(cosines: c, sines: s)
                    model.transformer.diagnosticReplaceRoPE { input, offset in rope(input, offset: offset) }
                }
                var outputs: [String: MLXArray] = [:], rows: [[String: Any]] = []
                func execute(_ stem: String, condition: String, cache: [KVCache]) throws {
                    try budget.check()
                    let key = condition + "." + stem
                    guard let input = fixture[stem + ".input"], let old = fixture[stem + ".logits"],
                        let reference = target[key] else { throw Failure.fixture }
                    let logits = model.logits(input, cache: cache); eval(logits)
                    try budget.check()
                    let values = logits.asArray(Float.self)
                    let legacy = try ChatterboxQ8FixedFixtureDiagnostic.compare(values, old.asArray(Float.self), stage: key)
                    let exact = try ChatterboxQ8FixedFixtureDiagnostic.compare(values, reference.asArray(Float.self), stage: key)
                    rows.append(["condition": key, "old_oracle": try object(legacy),
                        "certified_diagnostic": try object(exact),
                        "lane1_signed6472minus4205": values[8194 + 6472] - values[8194 + 4205]])
                    outputs[key] = MLXArray(values, [2, 8194])
                }
                for language in ["en", "es"] {
                    let cache = (0..<30).map { _ in KVCache() }
                    try execute(language + ".prefill", condition: "native", cache: cache)
                    for i in 0..<8 { try execute("\(language).decode.\(i)", condition: "native", cache: cache) }
                }
                for offset in [93, 95] {
                    let source = offset == 93 ? cpu93 : cpu95
                    let cache = try (0..<30).map { index -> KVCache in
                        try budget.check()
                        let stem = offset == 93 ? "es.prefill.layer.\(index)" : "layer.\(index)"
                        guard let k = source[stem + ".keys"], let v = source[stem + ".values"] else { throw Failure.fixture }
                        return try KVCache.restoringFixedFixture(keys: k, values: v, expectedOffset: offset)
                    }
                    for i in (offset - 93)..<3 { try execute("es.decode.\(i)", condition: "cpu\(offset)", cache: cache) }
                }
                guard Set(outputs.keys) == conditionKeys else { throw Failure.fixture }
                try budget.check()
                let raw = f.output.appendingPathComponent("diagnostic-logits.safetensors")
                try save(arrays: outputs, metadata: ["scope": "GPU factor diagnostic; not app oracle", "arm": name], url: raw)
                report["raw_logits_sha256"] = try ChatterboxMLXRenderer.digest(raw)
                report["comparisons"] = rows; report["wall_seconds"] = Date().timeIntervalSince(began)
                report["peak_mlx_bytes"] = Memory.peakMemory
                try budget.check()
                report["completed"] = true
                try write(report, f.output.appendingPathComponent("report.json"))
            }
        } catch {
            report["completed"] = false; report["error"] = String(describing: error)
            try? write(report, f.output.appendingPathComponent("report.json"))
            throw error
        }
    }
    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private static func write(_ value: [String: Any], _ file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
#endif
