import Foundation
import CryptoKit
import MLX
import MLXNN
import ChatterboxCoreML
import LibroxChatterbox
import os
import Darwin

/// Optional native decoder with the phone-tested mixed-precision math. The host
/// owns foreground eligibility and global MLX memory/cache budgets.
public actor ChatterboxMLXRenderer {
    public static let profile = "native-mlx-mixed-f16-accurate-1"
    public enum RendererError: Error { case precisionPolicy, identityMismatch, oracleMismatch, busy, resourceGuard, missingVoice, generationLimit }
    private let decoder: SpeechDecoder
    private let frontend: ChatterboxMultilingualPromptBuilder
    private let synth: ChatterboxTokenSynthesizer
    private let defaultVoice: URL
    private var occupied = false

    public init(weightsFile: URL, oracleFile: URL, modelDirectory: URL,
                defaultVoice: URL, watermarkDirectory: URL, acousticComputeUnits: PipelineComputeUnits) async throws {
        // Never change this process-global switch after another model initializes.
        guard ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0" else { throw RendererError.precisionPolicy }
        try Self.healthy(minimumAvailable: 3 * 1_024 * 1_024 * 1_024)
        guard try Self.digest(weightsFile) == "3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0",
              try Self.digest(oracleFile) == "87b8ab31eda9c63abbeecb8a9f0678bc8e0fe6980396ea0c4f9e16637ef618d2"
        else { throw RendererError.identityMismatch }
        let model = try Device.withDefaultDevice(.gpu) {
            let model = SpeechDecoder(precision: .mixedFloat16Accurate)
            let weights = try DecoderPrecision.mixedFloat16Accurate.loadWeights(from: weightsFile)
            try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
            eval(model)
            try Self.verify(model, fixture: loadArrays(url: oracleFile))
            return model
        }
        decoder = model
        frontend = try await ChatterboxMultilingualPromptBuilder(modelDirectory: modelDirectory)
        try ChatterboxVoiceFile.validate(at: defaultVoice)
        self.defaultVoice = defaultVoice
        try Self.healthy(minimumAvailable: 1_024 * 1_024 * 1_024)
        synth = try await ChatterboxTokenSynthesizer(modelDirectory: modelDirectory,
            conditioningFile: defaultVoice, watermarkDirectory: watermarkDirectory, computeUnits: acousticComputeUnits)
        try Self.healthy()
    }

    public func makeNarrator() -> ChatterboxNarrator {
        ChatterboxNarrator(rendering: { request in try await self.render(request) })
    }

    public func render(_ request: ChatterboxRequest) async throws -> ChatterboxAudioChunk {
        guard !occupied else { throw RendererError.busy }
        occupied = true; defer { occupied = false }
        try Self.healthy()
        let voice = request.conditioningFile ?? defaultVoice
        try ChatterboxVoiceFile.validate(at: voice)
        let assemblyBegan = Date()
        let prefix = try frontend.prepare(text: request.text, language: request.language, conditioningFile: voice,
            exaggeration: request.exaggeration, guidance: request.guidance, maxTokens: request.maxTokens)
        let assemblySeconds = Date().timeIntervalSince(assemblyBegan)
        let cache = (0..<30).map { _ in KVCache() }
        var input = MLXArray(prefix.embeddings, [2, prefix.length, 1024])
        var sampler = ChatterboxSpeechSampler(options: .multilingual(language: request.language,
            exaggeration: request.exaggeration, cfgWeight: request.guidance, temperature: request.temperature,
            maxTokens: request.maxTokens, seed: request.seed))
        var tokens: [Int] = [], stopped = false
        var prefillSeconds = 0.0
        let began = Date()
        for step in 0..<request.maxTokens {
            try Self.healthy()
            let start = Date()
            let values = predict(input, cache: cache)
            if step == 0 { prefillSeconds = Date().timeIntervalSince(start) }
            guard values.count == 16_388, values.allSatisfy(\.isFinite) else { throw RendererError.oracleMismatch }
            let guided = (0..<8194).map { values[$0] + request.guidance * (values[$0] - values[8194 + $0]) }
            let token = sampler.sample(logits: guided, previous: tokens, minTokensReached: tokens.count >= 2)
            if token == 6562, tokens.count >= 2 { stopped = true; break }
            tokens.append(token)
            let embedding = try frontend.speechInput(token: token, position: step + 1)
            input = MLXArray(embedding + embedding, [2, 1, 1024])
        }
        guard stopped else { throw RendererError.generationLimit }
        let decodeSeconds = Date().timeIntervalSince(began) - prefillSeconds
        let valid = tokens.filter { $0 < 6561 }
        try Self.healthy()
        let synthBegan = Date()
        let samples = try await synth.render(tokens: valid, conditioningFile: voice)
        try Task.checkCancellation()
        return try .init(samples: samples, timings: .init(prefillSeconds: prefillSeconds,
            decodeSeconds: decodeSeconds, synthSeconds: Date().timeIntervalSince(synthBegan), watermarkSeconds: 0,
            speechTokens: valid.count, decodeBackend: Self.profile, hostAssemblySeconds: assemblySeconds))
    }

    private func predict(_ input: MLXArray, cache: [KVCache]) -> [Float] {
        Device.withDefaultDevice(.gpu) {
            let logits = decoder.logits(input, cache: cache)
            eval(logits)
            return logits.asArray(Float.self)
        }
    }

    private static func healthy(minimumAvailable: Int = 256 * 1_024 * 1_024) throws {
        try Task.checkCancellation()
        let info = ProcessInfo.processInfo
        guard !info.isLowPowerModeEnabled, info.thermalState != .serious, info.thermalState != .critical,
              try availableMemory() >= UInt64(minimumAvailable) else { throw RendererError.resourceGuard }
    }
    private static func availableMemory() throws -> UInt64 {
        #if os(macOS)
        // A system free+inactive estimate on macOS, not iOS process headroom.
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &page) == KERN_SUCCESS else { throw RendererError.resourceGuard }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(page)
        #else
        return UInt64(os_proc_available_memory())
        #endif
    }
    private static func digest(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func verify(_ model: SpeechDecoder, fixture: [String: MLXArray]) throws {
        for language in ["en", "es"] {
            let cache = (0..<30).map { _ in KVCache() }
            for step in 0...8 {
                try healthy()
                let stem = language + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                guard let input = fixture[stem + ".input"], let expected = fixture[stem + ".logits"] else { throw RendererError.oracleMismatch }
                let output = model.logits(input, cache: cache); eval(output)
                let a = output.asArray(Float.self), b = expected.asArray(Float.self)
                guard a.count == 16_388, b.count == a.count, a.allSatisfy(\.isFinite) else { throw RendererError.oracleMismatch }
                var maximum: Float = 0, squared = 0.0, norm = 0.0
                for (x, y) in zip(a, b) { maximum = max(maximum, abs(x - y)); squared += pow(Double(x - y), 2); norm += pow(Double(y), 2) }
                let top1 = (0..<2).allSatisfy { lane in
                    (0..<8194).max { a[lane * 8194 + $0] < a[lane * 8194 + $1] } ==
                    (0..<8194).max { b[lane * 8194 + $0] < b[lane * 8194 + $1] }
                }
                guard maximum <= 0.05, sqrt(squared / max(norm, 1e-30)) <= 0.002, top1 else { throw RendererError.oracleMismatch }
            }
        }
    }
}
