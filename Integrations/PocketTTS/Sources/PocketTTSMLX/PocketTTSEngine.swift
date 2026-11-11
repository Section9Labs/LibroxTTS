// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog
import MLX

public enum PocketTTSError: LocalizedError {
    case emptyText, textTooLong, invalidVoice, unsupportedLanguage, invalidAssets, invalidAudio, invalidSamplerSteps
    public var errorDescription: String? {
        switch self {
        case .emptyText: "There is no text to speak."
        case .textTooLong: "This passage exceeds the bounded Max input or audio limit. Split it into shorter passages."
        case .invalidVoice: "This voice is not in the Max catalog."
        case .unsupportedLanguage: "Max does not support this language."
        case .invalidAssets: "The Max language pack is missing or invalid. Download it again."
        case .invalidAudio: "Max did not produce valid audio."
        case .invalidSamplerSteps: "Max sampler steps must be between 1 and 8."
        }
    }
}

/// Serialized native Swift MLX owner. MLX arrays and caches never cross this actor.
/// Foreground and granted background work may use GPU; other background work uses CPU.
/// Backend changes retire all model and RNG state before creating new operations.
public actor PocketTTSEngine {
    public static let runtimeIdentity = PocketTTSBackend.mlx.runtimeIdentity
    public enum Backend: String, Codable, Sendable { case gpu, cpu }
    public private(set) var backend: Backend
    private var randomState: MLXRandom.RandomState?
    private var randomSeed: UInt64?
    private var hasAllocated = false
    private var activeSamplerSteps: Int?
    private var diagnostics: (@Sendable (PocketTTSResourceSnapshot) -> Void)?
    public func setResourceObserver(_ observer: (@Sendable (PocketTTSResourceSnapshot) -> Void)?) {
        diagnostics = observer
    }
    private var resources: PocketTTSResourceMonitor {
        .init(backend: backend.rawValue, samplerSteps: activeSamplerSteps,
              tokenCount: model?.diagnosticTokenCount, frameIndex: model?.diagnosticFrameIndex, observe: diagnostics)
    }
    public struct Output: Sendable { public let samples: [Float]; public let sampleRate: Int }
    private let directory: URL
    private var model: PocketTTSModel?
    private var language: String?
    /// The language whose model is held in memory, or nil.
    public var loadedLanguage: String? { language }
    /// CPU duty cycle for `.cpu` renders on iOS; nil = unmetered. Default 0.5.
    public private(set) var cpuBudgetFraction: Double? = PocketCPUWorkBudget.defaultFraction
    public func setCPUBudgetFraction(_ fraction: Double?) { cpuBudgetFraction = fraction }
        public init(directory: URL, backend: Backend = .gpu) {
        self.directory = directory; self.backend = backend
    }
    public func unload() {
        model = nil; language = nil; randomState = nil
        // A never-loaded engine must not initialize Metal just to unload.
        if hasAllocated { Memory.clearCache(); hasAllocated = false }
    }
    /// Call after cancelling and awaiting an in-flight render. Actor serialization
    /// also prevents backend replacement while a synchronous frame is evaluating.
    public func setBackend(_ value: Backend) {
        guard value != backend else { return }
        unload()
        backend = value
    }
    /// Reproducible audition seed, isolated from other MLX engines in the process.
    public func setRandomSeed(_ seed: UInt64) {
        randomSeed = seed; randomState = nil
    }
    private func onBackend<R>(_ body: (PocketCPUWorkBudget?) throws -> R) throws -> R {
        try Device.withDefaultDevice(backend == .cpu ? .cpu : .gpu) {
            hasAllocated = true
            if randomState == nil {
                randomState = randomSeed.map(MLXRandom.RandomState.init(seed:)) ?? MLXRandom.RandomState()
            }
            return try withRandomState(randomState!) {
                defer {
                    // Do not retain unevaluated RNG splits on the previous device.
                    if Task.isCancelled { randomState = nil }
                    else if let randomState { eval(randomState) }
                    Memory.clearCache()
                }
                do {
                    try resources.checkpoint("operation-start")
                    let result = try body(PocketCPUWorkBudget.backgroundBudget(cpu: backend == .cpu, fraction: cpuBudgetFraction))
                    try Task.checkCancellation()
                    diagnostics?(resources.snapshot("operation-complete"))
                    return result
                } catch {
                    // Model.render resets streaming state on every exit. Failed
                    // operations also discard loaded weights/RNG before returning.
                    model = nil; language = nil; randomState = nil
                    Stream.defaultStream.synchronize()
                    Memory.clearCache()
                    diagnostics?(resources.snapshot(Task.isCancelled ? "cancelled-retired" : "failed-retired"))
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
        }
    }
    public func synthesize(_ text: String, voiceID: String, temperature: Float = 0.3,
                           continueChunks: Bool = true, chunking: PocketTTSChunkingOptions = .init(),
                           role: PocketTTSPassageRole = .narration,
                           samplerSteps: Int = PocketTTSSamplingOptions.defaultSamplerSteps,
                           deliveryStyle: PocketTTSDeliveryStyle = .original) throws -> Output {
        try chunking.validate()
        guard (1...8).contains(samplerSteps) else { throw PocketTTSError.invalidSamplerSteps }
        try PocketTTSSamplingOptions(temperature: temperature, samplerSteps: samplerSteps).validate()
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        let stateName = try PocketTTSDeliveryCatalog.stateName(voiceID: voiceID, style: deliveryStyle)
        try PocketTTSDeliveryCatalog.validate(deliveryStyle, voiceID: voiceID, in: directory)
        guard text.unicodeScalars.count <= 16_384 else { throw PocketTTSError.textTooLong }
        try Task.checkCancellation()
        activeSamplerSteps = samplerSteps
        defer { activeSamplerSteps = nil }
        return try onBackend { budget in
            let model = try loadedModel(language: voice.language)
            model.temp = temperature
            model.lsd_decode_steps = samplerSteps
            var samples: [Float] = []
            try model.render(text: text, voice: stateName, continuation: continueChunks, chunking: chunking,
                             role: role, language: voice.language, checkpoint: { try self.resources.checkpoint($0) }) { chunk in
                guard samples.count + chunk.count <= 24_000 * 300 else { throw PocketTTSError.textTooLong }
                samples += chunk
                try budget?.checkpoint()
            }
            guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw PocketTTSError.invalidAudio }
            return Output(samples: samples, sampleRate: model.sampleRate)
        }
    }
    /// Frame callbacks are synchronous and apply backpressure. The consumer must
    /// discard staged output on errors/cancellation; only success completes a unit.
    public func renderFrames(_ text: String, voiceID: String, temperature: Float = 0.3,
                             continueChunks: Bool = true,
                             chunking: PocketTTSChunkingOptions = .init(),
                             role: PocketTTSPassageRole = .narration,
                             samplerSteps: Int = PocketTTSSamplingOptions.defaultSamplerSteps,
                             deliveryStyle: PocketTTSDeliveryStyle = .original,
                             onTextChunk: @Sendable (PocketTTSChunkProgress) throws -> Void = { _ in },
                             receive: @Sendable ([Float]) throws -> Void) throws {
        try chunking.validate()
        guard (1...8).contains(samplerSteps) else { throw PocketTTSError.invalidSamplerSteps }
        try PocketTTSSamplingOptions(temperature: temperature, samplerSteps: samplerSteps).validate()
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        let stateName = try PocketTTSDeliveryCatalog.stateName(voiceID: voiceID, style: deliveryStyle)
        try PocketTTSDeliveryCatalog.validate(deliveryStyle, voiceID: voiceID, in: directory)
        guard text.unicodeScalars.count <= 16_384 else { throw PocketTTSError.textTooLong }
        try Task.checkCancellation()
        activeSamplerSteps = samplerSteps
        defer { activeSamplerSteps = nil }
        return try onBackend { budget in
            let model = try loadedModel(language: voice.language)
            model.temp = temperature
            model.lsd_decode_steps = samplerSteps
            var sampleCount = 0
            try model.render(text: text, voice: stateName, continuation: continueChunks,
                             chunking: chunking, role: role, language: voice.language, checkpoint: { try self.resources.checkpoint($0) },
                             onTextChunk: onTextChunk) { chunk in
                guard sampleCount + chunk.count <= 24_000 * 300 else { throw PocketTTSError.textTooLong }
                sampleCount += chunk.count
                try budget?.checkpoint()
                try receive(chunk)
            }
        }
    }
    /// Inspect the same token-aware decisions used by synthesis before generating audio.
    public func previewChunks(_ text: String, voiceID: String,
                              chunking: PocketTTSChunkingOptions = .init(),
                              role: PocketTTSPassageRole = .narration) throws -> [PocketTTSTextChunk] {
        return try onBackend { _ in
            try chunking.validate()
            guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
            return try loadedModel(language: voice.language).chunkPlan(text: text, language: voice.language,
                                                                      role: role, options: chunking)
        }
    }

    private func loadedModel(language requested: String) throws -> PocketTTSModel {
        if language != requested {
            model = nil; language = nil
            Memory.clearCache()
            try Task.checkCancellation()
            try PocketTTSCatalog.validate(in: directory, language: requested)
            let modelDirectory = directory.appendingPathComponent(requested)
            let bytes = try modelDirectory.appendingPathComponent("model.safetensors")
                .resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            // Allow mapped weights plus conversion/evaluation overlap at load.
            try resources.checkpoint("before-load", additionalBytes: PocketTTSResourceMonitor.loadReservation(fileBytes: UInt64(max(0, bytes))))
            model = try PocketTTSModel.fromModelDirectory(modelDirectory,
                checkpoint: { try self.resources.checkpoint($0) })
            try resources.checkpoint("after-load")
            language = requested
        }
        guard let model else { throw PocketTTSError.invalidAssets }
        return model
    }
}
