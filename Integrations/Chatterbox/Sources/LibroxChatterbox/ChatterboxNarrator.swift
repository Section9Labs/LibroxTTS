import Foundation
import CoreML
import ChatterboxCoreML
import PerthCoreML
import KokoroNarration
import CryptoKit

public enum ChatterboxNarrationError: Error, Equatable, Sendable {
    case emptyText, textTooLong, unsupportedLanguage(String), invalidOptions
    case invalidAudio, invalidSampleRate(Int), notLoaded, busy, wrongModelVariant
    case missingLocalFile(String), diagnosticEnvironmentEnabled
    case generationLimitReached, missingVoiceConditioning(String), invalidSourceRange, sourceTextMismatch
    case unverifiedGPUTokenizer
    case invalidBatch
}

/// A bounded natural-text request. Language identifiers belong to Chatterbox,
/// not Kokoro's phoneme vocabulary or Qwen's language-name catalog.
public struct ChatterboxRequest: Sendable {
    public static let languages: Set<String> = [
        "ar", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "it", "ja",
        "ko", "ms", "nl", "no", "pl", "pt", "ru", "sv", "sw", "tr", "zh",
    ]
    public let text: String
    public let language: String
    /// Upstream voice-conditioning safetensors; nil selects the installed default.
    public let conditioningFile: URL?
    public let exaggeration: Float
    public let guidance: Float
    public let temperature: Float
    public let maxTokens: Int
    public let seed: UInt64?
    public let sourceContext: ChatterboxSourceContext?

    public init(text: String, language: String, conditioningFile: URL? = nil,
                exaggeration: Float = 0.5, guidance: Float = 0.5,
                temperature: Float = 0.8, maxTokens: Int = 350,
                seed: UInt64? = nil, sourceContext: ChatterboxSourceContext? = nil) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatterboxNarrationError.emptyText
        }
        // Reject instead of silently truncating a chapter. The caller owns source ranges.
        guard text.utf8.count <= 8_000, text.count <= 2_000 else {
            throw ChatterboxNarrationError.textTooLong
        }
        guard Self.languages.contains(language) else {
            throw ChatterboxNarrationError.unsupportedLanguage(language)
        }
        guard exaggeration.isFinite, (0...2).contains(exaggeration),
              guidance.isFinite, (0...2).contains(guidance),
              temperature.isFinite, (0.1...2).contains(temperature),
              (2...1_000).contains(maxTokens) else {
            throw ChatterboxNarrationError.invalidOptions
        }
        self.text = text; self.language = language; self.conditioningFile = conditioningFile
        self.exaggeration = exaggeration; self.guidance = guidance
        self.temperature = temperature; self.maxTokens = maxTokens; self.seed = seed
        self.sourceContext = sourceContext
    }

    var options: GenerationOptions {
        .multilingual(language: language, exaggeration: exaggeration, cfgWeight: guidance,
                      temperature: temperature, maxTokens: maxTokens, seed: seed)
    }
}

/// Upstream stage measurements in seconds. Excludes model loading and host playback;
/// stages may overlap across chunks, so their sum is not total request wall time.
public struct ChatterboxChunkTimings: Sendable {
    public let prefillSeconds: TimeInterval
    public let decodeSeconds: TimeInterval
    public let synthSeconds: TimeInterval
    public let watermarkSeconds: TimeInterval
    public let speechTokens: Int
    public let decodeBackend: String
    public var hostAssemblySeconds: TimeInterval = 0
    public var conditioningCacheHit: Bool? = nil
    public var acoustics: ChatterboxAcousticTimings? = nil
    /// Present only for the explicit decode profiling diagnostic.
    public var decodeSteps: DecodeStepTimings? = nil
    public init(prefillSeconds: TimeInterval, decodeSeconds: TimeInterval, synthSeconds: TimeInterval,
                watermarkSeconds: TimeInterval, speechTokens: Int, decodeBackend: String,
                hostAssemblySeconds: TimeInterval = 0, conditioningCacheHit: Bool? = nil,
                decodeSteps: DecodeStepTimings? = nil) {
        self.prefillSeconds = prefillSeconds; self.decodeSeconds = decodeSeconds; self.synthSeconds = synthSeconds
        self.watermarkSeconds = watermarkSeconds; self.speechTokens = speechTokens; self.decodeBackend = decodeBackend
        self.hostAssemblySeconds = hostAssemblySeconds; self.conditioningCacheHit = conditioningCacheHit; self.decodeSteps = decodeSteps
    }
}

public struct ChatterboxAudioChunk: Sendable {
    public static let expectedSampleRate = 24_000
    public let samples: [Float]
    public let sampleRate: Int
    public let timings: ChatterboxChunkTimings?
    public init(samples: [Float], sampleRate: Int = 24_000,
                timings: ChatterboxChunkTimings? = nil) throws {
        guard sampleRate == Self.expectedSampleRate else {
            throw ChatterboxNarrationError.invalidSampleRate(sampleRate)
        }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw ChatterboxNarrationError.invalidAudio
        }
        self.samples = samples; self.sampleRate = sampleRate
        self.timings = timings
    }
}

public struct ChatterboxBatchChunk: Sendable {
    public let requestIndex: Int
    public let chunkIndex: Int
    public let isFinalChunk: Bool
    /// The original immutable request, including source/cast/performance metadata.
    public let request: ChatterboxRequest
    public let audio: ChatterboxAudioChunk
    public init(requestIndex: Int, chunkIndex: Int, isFinalChunk: Bool,
                request: ChatterboxRequest, audio: ChatterboxAudioChunk) {
        self.requestIndex = requestIndex; self.chunkIndex = chunkIndex; self.isFinalChunk = isFinalChunk
        self.request = request; self.audio = audio
    }
}

/// Optional Core ML backend. Owns no audio session, downloads, playback, or Kokoro state.
/// The busy lease spans suspension points so model streams cannot overlap.
public actor ChatterboxNarrator {
    public typealias Renderer = @Sendable (ChatterboxRequest) async throws -> ChatterboxAudioChunk
    typealias Source = @Sendable (ChatterboxRequest) -> AsyncThrowingStream<ChatterboxAudioChunk, Error>
    public typealias BatchSource = @Sendable ([ChatterboxRequest], @escaping @Sendable (ChatterboxBatchChunk) async throws -> Void) async throws -> Void
    private var source: Source?
    private var batchSource: BatchSource?
    private var occupied = false
    private var renderer: Renderer?
    /// Successful T3 load configuration; Core ML may still place operations on CPU.
    public private(set) var selectedT3ComputeUnits: String?
    public init() {}
    /// An alternative decoder can use the same source bridge and lookahead cache.
    /// Direct awaited calls preserve cancellation and busy-lease lifetime.
    public init(rendering: @escaping Renderer) { renderer = rendering }
    public init(rendering: @escaping Renderer, batchRendering: @escaping BatchSource) {
        renderer = rendering; batchSource = batchRendering
    }
    init(source: @escaping Source) { self.source = source }
    init(batchSource: @escaping BatchSource) { self.batchSource = batchSource }

    public enum ComputePolicy: Sendable { case automatic, cpuOnly, neuralEngine, gpu }

    public func load(modelDirectory: URL, watermarkDirectory: URL,
                     computePolicy: ComputePolicy = .automatic,
                     t3ComputeUnits: MLComputeUnits? = nil,
                     padFlowToMaximum: Bool? = nil) async throws {
        guard !occupied else { throw ChatterboxNarrationError.busy }
        guard source == nil, renderer == nil else { return }
        occupied = true; defer { occupied = false }
        try Task.checkCancellation()
        // Reject decode-only benchmark mode rather than returning empty synthesis.
        guard ProcessInfo.processInfo.environment["CHATTERBOX_SKIP_SYNTH"] == nil else {
            throw ChatterboxNarrationError.diagnosticEnvironmentEnabled
        }
        try Self.requireFile(modelDirectory.appendingPathComponent("perceiver_query.npy"))
        let units: MLComputeUnits
        switch computePolicy {
        case .automatic: units = .all
        case .cpuOnly: units = .cpuOnly
        case .neuralEngine: units = .cpuAndNeuralEngine
        case .gpu: units = .cpuAndGPU
        }
        // Construct locally: upstream's default makeOrFallback may download weights
        // or silently omit watermarking. Loading failure here is an explicit error.
        let watermark = try PerthWatermarker(modelDirectory: watermarkDirectory, computeUnits: units)
        // Nil overrides preserve upstream placement and its T3 load recovery.
        // Explicit .all disables that recovery and is not equivalent to automatic.
        let model = try await ChatterboxCoreMLModel.load(from: modelDirectory,
            watermarker: PerthWatermark(watermarker: watermark),
            computeUnits: Self.pipelineComputeUnits(for: computePolicy, t3Override: t3ComputeUnits), padFlowToMaximum: padFlowToMaximum)
        guard model.loadedVariant == .multilingual else { throw ChatterboxNarrationError.wrongModelVariant }
        try Task.checkCancellation()
        selectedT3ComputeUnits = model.selectedT3ComputeUnits
        source = { request in
            let upstream = model.generateStream(request.text, voice: request.conditioningFile, options: request.options)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await value in upstream {
                            try Task.checkCancellation()
                            guard value.tokenCount < request.maxTokens else {
                                throw ChatterboxNarrationError.generationLimitReached
                            }
                            let timings = ChatterboxChunkTimings(prefillSeconds: value.prefillTime,
                                decodeSeconds: value.decodeTime, synthSeconds: value.synthTime,
                                watermarkSeconds: value.watermarkTime, speechTokens: value.tokenCount,
                                decodeBackend: value.decodeBackend.rawValue,
                                hostAssemblySeconds: value.hostAssemblyTime,
                                conditioningCacheHit: value.conditioningCacheHit, decodeSteps: value.decodeStepTimings)
                            let chunk = try ChatterboxAudioChunk(samples: value.samples, timings: timings)
                            if case .terminated = continuation.yield(chunk) { break }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        batchSource = { requests, receive in
            let units = requests.map {
                ChatterboxCoreMLModel.BatchRequest(text: $0.text, voice: $0.conditioningFile, options: $0.options)
            }
            try await model.generateBatch(units) { chunk in
                let value = chunk.audio
                let timings = ChatterboxChunkTimings(prefillSeconds: value.prefillTime,
                    decodeSeconds: value.decodeTime, synthSeconds: value.synthTime,
                    watermarkSeconds: value.watermarkTime, speechTokens: value.tokenCount,
                    decodeBackend: value.decodeBackend.rawValue,
                    hostAssemblySeconds: value.hostAssemblyTime,
                    conditioningCacheHit: value.conditioningCacheHit, decodeSteps: value.decodeStepTimings)
                let audio = try ChatterboxAudioChunk(samples: value.samples, timings: timings)
                try await receive(ChatterboxBatchChunk(requestIndex: chunk.requestIndex,
                    chunkIndex: chunk.chunkIndex, isFinalChunk: chunk.isFinalChunk,
                    request: requests[chunk.requestIndex], audio: audio))
            }
        }
    }

    static func pipelineComputeUnits(for policy: ComputePolicy,
                                     t3Override: MLComputeUnits? = nil) -> PipelineComputeUnits {
        var result: PipelineComputeUnits = switch policy {
        case .automatic: .init()
        case .neuralEngine: .neuralEngine // retain the unsafe-on-ANE encoder on CPU
        case .cpuOnly:
            .init(t3: .cpuOnly, encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly)
        case .gpu:
            .init(t3: .cpuAndGPU, encoder: .cpuAndGPU, cfm: .cpuAndGPU,
                  vocoder: .cpuAndGPU, watermark: .cpuAndGPU)
        }
        if let t3Override { result.t3 = t3Override }
        return result
    }

    public func unload() throws {
        guard !occupied else { throw ChatterboxNarrationError.busy }
        source = nil
        renderer = nil
        batchSource = nil
        selectedT3ComputeUnits = nil
    }

    /// Ordered chunks; cancellation of the calling task propagates upstream.
    /// The caller must await this operation before unloading/replacing the backend.
    public func stream(_ request: ChatterboxRequest,
                       receive: @Sendable (ChatterboxAudioChunk) async throws -> Void) async throws {
        guard !occupied else { throw ChatterboxNarrationError.busy }
        guard source != nil || renderer != nil else { throw ChatterboxNarrationError.notLoaded }
        occupied = true; defer { occupied = false }
        try Task.checkCancellation()
        if let voice = request.conditioningFile { try Self.requireFile(voice) }
        if let renderer {
            let audio = try await renderer(request)
            try Task.checkCancellation()
            try await receive(audio)
            try Task.checkCancellation()
            return
        }
        var received = false
        for try await chunk in source!(request) {
            try Task.checkCancellation()
            try await receive(chunk)
            received = true
        }
        try Task.checkCancellation()
        guard received else { throw ChatterboxNarrationError.invalidAudio }
    }

    /// Opt-in cross-unit overlap. One decoder and one synthesizer are active at
    /// most, with two decoded chunks queued. No text merging or silence injection.
    /// Await this operation before unloading; cancellation joins both legs after
    /// the current Core ML call returns. A host must also cooperate in `receive`.
    public func streamBatch(_ requests: [ChatterboxRequest],
                            receive: @escaping @Sendable (ChatterboxBatchChunk) async throws -> Void) async throws {
        guard !occupied else { throw ChatterboxNarrationError.busy }
        guard (1...8).contains(requests.count),
              requests.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768 else {
            throw ChatterboxNarrationError.invalidBatch
        }
        guard batchSource != nil || renderer != nil else { throw ChatterboxNarrationError.notLoaded }
        occupied = true; defer { occupied = false }
        try Task.checkCancellation()
        for request in requests {
            if let voice = request.conditioningFile { try Self.requireFile(voice) }
        }
        if let batchSource { try await batchSource(requests, receive) }
        else if let renderer {
            // Direct renderers provide one complete bounded unit per call.
            // They share the same cache/identity contract without replicating models.
            for (index, request) in requests.enumerated() {
                try Task.checkCancellation()
                let audio = try await renderer(request)
                try Task.checkCancellation()
                try await receive(.init(requestIndex: index, chunkIndex: 0, isFinalChunk: true, request: request, audio: audio))
            }
        }
        try Task.checkCancellation()
    }

    /// Conditioning creation is a separate explicit operation and needs five
    /// additional encoder assets. Existing output files are never overwritten.
    public func prepareReference(audioFile: URL, modelsDirectory: URL, outputFile: URL,
                                 computePolicy: ComputePolicy = .neuralEngine,
                                 modelComputeUnits: [String: MLComputeUnits] = [:]) async throws {
        guard !occupied else { throw ChatterboxNarrationError.busy }
        occupied = true; defer { occupied = false }
        try Task.checkCancellation(); try Self.requireFile(audioFile)
        guard !FileManager.default.fileExists(atPath: outputFile.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let units: MLComputeUnits = switch computePolicy {
        case .automatic: .all
        case .cpuOnly: .cpuOnly
        case .neuralEngine: .cpuAndNeuralEngine
        case .gpu: .cpuAndGPU
        }
        var perModel = modelComputeUnits
        let tokenizerUnits = perModel["S3Tokenizer"] ?? units
        if tokenizerUnits == .all || tokenizerUnits == .cpuAndGPU {
            let repaired = try Self.hasValidatedGPUTokenizer(in: modelsDirectory)
            if !repaired, computePolicy == .automatic, perModel["S3Tokenizer"] == nil {
                // The original dynamic-RoPE gather crashes MPS. Automatic retains
                // GPU placement for other reference models, but uses CPU here.
                perModel["S3Tokenizer"] = .cpuOnly
            } else if !repaired { throw ChatterboxNarrationError.unverifiedGPUTokenizer }
        }
        let cloner = try await VoiceCloner(modelDirectory: modelsDirectory, computeUnits: units,
            encoderConditioningSeconds: 6, modelComputeUnits: perModel)
        try Task.checkCancellation()
        try cloner.cloneVoice(from: audioFile, to: outputFile)
        try Task.checkCancellation()
    }

    private static func requireFile(_ url: URL) throws {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw ChatterboxNarrationError.missingLocalFile(url.path)
        }
    }

    /// Audited equivalent RoPE-prefix repair; learned weights must remain exact.
    /// This allowlist applies to the reviewed .mlpackage only, not arbitrary exports.
    private static func hasValidatedGPUTokenizer(in directory: URL) throws -> Bool {
        let root = directory.appendingPathComponent("S3Tokenizer.mlpackage/Data/com.apple.CoreML")
        func digest(_ url: URL) throws -> String {
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            var hash = SHA256()
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard FileManager.default.isReadableFile(atPath: root.appendingPathComponent("model.mlmodel").path) else { return false }
        guard try digest(root.appendingPathComponent("model.mlmodel")) == "e869885d4e03bbcd2462422b0589ebd5c6f8b8f4893fbc3f25b6f8ccb61b279a" else { return false }
        return try digest(root.appendingPathComponent("weights/weight.bin")) == "3c80a10d8e75f79cc5e500c5e07c50db43e4ac27a60925d98130a882579713da"
    }
}
