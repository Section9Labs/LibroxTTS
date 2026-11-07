import CryptoKit
import Foundation
import LibroxTTS
import LibroxCTNative

extension NarrationPipelineProbe {
    static func compareNativeContext(arguments: [String]) async throws {
        guard arguments.count == 5 else { throw CTError.invalidTensor("Usage: --native-context ASSETS OUTPUT LANGUAGE NARRATOR_ID PASSAGE.txt") }
        let assets = URL(fileURLWithPath: arguments[0]), output = URL(fileURLWithPath: arguments[1])
        let language = arguments[2], voice = arguments[3]
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
        guard let source = String(data: sourceData, encoding: .utf8), !FileManager.default.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "context-comparison", chapterID: "1",
            narratorVoiceID: voice, language: language, characterVoices: true)
        guard !plan.units.isEmpty else { throw CTError.emptyText }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let cast = plan.cast { try cast.encoded().write(to: output.appendingPathComponent("cast.json")) }
        let fingerprint = try CTTextContext.modelFingerprint()
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil)
        try await renderer.load(.plus, directory: assets, executionContext: .foreground)
        var baseline: [Float] = [], candidate: [Float] = []
        var records: [[String: Any]] = []
        var checkedIdentity = false
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        do {
            for (index, unit) in plan.units.enumerated() {
                guard let selectedVoice = NarrationModel.plus.nativeVoices.first(where: { $0.id == unit.voiceID }) else {
                    throw CTError.unsupportedVoice
                }
                let begin = Date()
                let control = try await renderer.renderNativeDiagnostic(unit)
                let baselineSeconds = Date().timeIntervalSince(begin)
                guard let noise = control.native.trace["initial_latent"] else { throw CTError.invalidTensor("missing diagnostic noise") }
                try noise.data.write(to: output.appendingPathComponent("noise-\(index).bin"))
                if !checkedIdentity {
                    var identityUnit = unit
                    identityUnit.nativeTextContext = try CTTextContext.bind(contextText: unit.synthesisText,
                        spokenRange: NSRange(location: 0, length: unit.synthesisText.utf16.count), spokenText: unit.synthesisText,
                        language: language, modelFingerprint: fingerprint, styleID: selectedVoice.styleID)
                    let identical = try await renderer.renderNativeDiagnostic(identityUnit, initialNoise: noise)
                    guard identical.native.textContextDisposition == .identity,
                          identical.native.samples == control.native.samples, identical.samples == control.samples else {
                        throw CTError.invalidTensor("identity context changed native samples")
                    }
                    // A valid binding for a different style must be ignored.
                    identityUnit.nativeTextContext = try CTTextContext.bind(contextText: unit.synthesisText,
                        spokenRange: NSRange(location: 0, length: unit.synthesisText.utf16.count), spokenText: unit.synthesisText,
                        language: language, modelFingerprint: fingerprint, styleID: "wrong-style")
                    let rejected = try await renderer.renderNativeDiagnostic(identityUnit, initialNoise: noise)
                    guard rejected.native.textContextDisposition == .rejected,
                          rejected.native.samples == control.native.samples, rejected.samples == control.samples else {
                        throw CTError.invalidTensor("rejected context changed native samples")
                    }
                    checkedIdentity = true
                }
                var changedUnit = unit
                var bindingFailure = ""
                if unit.role == .dialogue {
                    do {
                        changedUnit.nativeTextContext = try NarrationTextContext.surrounding(plan.units, index: index, source: source,
                            language: language, modelFingerprint: fingerprint, styleID: selectedVoice.styleID)
                    } catch { bindingFailure = String(describing: error) }
                }
                let useContext = changedUnit.nativeTextContext.map { !$0.isIdentity } ?? false
                let start = Date()
                let changed = useContext ? try await renderer.renderNativeDiagnostic(changedUnit, initialNoise: noise) : control
                let candidateSeconds = useContext ? Date().timeIntervalSince(start) : 0
                let invariantKeys = ["text_ids", "text_mask", "style_ttl", "style_dp", "duration", "text_emb_late", "initial_latent", "latent_mask"]
                for key in invariantKeys {
                    guard let a = control.native.trace[key], let b = changed.native.trace[key],
                          a.kind == b.kind, a.shape == b.shape, a.data == b.data else { throw CTError.invalidTensor("comparison invariant \(key)") }
                }
                guard changed.samples.count == control.samples.count,
                      changed.native.predictedDuration == control.native.predictedDuration,
                      changed.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
                guard let earlyControl = control.native.trace["text_emb_early"],
                      let earlyChanged = changed.native.trace["text_emb_early"] else { throw CTError.invalidTensor("missing early features") }
                let earlyA = try earlyControl.floats()
                let earlyB = try earlyChanged.floats()
                let difference = zip(earlyA, earlyB).map { Double($0) - Double($1) }
                let energy = earlyA.reduce(0.0) { $0 + Double($1) * Double($1) }
                let delta = sqrt(difference.reduce(0) { $0 + $1 * $1 } / max(energy, 1e-30))
                baseline += control.samples; candidate += changed.samples
                var row: [String: Any] = ["index": index, "sourceOffsetUTF16": unit.range.location, "sourceLengthUTF16": unit.range.length,
                    "role": unit.role.rawValue, "voiceID": unit.voiceID, "styleID": selectedVoice.styleID, "text": unit.synthesisText,
                    "noiseShape": noise.shape, "noiseSHA256": digest(noise.data), "noiseFile": "noise-\(index).bin",
                    "contextApplied": changed.native.textContextDisposition == .applied,
                    "contextDisposition": changed.native.textContextDisposition.rawValue, "bindingFailure": bindingFailure,
                    "candidateReusesBaseline": !useContext, "invariantTensorsExact": invariantKeys,
                    "relativeEarlyFeatureChange": delta, "audioSeconds": Double(control.samples.count) / 44_100,
                    "baselineRenderSeconds": baselineSeconds, "candidateRenderSeconds": candidateSeconds,
                    "baselineGraphSeconds": control.native.graphSeconds, "candidateGraphSeconds": changed.native.graphSeconds]
                if let binding = changedUnit.nativeTextContext {
                    let data = try JSONEncoder().encode(binding)
                    try data.write(to: output.appendingPathComponent("context-\(index).json"))
                    row["bindingSHA256"] = digest(data)
                }
                records.append(row)
            }
        } catch { await renderer.unload(); throw error }
        await renderer.unload()
        let baselineURL = output.appendingPathComponent("baseline.wav"), candidateURL = output.appendingPathComponent("context.wav")
        try write(baseline, rate: 44_100, to: baselineURL)
        try write(candidate, rate: 44_100, to: candidateURL)
        let pair = baseline + [Float](repeating: 0, count: 35_280) + candidate
        let pairURL = output.appendingPathComponent("baseline-then-context.wav")
        try write(pair, rate: 44_100, to: pairURL)
        let manifest = try CTAssets.manifest()
        let receipt: [String: Any] = ["source": source, "sourceSHA256": digest(sourceData), "language": language,
            "sourceModelIdentity": manifest.identity, "modelFingerprint": fingerprint,
            "assetFiles": manifest.files.map { ["path": $0.path, "sha256": $0.sha256] },
            "pipelineRevision": NarrationPipeline.revision, "contextRevision": CTTextContext.revision,
            "deliveryIdentity": NarrationModel.plus.deliveryIdentity, "sampleRate": 44_100,
            "identityAndRejectedContextNativePCMExact": checkedIdentity, "allInvariantTensorsExact": true,
            "spokenDurationIdentical": true, "records": records,
            "baselineFile": baselineURL.path, "baselineSHA256": digest(try Data(contentsOf: baselineURL)),
            "candidateFile": candidateURL.path, "candidateSHA256": digest(try Data(contentsOf: candidateURL)),
            "pairFile": pairURL.path, "pairSHA256": digest(try Data(contentsOf: pairURL)), "comparisonGapSeconds": 0.8,
            "binarySHA256": digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "backend": "Core ML GPU-heavy production SDK with supplied noise; no ASR or extra pitch/tempo/gain processing",
            "scope": "Context-gather diagnostic, default off; native DK pacing. No DL, semantic-emotion, phone-speed or listening acceptance claim."]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("receipt.json"))
        let affected = records.filter { $0["contextApplied"] as? Bool == true }.count
        print("Native context comparison: \(affected) affected units; \(pairURL.path)")
    }
}
