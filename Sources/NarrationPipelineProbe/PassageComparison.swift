import Foundation
import LibroxCTNative
import LibroxTTS

extension NarrationPipelineProbe {
    /// Reconstruct delivery with controlled diagnostic noise. The files are not
    /// recordings of the installed iOS app. Optional frozen-reference inputs
    /// must describe exactly the same paragraph and tokenizer output.
    static func comparePassage(assets: URL, output: URL, passage: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let text = try String(contentsOf: passage, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = try await NarrationPipeline().plan(text, model: .plus,
            bookID: "passage-comparison", chapterID: "en", narratorVoiceID: nil, language: "en")
        // This diagnostic isolates a single model invocation. Longer inputs
        // belong in the normal renderer's bounded splitting path.
        guard plan.units.count == 1, plan.units[0].synthesisText == text else {
            throw CTError.invalidTensor("Comparison needs one unchanged English passage")
        }
        let backendName = ProcessInfo.processInfo.environment["LIBROX_PROBE_BACKEND"] ?? "coreMLGPUHeavy"
        guard let backend = CTEngine.Backend(rawValue: backendName) else {
            throw CTError.invalidTensor("Unknown diagnostic backend")
        }
        let engine = CTEngine(directory: assets, backend: backend)
        try await engine.load()
        var rows: [[String: Any]] = []
        let referenceURL = output.appendingPathComponent("reference-report.json")
        let reference: [String: Any]?
        let noise: CTTensor
        if FileManager.default.fileExists(atPath: referenceURL.path) {
            reference = try JSONSerialization.jsonObject(with: Data(contentsOf: referenceURL)) as? [String: Any]
            guard reference?["text"] as? String == text,
                  let shape = reference?["noise_shape"] as? [Int] else {
                throw CTError.invalidTensor("Reference passage or shape mismatch")
            }
            noise = try CTTensor(shape: shape, kind: .float32,
                data: Data(contentsOf: output.appendingPathComponent("reference-noise.bin")))
        } else {
            reference = nil
            let sizing = try await engine.synthesize(text, language: "en", captureTrace: true,
                                                     completeSentence: false)
            guard let shape = sizing.trace["initial_latent"]?.shape else { throw CTError.invalidTensor("noise") }
            noise = try CTTensor(gaussian(count: shape.reduce(1, *)), shape: shape)
        }
        let native = try await engine.synthesize(text, language: "en", initialNoise: noise,
                                                captureTrace: true, completeSentence: false)
        guard let waveform = native.trace["waveform"] else { throw CTError.invalidTensor("waveform") }
        try waveform.data.write(to: output.appendingPathComponent("coreml-raw.bin"))
        let traceURL = output.appendingPathComponent("coreml-trace")
        try FileManager.default.createDirectory(at: traceURL, withIntermediateDirectories: true)
        var traceManifest: [String: Any] = [:]
        for (name, tensor) in native.trace {
            try tensor.data.write(to: traceURL.appendingPathComponent(name + ".bin"))
            traceManifest[name] = ["shape": tensor.shape, "kind": tensor.kind.rawValue]
        }
        try JSONSerialization.data(withJSONObject: traceManifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: traceURL.appendingPathComponent("manifest.json"))
        if reference != nil {
            let ids = try Data(contentsOf: output.appendingPathComponent("reference-text-ids.bin"))
            guard ids == native.trace["text_ids"]?.data else { throw CTError.invalidTensor("Reference token mismatch") }
            let expected = try CTTensor(shape: [native.samples.count], kind: .float32,
                data: Data(contentsOf: output.appendingPathComponent("reference-raw.bin"))).floats()
            var errorPower = 0.0, signalPower = 0.0, maxError = 0.0
            for (a, b) in zip(expected, native.samples) {
                let delta = Double(a) - Double(b)
                errorPower += delta * delta; signalPower += Double(a) * Double(a)
                maxError = max(maxError, abs(delta))
            }
            rows.append(["comparison": "original-onnx-versus-coreml", "identicalTokens": true,
                "identicalInitialNoise": true, "backend": backend.rawValue, "samples": native.samples.count,
                "snrDB": 10 * log10(signalPower / max(errorPower, Double.leastNonzeroMagnitude)),
                "maximumAbsoluteError": maxError])
        }
        let candidate = try CTDelivery.prepare(native.samples, sampleRate: 44_100, level: .nativeDynamics)
        try write(candidate.samples, rate: 44_100, to: output.appendingPathComponent("candidate-delivery.wav"))
        rows.append(["comparison": "candidate-delivery", "units": [text], "sampleRate": 44_100,
            "samples": candidate.samples.count, "gainDB": candidate.gainDB,
            "predictedDuration": native.predictedDuration, "graphSeconds": native.graphSeconds])
        var legacy: [Float] = [], legacyRows: [[String: Any]] = []
        for (index, unit) in try oldPlan(text).enumerated() {
            let sizing = try await engine.synthesize(unit, language: "en", captureTrace: true)
            guard let shape = sizing.trace["initial_latent"]?.shape else { throw CTError.invalidTensor("noise") }
            let chunkNoise = try CTTensor(gaussian(count: shape.reduce(1, *)), shape: shape)
            let chunk = try await engine.synthesize(unit, language: "en", initialNoise: chunkNoise)
            let ending = unit.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
            let pause = ending.last.map { ".!?…。！？".contains($0) } == true ? 0.22 : 0
            let delivered = try CTDelivery.prepare(chunk.samples, sampleRate: 24_000,
                boundaryPause: pause, level: .referenceLoudness)
            legacy += delivered.samples
            try chunkNoise.data.write(to: output.appendingPathComponent("legacy-noise-\(index).bin"))
            legacyRows.append(["text": unit, "noiseShape": shape, "gainDB": delivered.gainDB,
                "samples": delivered.samples.count, "boundaryPause": pause])
        }
        try write(legacy, rate: 24_000, to: output.appendingPathComponent("released-delivery.wav"))
        rows.append(["comparison": "released-delivery-reconstruction", "sampleRate": 24_000,
            "samples": legacy.count, "units": legacyRows,
            "note": "Frozen 0.2.1 planner/delivery policy; changed input shapes require different diagnostic noise. Desktop reconstruction, not iOS playback capture."])
        await engine.unload()
        try report(rows, to: output)
        print(String(data: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
