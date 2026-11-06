// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
import CoreML
import Foundation
import KokoroPronunciation
@_exported import KokoroCatalog

public enum SynthesisError: Error, LocalizedError, Sendable {
    case invalidVoicePack, segmentTooLong, emptyPhonemes, invalidAudio
    case incompatibleVoiceAndLanguage, invalidSpeed, unknownVoice, unsupportedPlatform
    case unsupportedPronunciation
    case invalidDecoderAssets
    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: "Kokoro requires iOS or Mac Catalyst 18, or macOS 15 or later."
        case .invalidSpeed: "Speech speed must be between 0.5 and 2.0."
        case .unknownVoice: "Unknown Kokoro voice."
        case .invalidVoicePack: "The Kokoro voice file is invalid. Download the model again."
        case .segmentTooLong: "This passage exceeds the model's audio capacity."
        case .emptyPhonemes: "This text could not be pronounced in the selected language."
        case .invalidAudio: "Kokoro produced invalid or silent audio."
        case .incompatibleVoiceAndLanguage: "Choose a Kokoro voice for the selected language."
        case .unsupportedPronunciation: "The experimental pronunciation frontend could not represent all of this text."
        case .invalidDecoderAssets: "The fixed decoder assets are missing, incompatible, or failed integrity validation."
        }
    }
}

struct SegmentOutput: Sendable {
    let audio: [Float]
    let predDur: [Int]
    let decoderWindows: Int
    let maximumDecoderFrames: Int
    let fixedDecoderWindows: Int
    let shortDecoderWindows: Int
}

public struct Audio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

/// One engine serializes model loading, inference and unloading away from the UI actor.
/// Synthesis never downloads files and never owns an audio session.
public actor KokoroEngine {
    /// Independent pronunciation is opt-in until native listening checks pass.
    /// Both routes use the same bounded, background-compatible Core ML renderer.
    public enum PronunciationPolicy: Sendable { case established, independent }
    public enum RendererPolicy: Sendable {
        case established
        /// Opt-in original-weight decoder. Assets must be prepared explicitly.
        /// Always CPU-only; maximum 160 frames, exact-length short-input path.
        case fixedSize(directory: URL)
    }
    public enum ComputePolicy: Sendable {
        /// Default for audio apps that must continue synthesizing with the screen locked.
        case cpuOnly
        /// Foreground acceleration. Does not promise background GPU/ANE access.
        case automatic
    }
    public static let sampleRate = 24_000
    private let directory: URL
    private let policy: ComputePolicy
    private let pronunciationPolicy: PronunciationPolicy
    /// Explicit audiobook assets. The compact renderer remains the default.
    public struct NarrationConfiguration: Sendable {
        public let harmonicSource: URL
        public let frontend: URL?
        public init(harmonicSource: URL, frontend: URL? = nil) {
            self.harmonicSource = harmonicSource; self.frontend = frontend
        }
    }
    private let frontendURL: URL?
    private let rendererPolicy: RendererPolicy
    private var model: DynamicCoreMLModel?
    private var narrationExperiment = false
    private var experimentalHarmonicSourceURL: URL?
    private var voices: [String: VoicePack] = [:]
    private var phonemizer = Phonemizer()
    private var independentPhonemizer: PronunciationEngine?

    public init(modelDirectory: URL, computePolicy: ComputePolicy = .cpuOnly,
                pronunciationPolicy: PronunciationPolicy = .established,
                rendererPolicy: RendererPolicy = .established,
                narration: NarrationConfiguration? = nil) {
        directory = modelDirectory
        policy = computePolicy
        self.pronunciationPolicy = pronunciationPolicy
        self.rendererPolicy = rendererPolicy
        frontendURL = narration?.frontend
        experimentalHarmonicSourceURL = narration?.harmonicSource
        narrationExperiment = narration != nil
    }

    public func load() throws {
        guard model == nil else { return }
        if narrationExperiment {
            guard case .fixedSize = rendererPolicy else { throw SynthesisError.invalidDecoderAssets }
        }
        guard #available(iOS 18, macCatalyst 18, macOS 15, *) else {
            throw SynthesisError.unsupportedPlatform
        }
        model = try autoreleasepool {
            let fixedDirectory: URL?
            switch rendererPolicy {
            case .established: fixedDirectory = nil
            case .fixedSize(let directory): fixedDirectory = directory
            }
            return try DynamicCoreMLModel(directory: directory,
                computeUnits: policy == .cpuOnly ? .cpuOnly : .all, fixedDecoderDirectory: fixedDirectory,
                harmonicSourceURL: experimentalHarmonicSourceURL, narrationExperiment: narrationExperiment, frontendURL: frontendURL)
        }
    }

    /// Local benchmark only. Loading the candidate explicitly never changes the default renderer.
    /// Keeps inference CPU-only and retains the 160-frame decoder limit.
    @_spi(NarrationBenchmark)
    public func useExperimentalHarmonicSource(at url: URL) throws {
        guard case .fixedSize = rendererPolicy else { throw SynthesisError.invalidDecoderAssets }
        unload()
        experimentalHarmonicSourceURL = url
        narrationExperiment = false
    }

    /// Benchmark-only matching of the wider-overlap, half-voiced-noise candidate.
    @_spi(NarrationBenchmark)
    public func useNarrationExperiment(at sourceURL: URL) throws {
        try useExperimentalHarmonicSource(at: sourceURL)
        narrationExperiment = true
    }

    /// Render a bounded unit from BookNarrationPlanner with the configured
    /// audiobook renderer. The caller retains source offsets and voice identity.
    public func synthesizeNarration(_ phonemes: String, voiceID: String,
                                   styleRow: Int = 158, speed: Float = 1,
                                   pitchGestures: [NarrationPitchGesture] = [],
                                   voiceBlend: NarrationVoiceBlend? = nil) throws -> Audio {
        try synthesizePreparedNarration(phonemes, voiceID: voiceID, styleRow: styleRow, speed: speed,
                                       pitchGestures: pitchGestures, voiceBlend: voiceBlend)
    }

    /// Checked prepared input avoids silently changing the listening experiment's
    /// pronunciation or voice style row in the physical-device memory run.
    @_spi(NarrationBenchmark)
    public func synthesizePreparedNarration(_ phonemes: String, voiceID: String,
                                            styleRow: Int, speed: Float = 1,
                                            experimentalProsody: ExperimentalProsody = .neutral,
                                            experimentalNoiseSeed: UInt64? = nil,
                                            pitchGestures: [NarrationPitchGesture] = [],
                                            voiceBlend: NarrationVoiceBlend? = nil) throws -> Audio {
        try Task.checkCancellation()
        guard narrationExperiment, case .fixedSize = rendererPolicy else { throw SynthesisError.invalidDecoderAssets }
        guard Voice.named(voiceID) != nil else { throw SynthesisError.unknownVoice }
        guard speed.isFinite, (0.5...2).contains(speed) else { throw SynthesisError.invalidSpeed }
        guard (1...510).contains(phonemes.unicodeScalars.count), (0...510).contains(styleRow) else {
            throw SynthesisError.segmentTooLong
        }
        try load()
        guard let model, phonemes.unicodeScalars.allSatisfy({ model.vocab[String($0)] != nil }),
              phonemes.contains(where: { !$0.isWhitespace && !$0.isPunctuation }) else {
            throw SynthesisError.unsupportedPronunciation
        }
        let pack: VoicePack
        if let cached = voices[voiceID] { pack = cached }
        else {
            pack = try VoicePack(data: Data(contentsOf: directory.appendingPathComponent("voices/\(voiceID).bin")))
            voices = [voiceID: pack]
        }
        let style = try pack.style(phonemeCount: styleRow)
        if let blend = voiceBlend {
            guard blend.weight.isFinite, (0...0.5).contains(blend.weight),
                  let secondary = Voice.named(blend.secondaryVoiceID),
                  secondary.language == Voice.named(voiceID)?.language else {
                throw SynthesisError.incompatibleVoiceAndLanguage
            }
            if blend.weight > 0, blend.secondaryVoiceID != voiceID {
                let other: VoicePack
                if let cached = voices[blend.secondaryVoiceID] { other = cached }
                else { other = try VoicePack(data: Data(contentsOf: directory.appendingPathComponent("voices/\(blend.secondaryVoiceID).bin"))) }
                // At most two packs, independent of the number of book characters.
                voices = [voiceID: pack, blend.secondaryVoiceID: other]
                let reference = try other.style(phonemeCount: styleRow)
                for i in 0..<256 {
                    style[i] = NSNumber(value: style[i].floatValue * (1 - blend.weight)
                        + reference[i].floatValue * blend.weight)
                }
            }
        }
        let samples = try autoreleasepool {
            try model.forward(phonemes: phonemes, refS: style, speed: speed,
                              experimentalProsody: experimentalProsody,
                              experimentalNoiseSeed: experimentalNoiseSeed,
                              pitchGestures: pitchGestures).audio
        }
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              samples.contains(where: { abs($0) > 0.00001 }) else { throw SynthesisError.invalidAudio }
        return Audio(samples: samples, sampleRate: Self.sampleRate)
    }

    public func unload() {
        model = nil
        voices.removeAll()
        phonemizer = Phonemizer()
        independentPhonemizer = nil
    }

    public func synthesize(_ text: String, voiceID: String = "af_heart", speed: Float = 1) throws -> Audio {
        try Task.checkCancellation()
        guard speed.isFinite, (0.5...2).contains(speed) else { throw SynthesisError.invalidSpeed }
        guard let voice = Voice.named(voiceID) else { throw SynthesisError.unknownVoice }
        let phonemes: String
        if pronunciationPolicy == .independent {
            if independentPhonemizer == nil { independentPhonemizer = PronunciationEngine() }
            guard let language = PronunciationLanguage(rawValue: voice.language.rawValue) else {
                throw SynthesisError.incompatibleVoiceAndLanguage
            }
            let result = try independentPhonemizer!.phonemize(text, language: language,
                options: .init(britishEnglish: voice.isBritish))
            guard !result.diagnostics.contains(where: { $0.code == .unsupportedSymbol || $0.code == .unexpandedNumber }) else {
                throw SynthesisError.unsupportedPronunciation
            }
            phonemes = result.phonemes
        } else {
            phonemes = try phonemizer.phonemes(for: text, voice: voice)
        }
        try load()
        // Tokenize by Unicode scalar, preserving the model's exact vocabulary.
        let filtered = phonemes.unicodeScalars.filter { model?.vocab[String($0)] != nil }
            .map(String.init).joined()
        guard filtered.contains(where: { !$0.isWhitespace && !$0.isPunctuation }) else {
            throw SynthesisError.emptyPhonemes
        }
        let pack: VoicePack
        if let cached = voices[voiceID] { pack = cached }
        else {
            pack = try VoicePack(data: Data(contentsOf: directory.appendingPathComponent("voices/\(voiceID).bin")))
            // A user switching voices must not accumulate all voice arrays indefinitely.
            voices = [voiceID: pack]
        }
        // Preserve the whole sentence's context up to the model's native
        // 510-token limit. Decoder windows bound memory independently of text.
        let samples = try renderChunks(Self.chunks(filtered, limit: DynamicCoreMLModel.maxPhonemeCount), pack: pack, speed: speed)
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              samples.contains(where: { abs($0) > 0.00001 }) else { throw SynthesisError.invalidAudio }
        return Audio(samples: samples, sampleRate: Self.sampleRate)
    }

    private func renderChunks(_ chunks: [String], pack: VoicePack, speed: Float) throws -> [Float] {
        var samples: [Float] = []
        var previous = ""
        for chunk in chunks {
            try Task.checkCancellation()
            let rendered = try render(chunk, pack: pack, speed: speed)
            AudioJoiner.append(rendered, to: &samples, after: previous)
            previous = chunk
        }
        return samples
    }

    private func render(_ phonemes: String, pack: VoicePack, speed: Float) throws -> [Float] {
        try Task.checkCancellation()
        guard let model else { throw CocoaError(.fileNoSuchFile) }
        return try autoreleasepool {
            try model.forward(phonemes: phonemes, refS: pack.style(phonemeCount: phonemes.unicodeScalars.count), speed: speed).audio
        }
    }

    /// Bounded chunks without truncation. A punctuation/word boundary is preferred.
    static func chunks(_ text: String, limit: Int) -> [String] {
        precondition(limit > 0)
        let characters = Array(text.unicodeScalars)
        var result: [String] = []
        var start = 0
        while start < characters.count {
            var end = min(start + limit, characters.count)
            if end < characters.count, end - start > 2 {
                // Do not turn leading quotes/whitespace into a standalone
                // inference when an overlong word has no later boundary.
                let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
                let contentStart = (start..<end).first { !ignored.contains(characters[$0]) } ?? start
                let candidates = contentStart..<end
                // Punctuation is a stronger boundary than a later space. The
                // old combined predicate nearly always picked the latter.
                let boundary = candidates.last(where: { ".!?…。！？".unicodeScalars.contains(characters[$0]) })
                    ?? candidates.last(where: { ",;:—、；：".unicodeScalars.contains(characters[$0]) })
                    ?? candidates.last(where: { CharacterSet.whitespacesAndNewlines.contains(characters[$0]) })
                if let boundary { end = boundary + 1 }
            }
            result.append(String(String.UnicodeScalarView(characters[start..<end])))
            start = end
        }
        return result
    }
}
