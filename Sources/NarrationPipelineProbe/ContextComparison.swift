import CryptoKit
import Foundation
import LibroxTTS
import LibroxCTNative

extension NarrationPipelineProbe {
    static func compareNativeContext(arguments: [String]) async throws {
        guard arguments.count == 5 || (8...10).contains(arguments.count) else {
            throw CTError.invalidTensor("Usage: --native-context ASSETS OUTPUT LANGUAGE NARRATOR_ID PASSAGE.txt [STYLE_GRAPHS MANIFEST_SHA256 CHARACTER_VOICE_OR_DASH [SHARED_NOISE_DIRECTORY [CARRY_MODE]]]")
        }
        let assets = URL(fileURLWithPath: arguments[0]), output = URL(fileURLWithPath: arguments[1])
        let language = arguments[2], voice = arguments[3]
        let sourceData = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
        guard let source = String(data: sourceData, encoding: .utf8), !FileManager.default.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let carryValue = arguments.count == 10 ? arguments[9] : "disabled"
        guard let carryMode = CTContextStyleDiagnostic.CarryMode(rawValue: carryValue) else {
            throw CTError.invalidTensor("unknown context carry mode")
        }
        var plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "context-comparison", chapterID: "1",
            narratorVoiceID: voice, language: language, characterVoices: true)
        if arguments.count >= 8, arguments[7] != "-" {
            guard var cast = plan.cast, !cast.characters.isEmpty else {
                throw CTError.invalidTensor("diagnostic pinned character requires identified speakers")
            }
            for character in cast.characters { try cast.setVoice(arguments[7], for: character.id) }
            plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "context-comparison", chapterID: "1",
                narratorVoiceID: voice, language: language, cast: cast, characterVoices: true)
        }
        guard !plan.units.isEmpty else { throw CTError.emptyText }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let cast = plan.cast { try cast.encoded().write(to: output.appendingPathComponent("cast.json")) }
        let fingerprint = try CTTextContext.modelFingerprint()
        let sharedNoise = arguments.count >= 9 ? URL(fileURLWithPath: arguments[8]) : nil
        if let sharedNoise { try FileManager.default.createDirectory(at: sharedNoise, withIntermediateDirectories: true) }
        struct SavedNoise: Codable { let shape: [Int]; let data: Data }
        var bindings: [Int: CTTextContext.Binding] = [:]
        var roleEvidence: [String: CTRolePoolEvidence] = [:]
        var reportingEvidence: [String: CTReportingPoolEvidence] = [:]
        var bindingFailures: [Int: String] = [:]
        for (index, unit) in plan.units.enumerated() where unit.role == .dialogue {
            guard let selected = NarrationModel.plus.nativeVoices.first(where: { $0.id == unit.voiceID }) else { throw CTError.unsupportedVoice }
            do {
                let binding = try NarrationTextContext.surrounding(plan.units, index: index, source: source,
                    language: language, modelFingerprint: fingerprint, styleID: selected.styleID)
                bindings[index] = binding
                let roles = try Self.roleEvidence(units: plan.units, index: index, source: source, binding: binding)
                roleEvidence[binding.renderCacheKey] = roles
                reportingEvidence[binding.renderCacheKey] = NarrationReportingContext.evidence(units: plan.units, index: index,
                    source: source, roleEvidence: roles, decisions: plan.bookPlan?.attribution?.decisions ?? [])
            } catch { bindingFailures[index] = String(describing: error) }
        }
        let evidenceEncoder = JSONEncoder(); evidenceEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let evidenceData = try evidenceEncoder.encode(roleEvidence)
        try evidenceData.write(to: output.appendingPathComponent("role-evidence.json"))
        let evaluations = try roleEvidence.mapValues { try $0.evaluated() }
        try evidenceEncoder.encode(evaluations).write(to: output.appendingPathComponent("role-evaluation.json"))
        let reportingData = try evidenceEncoder.encode(reportingEvidence)
        try reportingData.write(to: output.appendingPathComponent("reporting-evidence.json"))
        let reportingEvaluations = try reportingEvidence.mapValues { evidence in
            try evidence.evaluated(roleEvidence: roleEvidence[evidence.binding.renderCacheKey]!)
        }
        try evidenceEncoder.encode(reportingEvaluations).write(to: output.appendingPathComponent("reporting-evaluation.json"))
        if ProcessInfo.processInfo.environment["LIBROX_ROLE_PLAN_ONLY"] == "1" {
            let unitRows: [[String: Any]] = plan.units.enumerated().map { index, unit in
                ["index": index, "text": unit.synthesisText, "sourceText": unit.text, "role": unit.role.rawValue,
                 "voiceID": unit.voiceID, "speakerID": unit.speakerID ?? "", "range": [unit.range.location, unit.range.length],
                 "binding": bindings[index]?.renderCacheKey ?? "", "failure": bindingFailures[index] ?? ""]
            }
            try JSONSerialization.data(withJSONObject: unitRows, options: [.sortedKeys, .prettyPrinted])
                .write(to: output.appendingPathComponent("plan.json"))
            return
        }
        let graphObject: [String: Any] = arguments.count >= 8
            ? (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[5]).appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]) : [:]
        let usesRoleEvidence = graphObject["rolePoolMode"] != nil
        let diagnostic = arguments.count >= 8 ? CTContextStyleDiagnostic.Configuration(
            directory: URL(fileURLWithPath: arguments[5]), manifestSHA256: arguments[6], carryMode: carryMode,
            roleEvidence: usesRoleEvidence ? roleEvidence : [:],
            reportingEvidence: graphObject["reportingPoolMode"] != nil ? reportingEvidence : [:]) : nil
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil, contextStyleDiagnostic: diagnostic)
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
                let noiseKey = digest(try JSONEncoder().encode([fingerprint, language, unit.voiceID, unit.synthesisText]))
                let savedNoiseURL = sharedNoise?.appendingPathComponent(noiseKey + ".json")
                var replayNoise: CTTensor?
                if let savedNoiseURL, FileManager.default.fileExists(atPath: savedNoiseURL.path) {
                    let saved = try JSONDecoder().decode(SavedNoise.self, from: Data(contentsOf: savedNoiseURL))
                    replayNoise = try CTTensor(shape: saved.shape, kind: .float32, data: saved.data)
                }
                let begin = Date()
                let control = try await renderer.renderNativeDiagnostic(unit, initialNoise: replayNoise)
                let baselineSeconds = Date().timeIntervalSince(begin)
                guard let noise = control.native.trace["initial_latent"] else { throw CTError.invalidTensor("missing diagnostic noise") }
                if let savedNoiseURL, replayNoise == nil {
                    try JSONEncoder().encode(SavedNoise(shape: noise.shape, data: noise.data)).write(to: savedNoiseURL, options: .atomic)
                }
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
                let bindingFailure = bindingFailures[index] ?? ""
                changedUnit.nativeTextContext = bindings[index]
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
                let joinedOffset = candidate.count
                guard control.native.samples.count == control.samples.count,
                      changed.native.samples.count == changed.samples.count,
                      changed.samples.count == noise.shape.last! * 3072,
                      try changed.native.trace["waveform"]?.floats() == changed.native.samples else {
                    throw CTError.invalidTensor("native frame preservation")
                }
                for (name, audio) in [("baseline-native", control.native.samples), ("baseline-delivered", control.samples),
                                      ("context-native", changed.native.samples), ("context-delivered", changed.samples)] {
                    try write(audio, rate: 44_100, to: output.appendingPathComponent("unit-\(index)-\(name).wav"))
                }
                baseline += control.samples; candidate += changed.samples
                var row: [String: Any] = ["index": index, "sourceOffsetUTF16": unit.range.location, "sourceLengthUTF16": unit.range.length,
                    "role": unit.role.rawValue, "voiceID": unit.voiceID, "styleID": selectedVoice.styleID, "text": unit.synthesisText,
                    "noiseShape": noise.shape, "noiseSHA256": digest(noise.data), "noiseFile": "noise-\(index).bin",
                    "sharedNoiseKey": noiseKey,
                    "predictedDuration": changed.native.predictedDuration, "latentFrames": noise.shape.last!,
                    "nativeSampleCount": changed.native.samples.count, "deliveredSampleCount": changed.samples.count,
                    "joinedOffsetSamples": joinedOffset, "nativeToDeliveredCountExact": true,
                    "nativePCM32SHA256": changed.native.samples.withUnsafeBytes { digest(Data($0)) },
                    "baselinePCM32SHA256": control.samples.withUnsafeBytes { digest(Data($0)) },
                    "candidatePCM32SHA256": changed.samples.withUnsafeBytes { digest(Data($0)) },
                    "candidateTensorDigests": changed.native.trace.mapValues { tensor in
                        ["shape": tensor.shape, "kind": tensor.kind.rawValue,
                         "bytes": tensor.data.count, "sha256": digest(tensor.data)] as [String: Any]
                    },
                    "contextApplied": changed.native.textContextDisposition == .applied,
                    "contextDisposition": changed.native.textContextDisposition.rawValue, "bindingFailure": bindingFailure,
                    "candidateReusesBaseline": !useContext, "invariantTensorsExact": invariantKeys,
                    "relativeEarlyFeatureChange": delta, "audioSeconds": Double(control.samples.count) / 44_100,
                    "baselineRenderSeconds": baselineSeconds, "candidateRenderSeconds": candidateSeconds,
                    "baselineGraphSeconds": control.native.graphSeconds, "candidateGraphSeconds": changed.native.graphSeconds]
                row["generatorStepsObserved"] = changed.native.trace.keys.filter { $0.hasPrefix("latent_after_step_") }.count
                if let payload = changed.native.trace["context_carry_payload_bytes"] {
                    let values = try payload.floats().map(Int.init)
                    guard values.count == 5 else { throw CTError.invalidTensor("context carry payload receipt") }
                    row["contextCarryPayloadBytes"] = ["inputSnapshots": values[0], "temporaryFloatArrays": values[1],
                        "newUnpaddedTensorData": values[2], "retainedPaddedConditions": values[3], "referenceFeature": values[4]]
                    row["contextCarryPayloadScope"] = "Exact payload allocation categories, not resident peak; tracing retains extra diagnostic copies"
                }
                if let residual = changed.native.trace["context_carry_residual"] {
                    let values = try residual.floats()
                    row["contextCarryResidualRMS"] = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count))
                    row["contextCarryResidualMaxAbs"] = values.map(abs).max() ?? 0
                }
                if let mask = changed.native.trace["terminal_keep"],
                   let spokenQuery = changed.native.trace["second_111"],
                   let acceptedQuery = changed.native.trace["context_style_combined_2"],
                   let selectedQuery = changed.native.trace["terminal_selected_query"] {
                    let keep = try mask.floats(), own = try spokenQuery.floats(), accepted = try acceptedQuery.floats()
                    let selected = try selectedQuery.floats()
                    guard own.count == 256, accepted.count == 256, selected.count == keep.count * 256 else {
                        throw CTError.invalidTensor("terminal query dimensions")
                    }
                    var protectedChange: Float = 0
                    for token in keep.indices {
                        guard keep[token] == 0 || keep[token] == 1 else { throw CTError.invalidTensor("terminal selector value") }
                        for channel in 0..<256 {
                            let expected = keep[token] == 1 ? accepted[channel] : own[channel]
                            guard selected[token * 256 + channel] == expected else { throw CTError.invalidTensor("terminal selection exactness") }
                            if keep[token] == 0 { protectedChange = max(protectedChange, abs(expected - accepted[channel])) }
                        }
                    }
                    row["terminalProtectedIndices"] = keep.indices.filter { keep[$0] == 0 }
                    row["terminalInputBytes"] = mask.data.count
                    row["terminalSelectedQueryBytes"] = selectedQuery.data.count
                    row["terminalQuerySelectionExact"] = true
                    row["terminalProtectedQueryMaxChange"] = protectedChange
                }
                if let binding = changedUnit.nativeTextContext {
                    let data = try JSONEncoder().encode(binding)
                    try data.write(to: output.appendingPathComponent("context-\(index).json"))
                    row["bindingSHA256"] = digest(data)
                    if let evidence = roleEvidence[binding.renderCacheKey] {
                        row["roleEvidenceIdentity"] = evidence.identity
                        row["roleEvaluation"] = try JSONSerialization.jsonObject(with: evidenceEncoder.encode(evidence.evaluated()))
                    }
                    if let reporting = reportingEvidence[binding.renderCacheKey], let roles = roleEvidence[binding.renderCacheKey] {
                        row["reportingEvidenceIdentity"] = reporting.identity
                        row["reportingEvaluation"] = try JSONSerialization.jsonObject(with: evidenceEncoder.encode(reporting.evaluated(roleEvidence: roles)))
                    }
                    if let role = changed.native.trace["role_pool_mask"] { row["actualRolePoolMask"] = try role.floats() }
                    if let local = changed.native.trace["context_spoken_content"] {
                        row["contextLocalInputBytes"] = local.data.count
                    }
                    if let pool = changed.native.trace["quote_pool_mask"] {
                        let values = try pool.floats()
                        let scalars = Array(binding.normalizedContext.unicodeScalars)
                        guard values.count == scalars.count else { throw CTError.invalidTensor("quote pool receipt count") }
                        row["quotePoolInputBytes"] = pool.data.count
                        row["quotePoolIncludedIndices"] = values.indices.filter { values[$0] == 1 }
                        row["quotePoolExcludedIndices"] = values.indices.filter { values[$0] == 0 }
                        row["quotePoolText"] = String(String.UnicodeScalarView(values.indices.filter { values[$0] == 1 }.map { scalars[$0] }))
                    }
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
            "contextMethod": diagnostic == nil ? "whole-context-gather" : "context-style-queries-isolated-content",
            "contextStyleManifestSHA256": diagnostic?.manifestSHA256 ?? "",
            "roleEvidenceSHA256": digest(evidenceData), "reportingEvidenceSHA256": digest(reportingData),
            "reportingPoolMode": graphObject["reportingPoolMode"] ?? "absent",
            "reportingPoolRevision": graphObject["reportingPoolRevision"] ?? "absent",
            "contextCarryMode": carryMode.rawValue, "contextCarryRevision": CTContextStyleDiagnostic.carryRevision,
            "diagnosticIdentity": diagnostic?.diagnosticIdentity ?? "",
            "scope": "Default-off native context diagnostic; native DK pacing. No DL, semantic-emotion, phone-speed or listening acceptance claim."]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent("receipt.json"))
        let affected = records.filter { $0["contextApplied"] as? Bool == true }.count
        print("Native context comparison: \(affected) affected units; \(pairURL.path)")
    }
    private static func roleEvidence(units: [BookNarrationUnit], index: Int, source: String,
                                     binding: CTTextContext.Binding) throws -> CTRolePoolEvidence {
        let original = source as NSString
        var matches: [[CTRolePoolEvidence.Span]] = []
        for low in max(0, index - 2)...index {
            for high in index...min(units.count - 1, index + 2) {
                var assembled = "", spans: [CTRolePoolEvidence.Span] = [], selectedOffset = -1, valid = true
                for position in low...high {
                    let unit = units[position]
                    guard unit.range.location >= 0, unit.range.length > 0,
                          unit.range.location <= original.length, unit.range.length <= original.length - unit.range.location,
                          original.substring(with: unit.range) == unit.text else { valid = false; break }
                    if position > low {
                        let priorEnd = NSMaxRange(units[position - 1].range)
                        guard priorEnd <= unit.range.location else { valid = false; break }
                        let gap = original.substring(with: NSRange(location: priorEnd, length: unit.range.location - priorEnd))
                        guard !gap.contains(where: \.isNewline) else { valid = false; break }
                        assembled += gap
                    }
                    if position == index { selectedOffset = assembled.utf16.count }
                    spans.append(.init(offsetUTF16: assembled.utf16.count, lengthUTF16: unit.synthesisText.utf16.count,
                        text: unit.synthesisText, role: unit.role.rawValue))
                    assembled += unit.synthesisText
                }
                if valid, assembled == binding.contextText, selectedOffset == binding.spokenOffsetUTF16 {
                    matches.append(spans)
                }
            }
        }
        guard matches.count == 1, let spans = matches.first else { throw CTError.invalidTensor("ambiguous role window") }
        return CTRolePoolEvidence(binding: binding, spans: spans)
    }

}
