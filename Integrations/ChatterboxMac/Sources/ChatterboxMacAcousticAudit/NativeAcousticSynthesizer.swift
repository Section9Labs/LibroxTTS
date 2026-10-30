#if os(macOS)
import Foundation
import CryptoKit
import MLX
import MLXNN
import ChatterboxCoreML

/// Opt-in Mac candidate. Production/readiness requires complete-pipeline listening
/// and performance validation; the default Standard backend is unchanged.
public actor ChatterboxMacAcousticSynthesizer: ChatterboxAcousticSynthesizing {
    public nonisolated static let revision = "native-s3gen-f32-cpustate-cfg07-steps10-vocoder42-trim960-1"
    public nonisolated static let stockSHA256 = "5fef40319194272ac3ca10f02cd02e69b51ccb587f9b33357901a04605cdb68d"
    public nonisolated let watermarkPolicy: ChatterboxWatermarkPolicy = .disabled
    public nonisolated let profileIdentifier: String
    private let processLease: UUID
    private let loaded: NativeAcousticModel
    private let voice: URL
    private var occupied = false

    public init(checkpoint: URL, metallib: URL, stockConditioning: URL,
                waveformPolicy: NativeAcousticWaveformPolicy = .legacyAtomic) throws {
        self.voice = stockConditioning
        try Self.hostHealth(); try Self.verifyStock(stockConditioning)
        let lease = try NativeAcousticProcessLease.shared.acquire()
        do {
            loaded = try NativeAcousticModel(checkpoint: checkpoint, metallib: metallib, waveformPolicy: waveformPolicy, check: Self.health)
            try Self.health()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let state = SHA256.hash(data: try encoder.encode(loaded.report.derivedSHA256)).map { String(format: "%02x", $0) }.joined()
            profileIdentifier = Self.revision + "-" + loaded.report.checkpointSHA256 + "-" + state +
                (waveformPolicy == .legacyAtomic ? "" : "-" + waveformPolicy.rawValue)
            processLease = lease
        } catch {
            NativeAcousticProcessLease.shared.release(lease)
            throw error
        }
    }
    deinit { NativeAcousticProcessLease.shared.release(processLease) }

    public nonisolated func backend() throws -> ChatterboxAcousticBackend {
        try .init(identifier: profileIdentifier, watermarkPolicy: watermarkPolicy, synthesizer: self)
    }
    public func loadingReport() throws -> Data { try JSONEncoder().encode(loaded.report) }

    public func renderMeasured(tokens: [Int], conditioningFile: URL? = nil) throws -> ChatterboxAcousticOutput {
        guard !occupied, !tokens.isEmpty, tokens.count <= 350,
              tokens.allSatisfy({ (0..<6561).contains($0) }) else { throw AcousticInventoryError.input }
        occupied = true; defer { occupied = false }
        try Self.health(); try loaded.verify()
        let selected = conditioningFile ?? voice; try Self.verifyStock(selected)
        let began = Date()
        var timings = ChatterboxAcousticTimings()
        timings.generatedTokens = tokens.count
        timings.windows = 1; timings.flowPredictions = 20
        let generated = tokens.map(Int32.init) + [4299, 4299, 4299]
        timings.preparationSeconds = Date().timeIntervalSince(began)
        var samples: [Float] = try Device.withDefaultDevice(.gpu) {
        let conditioning = try loadArrays(url: selected, stream: .cpu)
        guard let embedding = conditioning["gen.embedding"], embedding.dtype == .float32, embedding.shape == [192],
              let prompt = conditioning["gen.prompt_token"], prompt.dtype == .int32,
              let length = conditioning["gen.prompt_token_len"], length.dtype == .int32, length.size == 1,
              let feat = conditioning["gen.prompt_feat"], feat.dtype == .float32,
              feat.ndim == 2, feat.dim(1) == 80 else { throw AcousticInventoryError.identity }
        let count = Int(length.item(Int32.self))
        guard count > 0, count <= 750, count <= prompt.size, feat.dim(0) == count * 2 else { throw AcousticInventoryError.input }
            timings.promptTokens = count
            timings.preparationSeconds = Date().timeIntervalSince(began)
            let flowBegan = Date()
            // Exactly ten cosine-scheduled steps, .7 classifier-free guidance,
            // full F32 parameters. Cancellation is checked before accepting mel.
            let mel = loaded.model.inference(token: MLXArray(generated, [1, generated.count]),
                tokenLen: MLXArray([Int32(generated.count)]),
                promptToken: prompt[0..<count].reshaped(1, count), promptTokenLen: MLXArray([Int32(count)]),
                promptFeat: feat.reshaped(1, count * 2, 80), embedding: embedding.reshaped(1, 192), nTimesteps: 10)
            try Task.checkCancellation(); eval(mel); try Self.health()
            guard mel.dtype == .float32, mel.shape == [1, 80, generated.count * 2], all(isFinite(mel)).item(Bool.self)
            else { throw AcousticInventoryError.input }
            // Includes the native encoder and CFM; do not advertise this as a
            // decoder-only figure or invent a separate asynchronous stage time.
            timings.flowSeconds = Date().timeIntervalSince(flowBegan)
            let vocoderBegan = Date()
            // Isolated single acoustic actor; token decoder has no hot RNG draws.
            // Fixed request-vocoder seed eliminates constructor-order dependence.
            MLXRandom.seed(42)
            let (waveform, _) = try loaded.model.vocoder(mel)
            guard waveform.dtype == .float32, waveform.shape == [1, generated.count * 2 * 480],
                  waveform.size <= 120 * 24000 else { throw AcousticInventoryError.input }
            try Task.checkCancellation(); eval(waveform); try Self.health()
            let values = waveform.reshaped(-1).asArray(Float.self)
            timings.vocoderSeconds = Date().timeIntervalSince(vocoderBegan)
            return values
        }
        try Self.health(); try loaded.verify()
        guard !samples.isEmpty, samples.count <= 120 * 24_000, samples.allSatisfy(\.isFinite),
              samples.reduce(Float.zero, { max($0, abs($1)) }) <= 1 else { throw AcousticInventoryError.input }
        // Identical declared upstream trim-fade; no gain or peak normalization.
        if samples.count >= 960 {
            for i in 0..<480 { samples[i] = 0 }
            for i in 0..<480 { samples[480+i] *= (cos(Float.pi * (1-Float(i)/479)) + 1) / 2 }
        }
        // Matt explicitly removed watermarking from Mac Pro. No watermark
        // model is loaded and no waveform modification is applied here.
        timings.watermarkSeconds = 0
        try Self.health()
        return .init(samples: samples, timings: timings)
    }

    private nonisolated static func verifyStock(_ file: URL) throws {
        try ChatterboxVoiceFile.validate(at: file)
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        let data = try input.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 2 * 1024 * 1024,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == stockSHA256 else { throw AcousticInventoryError.identity }
    }
    static func hostHealth() throws {
        try Task.checkCancellation()
        let info = ProcessInfo.processInfo
        guard !info.isLowPowerModeEnabled, info.thermalState != .serious, info.thermalState != .critical
        else { throw AcousticInventoryError.unsafeResource }
    }
    static func health() throws {
        try hostHealth()
        guard Memory.activeMemory <= 6 * 1024 * 1024 * 1024 else { throw AcousticInventoryError.unsafeResource }
    }
}
#endif
