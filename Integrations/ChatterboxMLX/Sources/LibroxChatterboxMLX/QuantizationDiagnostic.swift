#if os(macOS)
import Foundation
import AVFoundation
import CryptoKit
import MLX
import MLXNN
import ChatterboxCoreML
import LibroxChatterbox

/// Mac-only, bounded candidate comparison. This is deliberately separate from
/// the production renderer: a candidate's oracle failures are reported, never
/// treated as clearance to relax the production precision gate or ship a model.
public enum ChatterboxQuantizationDiagnostic {
    private enum Failure: Error { case configuration, weights, output, generationLimit, resource }
    private struct Sample: Decodable { let id: String; let text: String; let language: String }
    private struct Configuration: Decodable {
        let profile: String
        let weightsFile: String
        let expectedSHA256: String
        let oracleFile: String
        let modelDirectory: String
        let watermarkDirectory: String
        let conditioningFile: String
        let outputDirectory: String
        let samples: [Sample]
        let exportFile: String?
        let tokenReportFile: String?
        let referenceOracleFile: String?
        let groupSentences: Bool?
        let overlap: Bool?
        let reuseFlowInputs: Bool?
    }

    public static func run(configurationFile: URL) async throws {
        let c = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configurationFile))
        guard ["baseline", "smdesai-q8-oracle-only", "local-q8-f16scales", "export-local-q8",
               "local-q4-f16scales", "export-local-q4", "local-q8-cpu-reference", "acoustic-parity", "library-q8"].contains(c.profile), c.samples.count <= 6,
              ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0",
              ProcessInfo.processInfo.environment["CHATTERBOX_SYNTH_SEED"] == "42",
              !FileManager.default.fileExists(atPath: c.outputDirectory),
              try digest(URL(fileURLWithPath: c.weightsFile)) == c.expectedSHA256,
              try digest(URL(fileURLWithPath: c.oracleFile)) ==
                "87b8ab31eda9c63abbeecb8a9f0678bc8e0fe6980396ea0c4f9e16637ef618d2"
        else { throw Failure.configuration }
        // Foreign-checkpoint embeddings differ from our V3 frontend. Running
        // audio with that hybrid is invalid even if a few logits look plausible.
        guard c.profile != "smdesai-q8-oracle-only" || c.samples.isEmpty else { throw Failure.configuration }
        guard Set(c.samples.map(\.id)).count == c.samples.count,
              c.samples.allSatisfy({ $0.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil })
        else { throw Failure.configuration }
        ChatterboxMLXRenderer.configureBufferCache(maximumBytes: 64 * 1_024 * 1_024)
        try healthy(minimumAvailable: 3 * 1_024 * 1_024 * 1_024)
        if c.profile.hasPrefix("export-local-q") {
            try exportQuantized(c)
            return
        }
        if c.profile == "local-q8-cpu-reference" {
            try exportCPUReference(c)
            return
        }
        if c.profile == "acoustic-parity" {
            try await acousticComparison(c)
            return
        }
        if c.profile == "library-q8" {
            try await libraryBenchmark(c)
            return
        }
        let out = URL(fileURLWithPath: c.outputDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let began = Date()
        let model = try Device.withDefaultDevice(.gpu) { try load(c) }
        let backboneLoadSeconds = Date().timeIntervalSince(began)
        let modelBytes = model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
        let oracles = try Device.withDefaultDevice(.gpu) {
            try oracleReport(model, file: URL(fileURLWithPath: c.oracleFile))
        }
        Memory.clearCache()
        var report: [String: Any] = ["profile": c.profile, "weights_sha256": c.expectedSHA256,
            "conditioning_sha256": try digest(URL(fileURLWithPath: c.conditioningFile)),
            "model_parameter_bytes": modelBytes, "backbone_load_seconds": backboneLoadSeconds,
            "memory_after_backbone": memory(), "oracles": oracles,
            "production_gate_passed": oracles.allSatisfy { $0["production_gate_passed"] as? Bool == true },
            "experimental_mac_only": true, "acoustics": "unchanged CPU + Perth", "seed": 42]
        report["precision_policy"] = c.profile.hasPrefix("local-q")
            ? "210 Q\(bits(c)) group64 projections, FP16 affine scales/biases and KV; FP32 norms/head/accurate activations"
            : c.profile == "baseline" ? "production mixedFloat16Accurate"
            : "foreign Q8 group64, FP32 affine scales promote projection output and KV to FP32; oracle-only"
        try write(report, to: out.appendingPathComponent("report.json"))
        if let reference = c.referenceOracleFile {
            let referenceReports = try Device.withDefaultDevice(.gpu) {
                try oracleReport(model, file: URL(fileURLWithPath: reference))
            }
            report["q8_reference_checks"] = referenceReports
            report["q8_reference_sha256"] = try digest(URL(fileURLWithPath: reference))
            report["q8_implementation_gate_passed"] = referenceReports.allSatisfy { $0["production_gate_passed"] as? Bool == true }
            try write(report, to: out.appendingPathComponent("report.json"))
            guard report["q8_implementation_gate_passed"] as? Bool == true else { throw Failure.output }
        }
        if c.profile == "baseline", report["production_gate_passed"] as? Bool != true { throw Failure.output }
        if c.samples.isEmpty { return }
        let front = try await ChatterboxMultilingualPromptBuilder(modelDirectory: URL(fileURLWithPath: c.modelDirectory))
        let voice = URL(fileURLWithPath: c.conditioningFile)
        try ChatterboxVoiceFile.validate(at: voice)
        try healthy(minimumAvailable: 1_024 * 1_024 * 1_024)
        let synth = try await ChatterboxTokenSynthesizer(modelDirectory: URL(fileURLWithPath: c.modelDirectory),
            conditioningFile: voice, watermarkDirectory: URL(fileURLWithPath: c.watermarkDirectory),
            computeUnits: .init(encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly))
        let loaded = Date()
        report["total_load_and_oracle_seconds"] = loaded.timeIntervalSince(began)
        report["memory_after_full_load"] = memory()
        var clips: [[String: Any]] = []
        for sample in c.samples {
            guard sample.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { throw Failure.configuration }
            let request = try ChatterboxRequest(text: sample.text, language: sample.language,
                conditioningFile: voice, exaggeration: 0.5, guidance: 0.5, temperature: 0.8,
                maxTokens: 350, seed: 42)
            let start = Date()
            let decoded = try decode(request, model: model, frontend: front, voice: voice)
            Memory.clearCache()
            try healthy()
            let synthStart = Date()
            let pcm = try await synth.render(tokens: decoded.tokens)
            let synthSeconds = Date().timeIntervalSince(synthStart)
            let wall = Date().timeIntervalSince(start)
            guard pcm.allSatisfy(\.isFinite), !pcm.isEmpty else { throw Failure.output }
            try saveWave(pcm, to: out.appendingPathComponent(sample.id + ".wav"))
            Memory.clearCache()
            clips.append(["id": sample.id, "text": sample.text, "language": sample.language,
                "tokens": decoded.tokens, "prefill_seconds": decoded.prefill,
                "raw_tokens_before_filter": decoded.rawTokens, "eos_observed": true,
                "prefix_length": decoded.prefixLength, "prefix_sha256": decoded.prefixSHA256,
                "decode_seconds": decoded.decode, "assembly_seconds": decoded.assembly,
                "synth_seconds": synthSeconds, "wall_seconds": wall,
                "audio_seconds": Double(pcm.count) / 24_000, "rtf": wall / (Double(pcm.count) / 24_000),
                "raw_peak": pcm.map { abs($0) }.max() ?? 0, "memory": memory()])
            report["clips"] = clips
            try write(report, to: out.appendingPathComponent("report.json"))
            print("\(c.profile): \(sample.id) \(pcm.count / 24000)s audio, \(wall)s wall")
        }
        report["completed"] = true
        report["warm_render_total_seconds"] = Date().timeIntervalSince(loaded)
        try write(report, to: out.appendingPathComponent("report.json"))
    }

    private static func load(_ c: Configuration) throws -> SpeechDecoder {
        let model = SpeechDecoder(precision: .mixedFloat16Accurate)
        if c.profile == "baseline" {
            guard c.expectedSHA256 == "3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0" else { throw Failure.weights }
            let weights = try DecoderPrecision.mixedFloat16Accurate.loadWeights(from: URL(fileURLWithPath: c.weightsFile))
            try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        } else {
            // The extractor preserves upstream packed U32 and FP32 scales/biases.
            // No re-quantization, dequantization into resident FP16 or head change.
            let weights = try loadArrays(url: URL(fileURLWithPath: c.weightsFile))
            let expected = model.parameters().flattened()
            guard weights.count == 692 else { throw Failure.weights }
            var updates: [(String, Module)] = []
            var expectedKeys = Set(expected.map(\.0))
            for (name, module) in model.leafModules().flattened() {
                guard name.hasPrefix("tfmr.layers."), let linear = module as? Linear else { continue }
                guard let w = weights[name + ".weight"], let s = weights[name + ".scales"],
                      let b = weights[name + ".biases"], w.dtype == .uint32,
                      s.dtype == (c.profile.hasPrefix("local-q") ? .float16 : .float32), b.dtype == s.dtype,
                      w.shape == [linear.shape.0, linear.shape.1 * bits(c) / 32],
                      s.shape == [linear.shape.0, linear.shape.1 / 64], b.shape == s.shape
                else { throw Failure.weights }
                guard all(isFinite(s)).item(Bool.self), all(isFinite(b)).item(Bool.self) else { throw Failure.weights }
                expectedKeys.insert(name + ".scales"); expectedKeys.insert(name + ".biases")
                let quantizedLayer = QuantizedLinear(weight: w, scales: s, biases: b, groupSize: 64, bits: bits(c))
                if c.profile.hasPrefix("local-q") {
                    let probe = quantizedLayer(MLXArray.zeros([2, 1, linear.shape.1], dtype: .float16))
                    guard probe.dtype == .float16 else { throw Failure.weights }
                }
                updates.append((name, quantizedLayer))
            }
            guard updates.count == 210, Set(weights.keys) == expectedKeys else { throw Failure.weights }
            for (key, original) in expected where !key.hasPrefix("tfmr.layers.") || key.contains("layernorm") {
                guard let w = weights[key], w.shape == original.shape, w.dtype == .float32 else { throw Failure.weights }
            }
            model.update(modules: ModuleChildren.unflattened(updates))
            try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        }
        eval(model)
        Memory.clearCache()
        return model
    }

    private static func exportQuantized(_ c: Configuration) throws {
        guard c.expectedSHA256 == "3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0",
              let path = c.exportFile, !FileManager.default.fileExists(atPath: path), c.samples.isEmpty else { throw Failure.configuration }
        try Device.withDefaultDevice(.gpu) {
            var weights = try DecoderPrecision.mixedFloat16Accurate.loadWeights(from: URL(fileURLWithPath: c.weightsFile))
            var count = 0
            var errors: [[String: Any]] = []
            for key in Array(weights.keys).sorted() where key.hasPrefix("tfmr.layers.") && weights[key]!.ndim == 2 {
                try healthy()
                let original = weights.removeValue(forKey: key)!
                let (w, scales, biases) = quantized(original, groupSize: 64, bits: bits(c))
                guard let biases else { throw Failure.weights }
                let s = scales.asType(.float16), b = biases.asType(.float16)
                eval(w, s, b)
                guard all(isFinite(s)).item(Bool.self), all(isFinite(b)).item(Bool.self) else { throw Failure.weights }
                let restored = dequantized(w, scales: s, biases: b, groupSize: 64, bits: bits(c)).asType(.float32)
                let difference = abs(restored - original.asType(.float32))
                errors.append(["key": key, "max_abs": max(difference).item(Float.self),
                    "mean_abs": mean(difference).item(Float.self)])
                weights[key] = w
                weights[String(key.dropLast(7)) + ".scales"] = s
                weights[String(key.dropLast(7)) + ".biases"] = b
                count += 1
            }
            guard count == 210, weights.count == 692 else { throw Failure.weights }
            try save(arrays: weights, metadata: ["source_sha256": c.expectedSHA256,
                "precision": "source FP32 -> baseline FP16 projections -> affine Q\(bits(c)) group64; FP16 affine metadata; FP32 head/norm"], url: URL(fileURLWithPath: path))
            try write(["source_sha256": c.expectedSHA256, "candidate_sha256": try digest(URL(fileURLWithPath: path)),
                "mlx_swift_version": "0.32.3", "bits": bits(c), "group_size": 64, "mode": "affine",
                "source_rounding": "production mixedFloat16Accurate projection FP16", "per_tensor_error": errors],
                to: URL(fileURLWithPath: path + ".json"))
        }
    }

    private static func bits(_ c: Configuration) -> Int { c.profile.contains("q4") ? 4 : 8 }

    /// Independent ordinary dense FP16 CPU execution of the intended Q8 weights.
    /// This never invokes quantizedMatmul or the candidate Metal projection path.
    private static func exportCPUReference(_ c: Configuration) throws {
        guard c.expectedSHA256 == "231647ebb4deedad901c46cf3d7ca1e0fa70371b461c934c14dc63f16ec69017",
              let path = c.exportFile, !FileManager.default.fileExists(atPath: path), c.samples.isEmpty else { throw Failure.configuration }
        try Device.withDefaultDevice(.cpu) {
            let source = try loadArrays(url: URL(fileURLWithPath: c.weightsFile))
            let model = SpeechDecoder(precision: .mixedFloat16Accurate)
            var dense: [String: MLXArray] = [:]
            for (key, template) in model.parameters().flattened() {
                guard let w = source[key] else { throw Failure.weights }
                if w.dtype == .uint32 {
                    let stem = String(key.dropLast(7))
                    guard let s = source[stem + ".scales"], let b = source[stem + ".biases"] else { throw Failure.weights }
                    // Reconstruct outside quantizedMatmul, then use ordinary
                    // dense CPU projections with the existing activation policy.
                    let value = dequantized(w, scales: s.asType(.float32), biases: b.asType(.float32),
                        groupSize: 64, bits: 8, dtype: .float32).asType(.float16)
                    guard value.shape == template.shape else { throw Failure.weights }
                    eval(value); dense[key] = value
                } else { dense[key] = w }
            }
            try model.update(parameters: ModuleParameters.unflattened(dense), verify: .all)
            eval(model)
            let original = try loadArrays(url: URL(fileURLWithPath: c.oracleFile))
            var fixture: [String: MLXArray] = [:]
            for language in ["en", "es"] {
                let cache = (0..<30).map { _ in KVCache() }
                for step in 0...8 {
                    try healthy()
                    let stem = language + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                    guard let input = original[stem + ".input"] else { throw Failure.weights }
                    let output = model.logits(input, cache: cache); eval(output)
                    fixture[stem + ".input"] = input; fixture[stem + ".logits"] = output
                }
            }
            try save(arrays: fixture, metadata: ["weights_sha256": c.expectedSHA256,
                "reference": "ordinary dense FP16 CPU, FP32 accurate activations/head/norm; no quantizedMatmul"],
                url: URL(fileURLWithPath: path))
            try write(["weights_sha256": c.expectedSHA256, "oracle_sha256": try digest(URL(fileURLWithPath: path)),
                "cases": 18, "device": "CPU", "projection": "ordinary dense FP16, accurate activations",
                "compression_reference_delta_is_not_quality_acceptance": true],
                to: URL(fileURLWithPath: path + ".json"))
        }
    }

    private static func acousticComparison(_ c: Configuration) async throws {
        guard let path = c.tokenReportFile else { throw Failure.configuration }
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        guard let clips = j?["clips"] as? [[String: Any]], (1...6).contains(clips.count) else { throw Failure.configuration }
        let out = URL(fileURLWithPath: c.outputDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let units = PipelineComputeUnits(encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly)
        let a = try await ChatterboxTokenSynthesizer(modelDirectory: URL(fileURLWithPath: c.modelDirectory),
            conditioningFile: URL(fileURLWithPath: c.conditioningFile), watermarkDirectory: URL(fileURLWithPath: c.watermarkDirectory),
            computeUnits: units)
        let b = try await ChatterboxTokenSynthesizer(modelDirectory: URL(fileURLWithPath: c.modelDirectory),
            conditioningFile: URL(fileURLWithPath: c.conditioningFile), watermarkDirectory: URL(fileURLWithPath: c.watermarkDirectory),
            computeUnits: units, reuseFlowInputs: true)
        var rows: [[String: Any]] = []
        for clip in clips.prefix(2) {
            guard let tokens = clip["tokens"] as? [Int], let id = clip["id"] as? String else { throw Failure.configuration }
            var expected: [Float]?
            for optimized in [false, true, true, false] {
                try healthy(minimumAvailable: 1_024 * 1_024 * 1_024)
                let began = Date()
                let result = try await (optimized ? b : a).renderMeasured(tokens: tokens)
                let wall = Date().timeIntervalSince(began)
                if expected == nil { expected = result.samples }
                guard result.samples.count == expected!.count else { throw Failure.output }
                let differences = zip(result.samples, expected!).map { abs($0 - $1) }
                let exact = zip(result.samples, expected!).allSatisfy { $0.bitPattern == $1.bitPattern }
                rows.append(["id": id, "reuse": optimized, "wall_seconds": wall,
                    "audio_seconds": Double(result.samples.count) / 24_000, "bit_identical": exact,
                    "max_abs": differences.max() ?? 0,
                    "acoustics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.timings))])
                try write(["rows": rows, "policy": "CPU, fixed tokens and CFM noise42, Perth enabled; ABBA"],
                    to: out.appendingPathComponent("report.json"))
                guard exact else { throw Failure.output }
            }
        }
        try write(["rows": rows, "completed": true, "all_bit_identical": true], to: out.appendingPathComponent("report.json"))
    }

    private static func libraryBenchmark(_ c: Configuration) async throws {
        guard let oracle = c.referenceOracleFile, !c.samples.isEmpty else { throw Failure.configuration }
        let out = URL(fileURLWithPath: c.outputDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let began = Date()
        let renderer = try await ChatterboxMLXRenderer(weightsFile: URL(fileURLWithPath: c.weightsFile),
            oracleFile: URL(fileURLWithPath: oracle), modelDirectory: URL(fileURLWithPath: c.modelDirectory),
            defaultVoice: URL(fileURLWithPath: c.conditioningFile), watermarkDirectory: URL(fileURLWithPath: c.watermarkDirectory),
            acousticComputeUnits: .init(encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly),
            decoderProfile: .q8ExperimentalV1, reuseAcousticInputs: c.reuseFlowInputs ?? false)
        let loadSeconds = Date().timeIntervalSince(began)
        let narrator = await renderer.makeNarrator(overlap: c.overlap ?? false)
        let voice = URL(fileURLWithPath: c.conditioningFile)
        var reports: [[String: Any]] = []
        for sample in c.samples {
            let collector = BookBenchmarkCollector()
            let session = try ChatterboxBookSession(narrator: narrator,
                cacheDirectory: out.appendingPathComponent(sample.id + "-cache"),
                modelManifestSHA256: c.expectedSHA256, rendererProfile: renderer.profileIdentifier)
            let start = Date()
            try await session.stream(sample.text, language: sample.language, narratorID: "stock",
                conditioningFiles: ["stock": voice], direction: .neutral,
                grouping: c.groupSentences == true ? .compatibleNarration() : .sentences, seed: 42,
                preparation: .finiteExcerpt) { passage in
                    try await collector.append(passage)
                }
            let wall = Date().timeIntervalSince(start)
            let result = try await collector.result()
            try saveWave(result.samples, to: out.appendingPathComponent(sample.id + ".wav"))
            reports.append(["id": sample.id, "wall_seconds": wall,
                "generated_audio_seconds": Double(result.frames) / 24_000,
                "playback_audio_seconds": Double(result.samples.count) / 24_000,
                "rtf_generated": wall / (Double(result.frames) / 24_000),
                "units": try JSONSerialization.jsonObject(with: result.rowsData), "memory": memory()])
            try write(["completed": false, "load_seconds": loadSeconds, "samples": reports,
                "grouped": c.groupSentences ?? false, "overlap": c.overlap ?? false,
                "reuse_flow_inputs": c.reuseFlowInputs ?? false, "profile": renderer.profileIdentifier,
                "q8_implementation_checks": 18, "original_fp32_equivalent": false], to: out.appendingPathComponent("report.json"))
        }
        try await narrator.unload()
        try write(["completed": true, "load_seconds": loadSeconds, "samples": reports,
            "grouped": c.groupSentences ?? false, "overlap": c.overlap ?? false,
            "reuse_flow_inputs": c.reuseFlowInputs ?? false, "profile": renderer.profileIdentifier,
            "q8_implementation_checks": 18, "original_fp32_equivalent": false], to: out.appendingPathComponent("report.json"))
    }

    private static func oracleReport(_ model: SpeechDecoder, file: URL) throws -> [[String: Any]] {
        let f = try loadArrays(url: file)
        var reports: [[String: Any]] = []
        for lang in ["en", "es"] {
            let cache = (0..<30).map { _ in KVCache() }
            for step in 0...8 {
                try healthy()
                let stem = lang + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                guard let input = f[stem + ".input"], let target = f[stem + ".logits"] else { throw Failure.weights }
                let start = Date()
                let output = model.logits(input, cache: cache); eval(output)
                let wall = Date().timeIntervalSince(start)
                let a = output.asArray(Float.self), b = target.asArray(Float.self)
                guard a.count == 16388, b.count == a.count, a.allSatisfy(\.isFinite) else { throw Failure.output }
                var maximum = 0.0, squared = 0.0, norm = 0.0
                for (x, y) in zip(a, b) {
                    maximum = max(maximum, abs(Double(x - y)))
                    squared += pow(Double(x - y), 2); norm += pow(Double(y), 2)
                }
                let relative = sqrt(squared / max(norm, 1e-30))
                let top1 = (0..<2).allSatisfy { lane in
                    let r = (lane * 8194)..<((lane + 1) * 8194)
                    return r.max { a[$0] < a[$1] } == r.max { b[$0] < b[$1] }
                }
                reports.append(["stem": stem, "max_abs": maximum, "relative_l2": relative,
                    "fixed_prefix_prediction_seconds": wall,
                    "both_cfg_top1": top1, "production_gate_passed": maximum <= 0.05 && relative <= 0.002 && top1])
            }
        }
        return reports
    }

    private struct Decoded {
        let tokens: [Int]; let rawTokens: [Int]; let prefixLength: Int; let prefixSHA256: String
        let assembly: Double; let prefill: Double; let decode: Double
    }
    @inline(never) private static func decode(_ r: ChatterboxRequest, model: SpeechDecoder,
        frontend: ChatterboxMultilingualPromptBuilder, voice: URL) throws -> Decoded {
        let start = Date()
        let prefix = try frontend.prepare(text: r.text, language: r.language, conditioningFile: voice,
            exaggeration: r.exaggeration, guidance: r.guidance, maxTokens: r.maxTokens)
        let assembly = Date().timeIntervalSince(start)
        let prefixHash = prefix.embeddings.withUnsafeBytes { bytes in
            SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        }
        let cache = (0..<30).map { _ in KVCache() }
        var input = MLXArray(prefix.embeddings, [2, prefix.length, 1024])
        var sampler = ChatterboxSpeechSampler(options: .multilingual(language: r.language,
            exaggeration: r.exaggeration, cfgWeight: r.guidance, temperature: r.temperature,
            maxTokens: r.maxTokens, seed: r.seed))
        var tokens: [Int] = [], prefill = 0.0
        let began = Date()
        for step in 0..<r.maxTokens {
            try healthy()
            let t = Date()
            let values: [Float] = Device.withDefaultDevice(.gpu) {
                let output = model.logits(input, cache: cache); eval(output)
                return output.asArray(Float.self)
            }
            if step == 0 { prefill = Date().timeIntervalSince(t) }
            guard values.count == 16388, values.allSatisfy(\.isFinite) else { throw Failure.output }
            let guided = (0..<8194).map { values[$0] + r.guidance * (values[$0] - values[8194 + $0]) }
            let token = sampler.sample(logits: guided, previous: tokens, minTokensReached: tokens.count >= 2)
            if token == 6562 && tokens.count >= 2 {
                return .init(tokens: tokens.filter { $0 < 6561 }, rawTokens: tokens,
                    prefixLength: prefix.length, prefixSHA256: prefixHash, assembly: assembly,
                    prefill: prefill, decode: Date().timeIntervalSince(began) - prefill)
            }
            tokens.append(token)
            let embedding = try frontend.speechInput(token: token, position: step + 1)
            input = MLXArray(embedding + embedding, [2, 1, 1024])
        }
        throw Failure.generationLimit
    }

    private static func healthy(minimumAvailable: Int = 256 * 1_024 * 1_024) throws {
        try Task.checkCancellation()
        let s = ChatterboxMLXRenderer.memorySnapshot()
        guard !s.lowPowerMode, s.thermalState < 2,
              let available = s.availableBytes, available >= minimumAvailable else { throw Failure.resource }
    }
    private static func memory() -> [String: Any] {
        let s = ChatterboxMLXRenderer.memorySnapshot()
        return ["active_bytes": s.activeBytes, "cache_bytes": s.cacheBytes, "peak_bytes": s.peakBytes,
                "thermal": s.thermalState, "available_bytes": s.availableBytes ?? 0]
    }
    private static func digest(_ url: URL) throws -> String {
        let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
        var hash = SHA256()
        while let b = try f.read(upToCount: 1_048_576), !b.isEmpty { try Task.checkCancellation(); hash.update(data: b) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func saveWave(_ pcm: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
              let channel = buffer.floatChannelData?[0] else { throw Failure.output }
        buffer.frameLength = buffer.frameCapacity
        pcm.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: pcm.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
private actor BookBenchmarkCollector {
    var samples: [Float] = []
    var frames = 0
    var rows: [[String: Any]] = []
    func append(_ passage: ChatterboxPreparedPassage) throws {
        guard passage.samples.count <= 180 * 24_000 - samples.count else { throw CocoaError(.fileWriteOutOfSpace) }
        samples += passage.samples; frames += passage.generatedFrames
        var row: [String: Any] = ["index": passage.index, "source_location": passage.unit.request.sourceContext!.range.location,
            "source_length": passage.unit.request.sourceContext!.range.length,
            "sentence_fragments": passage.unit.sourceFragments.count, "cache_hit": passage.cacheHit,
            "generated_frames": passage.generatedFrames]
        if let t = passage.timings {
            row["decode_seconds"] = t.decodeSeconds; row["prefill_seconds"] = t.prefillSeconds
            row["synth_seconds"] = t.synthSeconds; row["watermark_seconds"] = t.watermarkSeconds
            if let a = t.acoustics { row["acoustics"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) }
        }
        rows.append(row)
    }
    struct Result: Sendable { let samples: [Float]; let frames: Int; let rowsData: Data }
    func result() throws -> Result { .init(samples: samples, frames: frames, rowsData: try JSONSerialization.data(withJSONObject: rows)) }
}

#endif
