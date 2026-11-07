// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog
import MLX

public enum PocketTTSError: LocalizedError {
    case emptyText, textTooLong, invalidVoice, unsupportedLanguage, invalidAssets, invalidAudio, invalidSamplerSteps
    public var errorDescription: String? {
        switch self {
        case .emptyText: "There is no text to speak."
        case .textTooLong: "This passage exceeds the bounded Pocket TTS input or audio limit. Split it into shorter passages."
        case .invalidVoice: "This voice is not in the Pocket TTS catalog."
        case .unsupportedLanguage: "Pocket TTS does not support this language."
        case .invalidAssets: "The Pocket TTS language pack is missing or invalid. Download it again."
        case .invalidAudio: "Pocket TTS did not produce valid audio."
        case .invalidSamplerSteps: "Pocket TTS sampler steps must be between 1 and 8."
        }
    }
}

/// Serialized native Swift MLX owner. MLX arrays and caches never cross this actor.
/// GPU generation is foreground/preparation-only until physical-device qualification.
public actor PocketTTSEngine {
    public static let runtimeIdentity = "pocket-mlx-28770c06-v3:quality4:adaptive:warm12:eos6:fp32"
    public struct Output: Sendable { public let samples: [Float]; public let sampleRate: Int }
    private let directory: URL
    private var model: PocketTTSModel?
    private var language: String?
    public init(directory: URL) { self.directory = directory }
    public func unload() { model = nil; language = nil }
    public func synthesize(_ text: String, voiceID: String, temperature: Float = 0.3,
                           continueChunks: Bool = true, chunking: PocketTTSChunkingOptions = .init(),
                           role: PocketTTSPassageRole = .narration,
                           samplerSteps: Int = PocketTTSSamplingOptions.defaultSamplerSteps) throws -> Output {
        try chunking.validate()
        guard (1...8).contains(samplerSteps) else { throw PocketTTSError.invalidSamplerSteps }
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        guard text.unicodeScalars.count <= 16_384 else { throw PocketTTSError.textTooLong }
        let model = try loadedModel(language: voice.language)
        model.temp = temperature
        model.lsd_decode_steps = samplerSteps
        var samples: [Float] = []
        try model.render(text: text, voice: voice.name, continuation: continueChunks, chunking: chunking,
                         role: role, language: voice.language) { chunk in
            guard samples.count + chunk.count <= 24_000 * 300 else { throw PocketTTSError.textTooLong }
            samples += chunk
        }
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw PocketTTSError.invalidAudio }
        return Output(samples: samples, sampleRate: model.sampleRate)
    }
    /// Frame callbacks are synchronous and apply backpressure. The consumer must
    /// discard staged output on errors/cancellation; only success completes a unit.
    public func renderFrames(_ text: String, voiceID: String,
                             chunking: PocketTTSChunkingOptions = .init(),
                             role: PocketTTSPassageRole = .narration,
                             samplerSteps: Int = PocketTTSSamplingOptions.defaultSamplerSteps,
                             receive: @Sendable ([Float]) throws -> Void) throws {
        try chunking.validate()
        guard (1...8).contains(samplerSteps) else { throw PocketTTSError.invalidSamplerSteps }
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        let model = try loadedModel(language: voice.language)
        model.temp = 0.3
        model.lsd_decode_steps = samplerSteps
        try model.render(text: text, voice: voice.name, chunking: chunking, role: role,
                         language: voice.language, onChunk: receive)
    }
    /// Inspect the same token-aware decisions used by synthesis before generating audio.
    public func previewChunks(_ text: String, voiceID: String,
                              chunking: PocketTTSChunkingOptions = .init(),
                              role: PocketTTSPassageRole = .narration) throws -> [PocketTTSTextChunk] {
        try chunking.validate()
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        return try loadedModel(language: voice.language).chunkPlan(text: text, language: voice.language,
                                                                  role: role, options: chunking)
    }

    private func loadedModel(language requested: String) throws -> PocketTTSModel {
        if language != requested {
            model = nil; language = nil
            try PocketTTSCatalog.validate(in: directory, language: requested)
            model = try PocketTTSModel.fromModelDirectory(directory.appendingPathComponent(requested))
            language = requested
        }
        guard let model else { throw PocketTTSError.invalidAssets }
        return model
    }
}
