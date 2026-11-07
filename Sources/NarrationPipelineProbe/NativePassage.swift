import Foundation
import CryptoKit
import LibroxTTS
import LibroxCTNative

extension NarrationPipelineProbe {
    /// One production rendering path. No legacy planning, ASR, audition gain,
    /// pitch/time processing or inferred parity with historical reference audio.
    static func nativePassage(arguments: [String], characterVoices: Bool = false) async throws {
        guard arguments.count == 5 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                "Usage: narration-pipeline-probe --native ASSETS OUTPUT LANGUAGE VOICE_ID PASSAGE.txt"])
        }
        let assets = URL(fileURLWithPath: arguments[0])
        let output = URL(fileURLWithPath: arguments[1])
        let language = arguments[2], requestedVoice = arguments[3]
        let source = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
        guard let text = String(data: source, encoding: .utf8),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let delivery = NarrationDeliveryOptions(expressive: true)
        let plan = try await NarrationPipeline().plan(text, model: .plus,
            bookID: "native-comparison", chapterID: "passage", narratorVoiceID: requestedVoice,
            language: language, characterVoices: characterVoices, delivery: delivery)
        guard plan.narratorVoiceID == requestedVoice, !plan.units.isEmpty,
              let voice = NarrationModel.plus.nativeVoices.first(where: { $0.id == requestedVoice }) else {
            throw CTError.unsupportedVoice
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Match the host contract: persist new assignments before their first audio.
        if let cast = plan.cast {
            try cast.encoded().write(to: output.appendingPathComponent("cast.json"), options: .atomic)
        }
        let manifest = try CTAssets.manifest()
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil)
        let started = Date()
        try await renderer.load(.plus, directory: assets, executionContext: .foreground)
        let loaded = Date()
        var samples: [Float] = []
        var units: [[String: Any]] = []
        do {
            for unit in plan.units {
                guard let unitVoice = NarrationModel.plus.nativeVoices.first(where: { $0.id == unit.voiceID }) else {
                    throw CTError.unsupportedVoice
                }
                let begin = Date()
                let audio = try await renderer.render(unit, delivery: delivery)
                guard !audio.isEmpty, audio.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
                samples += audio
                units.append(["sourceOffsetUTF16": unit.range.location, "sourceLengthUTF16": unit.range.length,
                    "voiceID": unit.voiceID, "engineVoiceID": unitVoice.engineVoiceID,
                    "speakerID": unit.speakerID ?? "", "role": unit.role.rawValue,
                    "synthesisText": unit.synthesisText,
                    "samples": audio.count, "renderSeconds": Date().timeIntervalSince(begin)])
            }
        } catch { await renderer.unload(); throw error }
        await renderer.unload()
        let wav = output.appendingPathComponent("native.wav")
        try write(samples, rate: Double(NarrationModel.plus.outputSampleRate), to: wav)
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let receipt: [String: Any] = [
            "modelIdentity": manifest.identity, "sourceManifestSHA256": manifest.referenceManifestSHA256,
            "assetFiles": manifest.files.map { ["path": $0.path, "sha256": $0.sha256] },
            "sourceSHA256": digest(source), "source": text, "language": plan.language,
            "voiceID": requestedVoice, "styleID": voice.styleID, "engineVoiceID": voice.engineVoiceID,
            "characterVoices": characterVoices,
            "pipelineRevision": NarrationPipeline.revision, "deliveryIdentity": NarrationModel.plus.deliveryIdentity,
            "deliveryOptions": delivery.cacheIdentity, "backend": "coreMLGPUHeavy",
            "sampleRate": NarrationModel.plus.outputSampleRate, "sampleCount": samples.count,
            "audioSeconds": Double(samples.count) / Double(NarrationModel.plus.outputSampleRate),
            "loadSeconds": loaded.timeIntervalSince(started), "totalSeconds": Date().timeIntervalSince(started),
            "units": units, "audioSHA256": digest(try Data(contentsOf: wav)),
            "pacing": "DK with native pacing; DL not implemented",
            "noise": "Production random noise; no deterministic parity claim",
            "processing": "Production CTDelivery nativeDynamics only; no additional audition processing",
            "status": "native-render-complete-not-listening-qualified"
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("receipt.json"), options: .atomic)
        print("Native \(voice.styleID) \(plan.language): \(samples.count) samples in \(plan.units.count) units; \(wav.path)")
    }
}
