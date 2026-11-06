import Foundation
import AVFoundation
import NaturalLanguage
import KokoroCatalog
import LibroxTTS
import LibroxCTNative

/// Real model smoke tests, plus controlled old/new pipeline auditions. This does
/// not label a language perceptually accepted or a sample more expressive.
@main struct NarrationPipelineProbe {
    static func main() async throws {
        if CommandLine.arguments.count == 4 {
            try await comparePassage(assets: URL(fileURLWithPath: CommandLine.arguments[1]),
                output: URL(fileURLWithPath: CommandLine.arguments[2]),
                passage: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        guard CommandLine.arguments.count == 3 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Usage: narration-pipeline-probe ASSETS OUTPUT [PASSAGE.txt]"])
        }
        let assets = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pipeline = NarrationPipeline()
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil)
        try await renderer.load(.plus, directory: assets, executionContext: .foreground)
        var results: [[String: Any]] = []
        for language in NarrationLanguage.textNativeCodes {
            let text = NarrationLanguage.sampleText(language)!
            let start = Date()
            do {
                let plan = try await pipeline.plan(text, model: .plus, bookID: "probe", chapterID: language,
                    narratorVoiceID: nil, language: language)
                var samples: [Float] = []
                for unit in plan.units { samples += try await renderer.render(unit) }
                guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
                try write(samples, rate: 44_100, to: output.appendingPathComponent(language + ".wav"))
                results.append(["language": language, "units": plan.units.count, "samples": samples.count,
                    "audioSeconds": Double(samples.count) / 44_100, "renderSeconds": Date().timeIntervalSince(start),
                    "peak": samples.map(abs).max() ?? 0, "source": text, "status": "rendered-not-listening-qualified"])
            } catch { results.append(["language": language, "error": String(describing: error)]) }
            try report(results, to: output)
            print("language \(language): \(results.last?["error"] ?? "rendered")")
        }
        await renderer.unload()
        let engine = CTEngine(directory: assets, backend: .coreMLGPUHeavy)
        try await engine.load()
        let passages = [
            ("en", "For months, she had kept his chair beside the fire, listening for his footsteps on the stairs and telling herself that the next knock would be his, even when the days grew shorter and the house seemed to have forgotten the sound of his voice, until at last he stood in the doorway, smiling through his tears. You came back! She took his cold hands in hers and led him into the warmth."),
            ("es", "Durante meses había guardado su silla junto al fuego, escuchando los pasos en la escalera y diciéndose que la próxima llamada sería la suya, incluso cuando los días se hicieron más cortos y la casa parecía haber olvidado el sonido de su voz, hasta que por fin apareció en la puerta, sonriendo entre lágrimas. ¡Has vuelto! Ella tomó sus manos frías y lo llevó junto al fuego.")]
        for (language, text) in passages {
            let plan = try await pipeline.plan(text, model: .plus, bookID: "audition", chapterID: language,
                                              narratorVoiceID: nil, language: language)
            for (label, units, legacy) in [("before", try oldPlan(text), true),
                                         ("after", plan.units.map(\.synthesisText), false)] {
                var samples: [Float] = []
                for unit in units {
                    let first = try await engine.synthesize(unit, language: language, captureTrace: true,
                                                           completeSentence: legacy)
                    guard let initial = first.trace["initial_latent"] else { throw CTError.invalidTensor("noise") }
                    // Same deterministic Gaussian stream for both paths. A change
                    // of text/duration necessarily changes the tensor's shape.
                    let noise = try CTTensor(gaussian(count: initial.shape.reduce(1, *)), shape: initial.shape)
                    let native = try await engine.synthesize(unit, language: language, initialNoise: noise,
                                                            completeSentence: legacy)
                    let ending = unit.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
                    let pause = legacy && ending.last.map({ ".!?…。！？".contains($0) }) == true
                        ? (language == "es" ? 0.32 : 0.22) : 0
                    let delivered = try CTDelivery.prepare(native.samples, sampleRate: 44_100,
                        boundaryPause: pause, level: legacy ? .referenceLoudness : .nativeDynamics)
                    samples += delivered.samples
                }
                // Audition at equal integrated loudness so louder is not mistaken
                // for better. This is one gain per complete clip, not per passage.
                let loudness = try CTDelivery.integratedLoudness(samples)
                let gain = min(pow(10, (-24 - loudness) / 20), 0.98 / Double(samples.map(abs).max()!))
                samples = samples.map { $0 * Float(gain) }
                try write(samples, rate: 44_100, to: output.appendingPathComponent(language + "-" + label + ".wav"))
                results.append(["comparison": language + "-" + label, "source": text,
                    "units": units, "samples": samples.count, "auditionGainDB": 20 * log10(gain),
                    "note": "Both comparisons at 44.1 kHz; old passage boundaries, punctuation and gain versus new. Fixed diagnostic noise. Listening judgment pending."])
                try report(results, to: output)
            }
        }
        await engine.unload()
        if results.contains(where: { $0["error"] != nil }) { throw CTError.invalidAudio }
    }
    static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try file.write(from: buffer)
    }
    static func report(_ rows: [[String: Any]], to output: URL) throws {
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"), options: .atomic)
    }
    static func gaussian(count: Int) -> [Float] {
        var state: UInt64 = 20261106
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / 9_007_199_254_740_992
        }
        var values: [Float] = []; values.reserveCapacity(count)
        while values.count < count {
            let radius = sqrt(-2 * log(uniform())), angle = 2 * Double.pi * uniform()
            values.append(Float(radius * cos(angle)))
            if values.count < count { values.append(Float(radius * sin(angle))) }
        }
        return values
    }
    static func oldPlan(_ text: String) throws -> [String] {
        let source = text as NSString
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { sentence, _ in
            ranges.append(NSRange(sentence, in: text)); return true
        }
        if ranges.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ranges = [NSRange(location: 0, length: source.length)]
        }
        var result: [NSRange] = []
        for range in ranges {
            var remainder = range
            while remainder.length > 0 {
                try Task.checkCancellation()
                var end = min(NSMaxRange(remainder), remainder.location + 280)
                if end < NSMaxRange(remainder) {
                    while end > remainder.location,
                          !(UnicodeScalar(source.character(at: end - 1)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false) { end -= 1 }
                    guard end > remainder.location else { throw CTError.invalidTensor("Legacy planner cannot split text") }
                }
                let part = NSRange(location: remainder.location, length: end - remainder.location)
                if let prior = result.last, end - prior.location <= 280,
                   !source.substring(with: NSRange(location: NSMaxRange(prior), length: part.location - NSMaxRange(prior))).contains("\n") {
                    result[result.count - 1] = NSRange(location: prior.location, length: end - prior.location)
                } else { result.append(part) }
                remainder = NSRange(location: end, length: NSMaxRange(remainder) - end)
            }
        }
        return result.map { source.substring(with: $0) }
    }
}
