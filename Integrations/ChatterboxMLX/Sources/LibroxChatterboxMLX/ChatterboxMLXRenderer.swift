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
    /// Legacy decoder selection ID. Use instance profileIdentifier for audio caches.
    public static let profile = "native-mlx-mixed-f16-accurate-1"
    public enum DecoderProfile: String, Sendable {
        case mixedFloat16Accurate = "native-mlx-mixed-f16-accurate-1"
        public var weightsSHA256: String {
            switch self {
            case .mixedFloat16Accurate: "3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0"
            }
        }
        public var oracleSHA256: String {
            switch self {
            case .mixedFloat16Accurate: "87b8ab31eda9c63abbeecb8a9f0678bc8e0fe6980396ea0c4f9e16637ef618d2"
            }
        }
    }
    public nonisolated let decoderProfile: DecoderProfile
    public nonisolated let watermarkPolicy: ChatterboxWatermarkPolicy
    /// Opaque rendering identity, including host-copy semantics and selected
    /// acoustic stages. Decoder selection/oracle IDs remain unchanged.
    public nonisolated let profileIdentifier: String
    public nonisolated static func renderingProfileIdentifier(
        decoderProfile: DecoderProfile, acousticComputeUnits: PipelineComputeUnits,
        reuseAcousticInputs: Bool = false, watermarkPolicy: ChatterboxWatermarkPolicy = .perth
    ) -> String {
        let stages = [acousticComputeUnits.encoder, acousticComputeUnits.cfm,
            acousticComputeUnits.vocoder, acousticComputeUnits.watermark]
            .map { $0.map { String($0.rawValue) } ?? "inherit" }.joined(separator: ",")
        let base = decoderProfile.rawValue + ":" + ChatterboxRequest.adapterRevision +
            ":acoustics=" + stages + ":reuse=" + (reuseAcousticInputs ? "1" : "0")
        // Keep previously qualified watermarked identities byte-for-byte stable.
        return watermarkPolicy == .perth ? base : base + ":watermark=" + watermarkPolicy.rawValue
    }
    public enum RendererError: Error, CustomNSError {
        case precisionPolicy, identityMismatch, oracleMismatch, busy
        case resourceGuard(ResourceGuardDetails)
        case missingVoice, generationLimit
        case oracleValidation(OracleValidationDetails)

        public static var errorDomain: String { "LibroxChatterboxMLX.ChatterboxMLXRenderer.RendererError" }
        // Keep existing codes stable when associated-value cases are added.
        public var errorCode: Int {
            switch self {
            case .resourceGuard: 0
            case .precisionPolicy: 1
            case .identityMismatch: 2
            case .oracleMismatch: 3
            case .busy: 4
            case .missingVoice: 5
            case .generationLimit: 6
            case .oracleValidation: 7
            }
        }
        public var errorUserInfo: [String: Any] {
            guard case .oracleValidation(let details) = self else { return [:] }
            var result: [String: Any] = ["oracleStage": details.stage,
                "oracleProfile": details.profileIdentifier,
                "oracleReason": details.reason.rawValue,
                "oracleActualCount": details.actualCount,
                "oracleExpectedCount": details.expectedCount]
            if let value = details.maximumAbsoluteError { result["oracleMaximumAbsoluteError"] = value }
            if let value = details.relativeL2 { result["oracleRelativeL2"] = value }
            if let value = details.top1Matches { result["oracleTop1Matches"] = value }
            return result
        }
    }

    /// Public, fixed-fixture diagnostics only; never contains request text or a voice.
    public struct OracleValidationDetails: Sendable, Codable {
        public enum Reason: String, Sendable, Codable {
            case missingFixture, invalidOutput, numericalMismatch
        }
        public let stage: String
        public let profileIdentifier: String
        public let reason: Reason
        public let actualCount: Int
        public let expectedCount: Int
        public let maximumAbsoluteError: Double?
        public let relativeL2: Double?
        public let top1Matches: Bool?
    }

    /// Numeric diagnostics only: contains no book text, audio or voice identity.
    public struct MemorySnapshot: Sendable, Codable {
        public let availableBytes: UInt64?
        public let activeBytes: Int
        public let cacheBytes: Int
        public let peakBytes: Int
        public let lowPowerMode: Bool
        public let thermalState: Int
    }

    public struct ResourceGuardDetails: Sendable, Codable {
        public enum Reason: String, Sendable, Codable {
            case memory, memoryQuery, lowPowerMode, thermal
        }
        public let reason: Reason
        public let minimumAvailableBytes: Int
        public let memory: MemorySnapshot
    }

    /// Process-wide MLX buffer pool policy; the host coordinates other MLX users.
    /// This limits reusable buffers, not live model allocations or safety guards.
    public nonisolated static func configureBufferCache(maximumBytes: Int) {
        precondition(maximumBytes >= 0)
        Memory.cacheLimit = maximumBytes
    }

    public nonisolated static func trimUnusedMemory() { Memory.clearCache() }

    public nonisolated static func memorySnapshot() -> MemorySnapshot {
        let info = ProcessInfo.processInfo
        return .init(availableBytes: availableMemory(), activeBytes: Memory.activeMemory,
                     cacheBytes: Memory.cacheMemory, peakBytes: Memory.peakMemory,
                     lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState.rawValue)
    }
    private let decoder: SpeechDecoder
    private let frontend: ChatterboxMultilingualPromptBuilder
    private let synth: ChatterboxTokenSynthesizer
    private let defaultVoice: URL
    private var occupied = false

    public init(weightsFile: URL, oracleFile: URL, modelDirectory: URL,
                defaultVoice: URL, watermarkDirectory: URL, acousticComputeUnits: PipelineComputeUnits,
                decoderProfile: DecoderProfile = .mixedFloat16Accurate,
                reuseAcousticInputs: Bool = false,
                watermarkPolicy: ChatterboxWatermarkPolicy = .perth) async throws {
        self.decoderProfile = decoderProfile
        self.watermarkPolicy = watermarkPolicy
        self.profileIdentifier = Self.renderingProfileIdentifier(decoderProfile: decoderProfile,
            acousticComputeUnits: acousticComputeUnits, reuseAcousticInputs: reuseAcousticInputs,
            watermarkPolicy: watermarkPolicy)
        // Never change this process-global switch after another model initializes.
        guard ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0" else { throw RendererError.precisionPolicy }
        try Self.healthy(minimumAvailable: 3 * 1_024 * 1_024 * 1_024)
        guard try Self.digest(weightsFile) == decoderProfile.weightsSHA256,
              try Self.digest(oracleFile) == decoderProfile.oracleSHA256
        else { throw RendererError.identityMismatch }
        let model = try Device.withDefaultDevice(.gpu) {
            let model = SpeechDecoder(precision: .mixedFloat16Accurate)
            let weights = try DecoderPrecision.mixedFloat16Accurate.loadWeights(from: weightsFile)
            try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
            eval(model)
            try Self.verify(model, fixture: loadArrays(url: oracleFile), profile: decoderProfile)
            return model
        }
        // Verification allocates its own KV caches and oracle tensors. None are
        // needed by the acoustic models; return unused buffers before loading them.
        Self.trimUnusedMemory()
        decoder = model
        frontend = try await ChatterboxMultilingualPromptBuilder(modelDirectory: modelDirectory)
        try ChatterboxVoiceFile.validate(at: defaultVoice)
        self.defaultVoice = defaultVoice
        try Self.healthy(minimumAvailable: 1_024 * 1_024 * 1_024)
        synth = try await ChatterboxTokenSynthesizer(modelDirectory: modelDirectory,
            conditioningFile: defaultVoice, watermarkDirectory: watermarkDirectory,
            computeUnits: acousticComputeUnits, reuseFlowInputs: reuseAcousticInputs, watermarkPolicy: watermarkPolicy)
        try Self.healthy()
    }

    public func makeNarrator(overlap: Bool = false) -> ChatterboxNarrator {
        if overlap {
            return ChatterboxNarrator(rendering: { request in try await self.render(request) },
                batchRendering: { requests, receive in try await self.renderBatch(requests, receive: receive) })
        }
        return ChatterboxNarrator(rendering: { request in try await self.render(request) })
    }

    public func render(_ request: ChatterboxRequest) async throws -> ChatterboxAudioChunk {
        guard !occupied else { throw RendererError.busy }
        occupied = true; defer { occupied = false }
        // ARC releases the decode helper's arrays before this phase boundary.
        // On failure the helper has also unwound before this deferred trim runs.
        defer { Self.trimUnusedMemory() }
        Self.trimUnusedMemory()
        try Self.healthy()
        let voice = request.conditioningFile ?? defaultVoice
        try ChatterboxVoiceFile.validate(at: voice)
        let decoded = try decode(request, voice: voice)
        Self.trimUnusedMemory()
        try Self.healthy()
        return try await Self.synthesize(decoded, voice: voice, using: synth, profile: decoderProfile.rawValue)
    }

    private nonisolated static func synthesize(_ decoded: DecodedSpeech, voice: URL,
        using synth: ChatterboxTokenSynthesizer, profile: String) async throws -> ChatterboxAudioChunk {
        try Self.healthy()
        let synthBegan = Date()
        let output = try await synth.renderMeasured(tokens: decoded.tokens, conditioningFile: voice)
        try Task.checkCancellation()
        var timings = ChatterboxChunkTimings(prefillSeconds: decoded.prefillSeconds,
            decodeSeconds: decoded.decodeSeconds,
            synthSeconds: max(0, Date().timeIntervalSince(synthBegan) - output.timings.watermarkSeconds),
            watermarkSeconds: output.timings.watermarkSeconds, speechTokens: decoded.tokens.count,
            decodeBackend: profile, hostAssemblySeconds: decoded.assemblySeconds)
        timings.acoustics = output.timings
        return try .init(samples: output.samples, timings: timings)
    }

    /// One decoder plus one acoustic worker, at most one completed/active prior
    /// unit. Cancellation joins the worker before the busy lease is released.
    private func renderBatch(_ requests: [ChatterboxRequest],
        receive: @escaping @Sendable (ChatterboxBatchChunk) async throws -> Void) async throws {
        guard !occupied else { throw RendererError.busy }
        guard (1...8).contains(requests.count) else { throw ChatterboxNarrationError.invalidBatch }
        occupied = true
        defer { occupied = false; Self.trimUnusedMemory() }
        try await withThrowingTaskGroup(of: ChatterboxAudioChunk.self) { group in
            var hasPending = false
            var previous = 0
            for (index, request) in requests.enumerated() {
                try Self.healthy()
                let voice = request.conditioningFile ?? defaultVoice
                try ChatterboxVoiceFile.validate(at: voice)
                let decoded = try decode(request, voice: voice)
                Self.trimUnusedMemory()
                if hasPending {
                    guard let audio = try await group.next() else { throw RendererError.oracleMismatch }
                    try Task.checkCancellation()
                    try await receive(.init(requestIndex: previous, chunkIndex: 0, isFinalChunk: true,
                                            request: requests[previous], audio: audio))
                }
                try Task.checkCancellation()
                let worker = synth, profile = decoderProfile.rawValue
                group.addTask { try await Self.synthesize(decoded, voice: voice, using: worker, profile: profile) }
                hasPending = true
                previous = index
            }
            if hasPending {
                guard let audio = try await group.next() else { throw RendererError.oracleMismatch }
                try Task.checkCancellation()
                try await receive(.init(requestIndex: previous, chunkIndex: 0, isFinalChunk: true,
                                        request: requests[previous], audio: audio))
            }
        }
        try Task.checkCancellation()
    }

    /// Keep all GPU tensors/KV storage in a synchronous scope. Only CPU token
    /// IDs and timing scalars survive into the Core ML acoustic phase.
    private struct DecodedSpeech: Sendable {
        let tokens: [Int]
        let prefillSeconds: Double
        let decodeSeconds: Double
        let assemblySeconds: Double
    }

    @inline(never)
    private func decode(_ request: ChatterboxRequest, voice: URL) throws -> DecodedSpeech {
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
        return .init(tokens: valid, prefillSeconds: prefillSeconds,
                     decodeSeconds: decodeSeconds, assemblySeconds: assemblySeconds)
    }

    private func predict(_ input: MLXArray, cache: [KVCache]) -> [Float] {
        Device.withDefaultDevice(.gpu) {
            let logits = decoder.logits(input, cache: cache)
            eval(logits)
            return logits.asArray(Float.self)
        }
    }

    static func healthy(minimumAvailable: Int = 256 * 1_024 * 1_024) throws {
        try Task.checkCancellation()
        let snapshot = memorySnapshot()
        let reason: ResourceGuardDetails.Reason?
        if snapshot.lowPowerMode { reason = .lowPowerMode }
        else if snapshot.thermalState == ProcessInfo.ThermalState.serious.rawValue ||
                    snapshot.thermalState == ProcessInfo.ThermalState.critical.rawValue { reason = .thermal }
        else if let available = snapshot.availableBytes {
            reason = available < UInt64(minimumAvailable) ? .memory : nil
        } else { reason = .memoryQuery }
        if let reason {
            throw RendererError.resourceGuard(.init(reason: reason,
                minimumAvailableBytes: minimumAvailable, memory: snapshot))
        }
    }
    private static func availableMemory() -> UInt64? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        // A system free+inactive estimate on the Mac (Catalyst too: there
        // os_proc_available_memory() is 0 because no jetsam limit applies).
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var page: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(mach_host_self(), &page) == KERN_SUCCESS else { return nil }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(page)
        #else
        return UInt64(os_proc_available_memory())
        #endif
    }
    static func digest(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func verify(_ model: SpeechDecoder, fixture: [String: MLXArray], profile: DecoderProfile) throws {
        for language in ["en", "es"] {
            let cache = (0..<30).map { _ in KVCache() }
            for step in 0...8 {
                try healthy()
                let stem = language + (step == 0 ? ".prefill" : ".decode.\(step - 1)")
                guard let input = fixture[stem + ".input"], let expected = fixture[stem + ".logits"] else {
                    throw RendererError.oracleValidation(.init(stage: stem, profileIdentifier: profile.rawValue, reason: .missingFixture,
                        actualCount: 0, expectedCount: 16_388,
                        maximumAbsoluteError: nil, relativeL2: nil, top1Matches: nil))
                }
                let output = model.logits(input, cache: cache); eval(output)
                let a = output.asArray(Float.self), b = expected.asArray(Float.self)
                guard a.count == 16_388, b.count == a.count, a.allSatisfy(\.isFinite) else {
                    throw RendererError.oracleValidation(.init(stage: stem, profileIdentifier: profile.rawValue, reason: .invalidOutput,
                        actualCount: a.count, expectedCount: b.count,
                        maximumAbsoluteError: nil, relativeL2: nil, top1Matches: nil))
                }
                var maximum: Float = 0, squared = 0.0, norm = 0.0
                for (x, y) in zip(a, b) { maximum = max(maximum, abs(x - y)); squared += pow(Double(x - y), 2); norm += pow(Double(y), 2) }
                let top1 = (0..<2).allSatisfy { lane in
                    (0..<8194).max { a[lane * 8194 + $0] < a[lane * 8194 + $1] } ==
                    (0..<8194).max { b[lane * 8194 + $0] < b[lane * 8194 + $1] }
                }
                let relativeL2 = sqrt(squared / max(norm, 1e-30))
                guard maximum <= 0.05, relativeL2 <= 0.002, top1 else {
                    throw RendererError.oracleValidation(.init(stage: stem, profileIdentifier: profile.rawValue, reason: .numericalMismatch,
                        actualCount: a.count, expectedCount: b.count,
                        maximumAbsoluteError: Double(maximum), relativeL2: relativeL2, top1Matches: top1))
                }
            }
        }
    }
}
