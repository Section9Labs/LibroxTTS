import Foundation
import CryptoKit
import LibroxTTS
import LibroxCTNative

extension NarrationPipelineProbe {
    /// Render each real preset with one loaded production renderer. Assets and
    /// inference are Core ML only; style switching must not require another model.
    static func nativeVoiceBank(arguments: [String]) async throws {
        guard arguments.count == 2 else { throw CocoaError(.fileReadUnknown) }
        let assets = URL(fileURLWithPath: arguments[0]), output = URL(fileURLWithPath: arguments[1])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil)
        let pipeline = NarrationPipeline(), delivery = NarrationModel.plus.resolvedDeliveryOptions(.init(expressive: true))
        let sources = ["en": "The lamp was still burning beside the window. She opened the letter, read the first line, and smiled. Tomorrow, they would finally see each other again.",
                       "es": "La lámpara seguía encendida junto a la ventana. Ella abrió la carta, leyó la primera línea y sonrió. Mañana, por fin, volverían a verse."]
        let started = Date()
        try await renderer.load(.plus, directory: assets, executionContext: .foreground)
        let loadSeconds = Date().timeIntervalSince(started)
        var cases: [[String: Any]] = []
        do {
            for language in ["en", "es"] {
                for voice in NarrationModel.plus.nativeVoices where voice.language == language {
                    try Task.checkCancellation()
                    let text = sources[language]!
                    let plan = try await pipeline.plan(text, model: .plus, bookID: "voice-bank", chapterID: language,
                        narratorVoiceID: voice.id, language: language, delivery: delivery)
                    guard plan.units.allSatisfy({ $0.voiceID == voice.id }) else { throw CTError.unsupportedVoice }
                    let begin = Date()
                    var samples: [Float] = []
                    for unit in plan.units { samples += try await renderer.render(unit, delivery: delivery) }
                    guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
                    let wav = output.appendingPathComponent("\(language)-\(voice.styleID).wav")
                    try write(samples, rate: 44_100, to: wav)
                    cases.append(["voiceID": voice.id, "engineVoiceID": voice.engineVoiceID, "language": language,
                        "text": text, "units": plan.units.count, "samples": samples.count,
                        "audioSeconds": Double(samples.count) / 44_100, "renderSeconds": Date().timeIntervalSince(begin),
                        "peak": samples.map(abs).max() ?? 0,
                        "audioSHA256": SHA256.hash(data: try Data(contentsOf: wav)).map { String(format: "%02x", $0) }.joined()])
                    let receipt: [String: Any] = ["modelIdentity": CTAssets.identity, "sampleRate": 44_100,
                        "loadSeconds": loadSeconds, "backend": "coreMLGPUHeavy", "rendererLoadCount": 1,
                        "pipelineRevision": NarrationPipeline.revision, "deliveryOptions": delivery.cacheIdentity,
                        "status": "native-render-validation-not-perceptual-acceptance", "cases": cases]
                    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent("receipt.json"), options: .atomic)
                    print("Rendered \(language) \(voice.styleID): \(samples.count) samples")
                }
            }
        } catch { await renderer.unload(); throw error }
        await renderer.unload()
    }
}
