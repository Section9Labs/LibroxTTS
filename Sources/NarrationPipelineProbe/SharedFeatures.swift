import CryptoKit
import Foundation
import LibroxTTS
import LibroxCTNative

extension NarrationPipelineProbe {
    static func nativeSharedFeatures(arguments: [String]) async throws {
        guard arguments.count == 2 else { throw CTError.invalidTensor("Usage: --native-shared-features ASSETS OUTPUT") }
        let assets = URL(fileURLWithPath: arguments[0]), output = URL(fileURLWithPath: arguments[1])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil)
        let pipeline = NarrationPipeline()
        let start = Date()
        try await renderer.load(.plus, directory: assets, executionContext: .foreground, repositoryID: CTAssets.identity)
        let loadSeconds = Date().timeIntervalSince(start)
        var records: [[String: Any]] = []
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        do {
            for (index, language) in NarrationModel.plus.supportedLanguageCodes.enumerated() {
                let style = CTAssets.styles[index % CTAssets.styles.count]
                let voice = "plus-\(style.lowercased())-\(language)-v1"
                guard let text = NarrationLanguage.sampleText(language) else { throw CTError.unsupportedLanguage }
                let plan = try await pipeline.plan(text, model: .plus, bookID: "shared-features", chapterID: language,
                    narratorVoiceID: voice, language: language, delivery: .init())
                var baseline: [Float] = [], mixed: [Float] = [], timed: [Float] = []
                var cadence = NarrationPlaybackCadence(model: .plus, nativeTiming: true)
                var inserted = 0
                let begin = Date()
                for unit in plan.units {
                    let natural = try await renderer.renderNativeDiagnostic(unit)
                    let blend = try await renderer.renderNativeDiagnostic(unit, delivery: .init(blendedVoice: true))
                    guard let noise = natural.native.trace["initial_latent"] else { throw CTError.invalidTensor("noise") }
                    let restored = try await renderer.renderNativeDiagnostic(unit, initialNoise: noise)
                    guard restored.samples == natural.samples,
                          restored.native.trace["style_ttl"]?.data == natural.native.trace["style_ttl"]?.data,
                          blend.native.trace["style_ttl"]?.data != natural.native.trace["style_ttl"]?.data,
                          blend.native.textContextDisposition == .absent else { throw CTError.invalidTensor("blend reset") }
                    guard natural.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
                          blend.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
                    baseline += natural.samples; mixed += blend.samples
                    var audio = natural.samples
                    inserted += cadence.apply(to: &audio, unit: unit, sampleRate: 44_100)
                    timed += audio
                }
                var files: [[String: Any]] = []
                for (label, audio) in [("original", baseline), ("blend", mixed), ("timing", timed)] {
                    let url = output.appendingPathComponent("\(language)-\(style)-\(label).wav")
                    try write(audio, rate: 44_100, to: url)
                    files.append(["kind": label, "path": url.lastPathComponent, "sha256": digest(try Data(contentsOf: url)),
                                  "samples": audio.count, "peak": audio.map(abs).max() ?? 0])
                }
                records.append(["language": language, "style": style, "source": text, "units": plan.units.count,
                    "resetPCMExactWithSuppliedNoise": true, "styleTablesChanged": true,
                    "timingInsertedSamples": inserted, "renderSeconds": Date().timeIntervalSince(begin), "files": files])
                let receipt: [String: Any] = ["modelIdentity": CTAssets.identity, "modelFingerprint": try CTTextContext.modelFingerprint(),
                    "pipelineRevision": NarrationPipeline.revision, "blendRevision": CTVoiceBlend.revision,
                    "binarySHA256": digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
                    "backend": "coreMLGPUHeavy", "loadSeconds": loadSeconds, "rendererLoadCount": 1,
                    "sampleRate": 44_100, "cases": records,
                    "scope": "Technical native blend and exact off-reset checks; not listening approval or matched-noise blend preference. Native timing stays opt-in; this short corpus may contain no seams."]
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("receipt.json"), options: .atomic)
                print("Validated \(language) \(style): original, blend, exact reset")
            }
        } catch { await renderer.unload(); throw error }
        await renderer.unload()
    }
}
