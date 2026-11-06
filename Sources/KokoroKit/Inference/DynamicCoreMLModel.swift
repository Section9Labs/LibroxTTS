// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
// Inference contract adapted from Jud/kokoro-coreml (Apache-2.0).
// See THIRD_PARTY_NOTICES.md. Actor ownership replaces upstream locking.
import CoreML
import Foundation

final class DynamicCoreMLModel {
    private let frontend: MLModel
    private let backend: DecoderBackend
    private let usesFixedDecoder: Bool
    private let narrationExperiment: Bool
    private let harmonicSource: ExperimentalHarmonicSource?
    let vocab: [String: Int]
    static let maxPhonemeCount = 510

    init(directory: URL, computeUnits: MLComputeUnits, fixedDecoderDirectory: URL? = nil,
         harmonicSourceURL: URL? = nil, narrationExperiment: Bool = false, frontendURL: URL? = nil) throws {
        self.narrationExperiment = narrationExperiment
        guard let url = Bundle.module.url(forResource: "vocab", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        vocab = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url))
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        harmonicSource = try harmonicSourceURL.map { try ExperimentalHarmonicSource(url: $0, halfVoicedNoise: narrationExperiment) }
        frontend = try MLModel(contentsOf: frontendURL ?? directory.appendingPathComponent("kokoro_frontend.mlmodelc"), configuration: config)
        usesFixedDecoder = fixedDecoderDirectory != nil
        backend = try DecoderBackend(directory: directory, computeUnits: computeUnits, fixedDirectory: fixedDecoderDirectory)
    }

    func forward(phonemes: String, refS: MLMultiArray, speed: Float,
                 experimentalProsody: ExperimentalProsody = .neutral,
                 experimentalNoiseSeed: UInt64? = nil,
                 pitchGestures: [NarrationPitchGesture] = []) throws -> SegmentOutput {
        if experimentalNoiseSeed != nil {
            guard narrationExperiment, harmonicSource != nil else { throw SynthesisError.invalidDecoderAssets }
        }
        let ids = [0] + phonemes.unicodeScalars.compactMap { vocab[String($0)] } + [0]
        guard ids.count <= Self.maxPhonemeCount + 2 else { throw SynthesisError.segmentTooLong }
        let count = NSNumber(value: ids.count)
        let input = try array([1, count], values: ids.map(Float.init), type: .int32)
        let mask = try array([1, count], values: Array(repeating: 1, count: ids.count), type: .int32)
        let speedInput = try array([1], values: [speed])
        var inputs: [String: MLMultiArray] = ["input_ids": input, "attention_mask": mask,
            "ref_s": refS, "speed": speedInput]
        if frontend.modelDescription.inputDescriptionsByName["random_phases"] != nil {
            let phases: [Float]
            if let seed = experimentalNoiseSeed {
                var generator = GaussianNoise(seed: seed ^ 0x504841534553)
                phases = (0..<9).map { _ in Float(generator.uniform() * 2 * Double.pi) }
            } else {
                phases = (0..<9).map { _ in Float.random(in: 0..<(2 * .pi)) }
            }
            inputs["random_phases"] = try array([1, 9], values: phases)
        }
        let front = try frontend.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        try Task.checkCancellation()
        // Predict pitch, duration and harmonic phase ONCE for the entire input.
        // Window only the decoder, never the linguistic/prosody frontend.
        let style = try array([1, 128], values: (0..<128).map { refS[$0].floatValue })
        var features: [String: MLMultiArray] = [:]
        for name in ["asr", "F0_pred", "N_pred"] {
            guard let value = front.featureValue(for: name)?.multiArrayValue else { throw SynthesisError.invalidAudio }
            features[name] = value
        }
        guard let frames = features["asr"]?.shape.last?.intValue,
              (1...4096).contains(frames),
              features["F0_pred"]?.shape.last?.intValue == frames * 2,
              features["N_pred"]?.shape.last?.intValue == frames * 2 else { throw SynthesisError.invalidAudio }
        let valid = frames * DecoderWindow.samplesPerFrame
        if let lengths = front.featureValue(for: "audio_length_samples")?.multiArrayValue,
           lengths[0].intValue != valid { throw SynthesisError.invalidAudio }
        if experimentalProsody != .neutral {
            guard narrationExperiment, harmonicSource != nil, let pitch = features["F0_pred"] else {
                throw SynthesisError.invalidDecoderAssets
            }
            features["F0_pred"] = try experimentalProsody.adjusted(pitch)
        }
        if !pitchGestures.isEmpty {
            guard narrationExperiment, harmonicSource != nil,
                  let pitch = features["F0_pred"],
                  let durations = front.featureValue(for: "pred_dur_clamped")?.multiArrayValue else {
                throw SynthesisError.invalidDecoderAssets
            }
            features["F0_pred"] = try NarrationAcoustics.adjusted(pitch, durations: durations,
                phonemeCount: ids.count - 2, gestures: pitchGestures)
        }
        if let harmonicSource, let pitch = features["F0_pred"] {
            features["har"] = try autoreleasepool { try harmonicSource.predict(pitch: pitch, seed: experimentalNoiseSeed) }
        } else {
            features["har"] = front.featureValue(for: "har")?.multiArrayValue
        }
        guard features["har"]?.shape.last?.intValue == frames * 120 + 1 else { throw SynthesisError.invalidAudio }
        let windows = DecoderWindow.plan(totalFrames: frames, context: narrationExperiment ? 40 : 20, blend: narrationExperiment ? 2400 : 480)
        var samples: [Float] = []
        samples.reserveCapacity(valid)
        for window in windows {
            try Task.checkCancellation()
            let decoded: [Float] = try autoreleasepool {
                var inputs: [String: MLFeatureValue] = ["s_content": MLFeatureValue(multiArray: style)]
                for (name, feature) in features {
                    let scale = name == "har" ? 120 : (name == "asr" ? 1 : 2)
                    let end = window.frames.upperBound * scale + (name == "har" ? 1 : 0)
                    let slice = try FeatureWindow.slice(feature, time: (window.frames.lowerBound * scale)..<end)
                    inputs[name] = MLFeatureValue(multiArray: slice)
                }
                let back = try backend.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs), frames: window.frames.count)
                guard let audio = back.featureValue(for: "audio")?.multiArrayValue,
                      audio.count >= window.frames.count * DecoderWindow.samplesPerFrame else {
                    throw SynthesisError.invalidAudio
                }
                let offset = window.frames.lowerBound * DecoderWindow.samplesPerFrame
                let range = (window.output.lowerBound - offset)..<(window.output.upperBound - offset)
                // Scalar indexing respects any strides supplied by Core ML.
                return range.map { audio[$0].floatValue }
            }
            DecoderWindow.append(decoded, at: window.output.lowerBound, to: &samples)
        }
        guard samples.count == valid else { throw SynthesisError.invalidAudio }
        let durations = front.featureValue(for: "pred_dur_clamped")?.multiArrayValue
        let predicted = durations.map { values in (0..<min(values.count, ids.count)).map { values[$0].intValue } } ?? []
        // Token 0 is a boundary token with its own duration. Keep 40 ms of
        // boundary context instead of cutting exactly at the predicted edge.
        let leading = max(0, (predicted.first ?? 0) * 600 - 960)
        let trailing = max(0, (predicted.last ?? 0) * 600 - 960)
        if leading + trailing < samples.count {
            samples = Array(samples[leading..<(samples.count - trailing)])
        }
        return SegmentOutput(audio: samples, predDur: predicted, decoderWindows: windows.count,
                             maximumDecoderFrames: windows.map { $0.frames.count }.max() ?? 0,
                             fixedDecoderWindows: usesFixedDecoder ? windows.filter { $0.frames.count == 160 }.count : 0,
                             shortDecoderWindows: usesFixedDecoder ? windows.filter { $0.frames.count < 160 }.count : 0)
    }

    private func array(_ shape: [NSNumber], values: [Float], type: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: type)
        guard array.count == values.count else { throw SynthesisError.invalidAudio }
        for i in values.indices { array[i] = NSNumber(value: values[i]) }
        return array
    }
}
