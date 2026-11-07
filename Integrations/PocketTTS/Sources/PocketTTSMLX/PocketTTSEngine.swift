// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog
import MLX

public enum PocketTTSError: LocalizedError {
    case emptyText, textTooLong, invalidVoice, unsupportedLanguage, invalidAssets, invalidAudio
    public var errorDescription: String? {
        switch self {
        case .emptyText: "There is no text to speak."
        case .textTooLong: "This passage exceeds the bounded Pocket TTS input or audio limit. Split it into shorter passages."
        case .invalidVoice: "This voice is not in the Pocket TTS catalog."
        case .unsupportedLanguage: "Pocket TTS does not support this language."
        case .invalidAssets: "The Pocket TTS language pack is missing or invalid. Download it again."
        case .invalidAudio: "Pocket TTS did not produce valid audio."
        }
    }
}

/// Serialized native Swift MLX owner. MLX arrays and caches never cross this actor.
/// GPU generation is foreground/preparation-only until physical-device qualification.
public actor PocketTTSEngine {
    public static let runtimeIdentity = "pocket-mlx-28770c06-v1:tf25:warm12:eos6:fp32"
    public struct Output: Sendable { public let samples: [Float]; public let sampleRate: Int }
    private let directory: URL
    private var model: PocketTTSModel?
    private var language: String?
    public init(directory: URL) { self.directory = directory }
    public func unload() { model = nil; language = nil }
    public func synthesize(_ text: String, voiceID: String, temperature: Float = 0.3,
                           continueChunks: Bool = true) throws -> Output {
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        guard text.unicodeScalars.count <= 16_384 else { throw PocketTTSError.textTooLong }
        if language != voice.language {
            model = nil; language = nil
            try PocketTTSCatalog.validate(in: directory, language: voice.language)
            model = try PocketTTSModel.fromModelDirectory(directory.appendingPathComponent(voice.language))
            language = voice.language
        }
        guard let model else { throw PocketTTSError.invalidAssets }
        model.temp = temperature
        var samples: [Float] = []
        try model.render(text: text, voice: voice.name, continuation: continueChunks) { chunk in
            guard samples.count + chunk.count <= 24_000 * 300 else { throw PocketTTSError.textTooLong }
            samples += chunk
        }
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw PocketTTSError.invalidAudio }
        return Output(samples: samples, sampleRate: model.sampleRate)
    }
    /// Frame callbacks are synchronous and apply backpressure. The consumer must
    /// discard staged output on errors/cancellation; only success completes a unit.
    public func renderFrames(_ text: String, voiceID: String,
                             receive: @Sendable ([Float]) throws -> Void) throws {
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        if language != voice.language {
            model = nil; language = nil
            try PocketTTSCatalog.validate(in: directory, language: voice.language)
            model = try PocketTTSModel.fromModelDirectory(directory.appendingPathComponent(voice.language))
            language = voice.language
        }
        guard let model else { throw PocketTTSError.invalidAssets }
        model.temp = 0.3
        try model.render(text: text, voice: voice.name, onChunk: receive)
    }
}
