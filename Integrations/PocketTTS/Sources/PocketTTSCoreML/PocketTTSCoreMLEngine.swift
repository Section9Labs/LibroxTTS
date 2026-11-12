import Foundation
import Darwin
import CoreML
import CryptoKit
import KokoroCatalog
import PocketTTSMLX
import MLX
import MLXRandom

/// Actor-owned Core ML acoustic backend. MLX is used only on CPU
/// for reading existing safetensors and the unchanged seeded noise generator.
/// All transformer, flow and Mimi neural inference runs through Core ML.
public actor PocketTTSCoreMLEngine {
    public static let runtimeIdentity = PocketTTSBackend.coreML.runtimeIdentity
    public enum Placement: String, Codable, Sendable { case cpu, cpuGPU, cpuANE, all }
    public struct Output: Sendable { public let samples: [Float]; public let sampleRate: Int }
    public enum Failure: Error { case incompatibleModel, unsupportedSampler(Int), cacheLimit, invalidShape, missingOutput(String), generationLimit(tokens: Int, frames: Int) }
    private let assets: URL
    private let models: URL?
    private let placement: Placement
    private var loaded: PocketCoreMLExecutionPlan?
    private var seed: UInt64?
    private var random: MLXRandom.RandomState?
    public init(directory: URL, modelsDirectory: URL? = nil, placement: Placement = .cpu) {
        assets = directory; models = modelsDirectory; self.placement = placement
    }
    private var resourceObserver: (@Sendable (PocketTTSResourceSnapshot) -> Void)?
    public func setResourceObserver(_ observer: (@Sendable (PocketTTSResourceSnapshot) -> Void)?) {
        resourceObserver = observer
    }
    public func setRandomSeed(_ value: UInt64) { seed = value; random = nil }
    public func unload() { loaded = nil; random = nil }
    public var loadedLanguage: String? { loaded?.language }
    public struct StageTiming: Sendable, Codable {
        public var calls: Int = 0
        public var wallSeconds: Double = 0
        public var cpuSeconds: Double = 0
    }
    private var collectTimings = false
    public func setTimingCollection(_ enabled: Bool) { collectTimings = enabled; loaded?.collectTimings = enabled }
    public var stageTimings: [String: StageTiming] { loaded?.timings ?? [:] }
    private var cpuBudgetFraction: Double?
    /// Paces execution without changing any model or sampling settings. The
    /// host may select a budget; live Core ML playback defaults to unmetered bursts.
    public func setCPUBudgetFraction(_ fraction: Double?) { cpuBudgetFraction = fraction }
    public func previewChunks(_ text: String, voiceID: String,
                              chunking: PocketTTSChunkingOptions = .init(),
                              role: PocketTTSPassageRole = .narration) throws -> [PocketTTSTextChunk] {
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        return try load(voice.language).chunks(text, options: chunking, role: role)
    }
    public func synthesize(_ text: String, voiceID: String, temperature: Float = 0.3,
                           continueChunks: Bool = true, chunking: PocketTTSChunkingOptions = .init(),
                           role: PocketTTSPassageRole = .narration, samplerSteps: Int = 4,
                           deliveryStyle: PocketTTSDeliveryStyle = .original) throws -> Output {
        var samples: [Float] = []
        try render(text, voiceID: voiceID, temperature: temperature, continueChunks: continueChunks,
                   chunking: chunking, role: role, samplerSteps: samplerSteps, deliveryStyle: deliveryStyle) { samples += $0 }
        return Output(samples: samples, sampleRate: 24_000)
    }
    public func renderFrames(_ text: String, voiceID: String, temperature: Float = 0.3,
                             continueChunks: Bool = true, chunking: PocketTTSChunkingOptions = .init(),
                             role: PocketTTSPassageRole = .narration, samplerSteps: Int = 4,
                             deliveryStyle: PocketTTSDeliveryStyle = .original,
                             onTextChunk: @Sendable (PocketTTSChunkProgress) throws -> Void = { _ in },
                             receive: @Sendable ([Float]) throws -> Void) throws {
        try render(text, voiceID: voiceID, temperature: temperature, continueChunks: continueChunks,
                   chunking: chunking, role: role, samplerSteps: samplerSteps, deliveryStyle: deliveryStyle, onTextChunk: onTextChunk, receive: receive)
    }
    private func render(_ text: String, voiceID: String, temperature: Float,
                        continueChunks: Bool, chunking: PocketTTSChunkingOptions,
                        role: PocketTTSPassageRole, samplerSteps: Int, deliveryStyle: PocketTTSDeliveryStyle,
                        onTextChunk: (PocketTTSChunkProgress) throws -> Void = { _ in },
                        receive: ([Float]) throws -> Void) throws {
        try chunking.validate()
        try PocketTTSSamplingOptions(temperature: temperature, samplerSteps: samplerSteps).validate()
        guard (1...8).contains(samplerSteps) else { throw Failure.unsupportedSampler(samplerSteps) }
        guard let voice = PocketTTSCatalog.voice(id: voiceID) else { throw PocketTTSError.invalidVoice }
        try PocketTTSDeliveryCatalog.validate(deliveryStyle, voiceID: voiceID, in: assets)
        let name = try PocketTTSDeliveryCatalog.stateName(voiceID: voiceID, style: deliveryStyle)
        // Synchronous actor work can be called repeatedly without a run-loop
        // autorelease drain. Bound Foundation/Core ML bridge lifetimes to one
        // render, including retained-output views and native voice preparation.
        try autoreleasepool { try Device.withDefaultDevice(.cpu) {
            if random == nil { random = seed.map(MLXRandom.RandomState.init(seed:)) ?? MLXRandom.RandomState() }
            try withRandomState(random!) {
                defer { if let random { eval(random) }; Memory.clearCache() }
                do {
                    try PocketTTSResourceChecks.checkpoint("operation-start", backend: "coreml-cpu", samplerSteps: samplerSteps, observer: resourceObserver)
                    let budget = PocketCPUWorkBudget.backgroundBudget(cpu: placement == .cpu || placement == .cpuANE, fraction: cpuBudgetFraction)
                    let m = try load(voice.language)
                    m.timings = [:]
                    let flow = try m.flow(samplerSteps)
                    let prompt = try m.voice(name)
                    let chunks = try m.chunks(text, options: chunking, role: role)
                    var previousText: String?
                    var previous: [MLMultiArray] = []
                    var total = 0
                    for chunk in chunks {
                        try Task.checkCancellation()
                        let chunkStart = total
                        if chunk.startsNewPassage { previousText = nil; previous = [] }
                        let forced = continueChunks && !previous.isEmpty
                        let joined = forced ? previousText! + " " + chunk.text : chunk.text
                        let prepared = try PocketTTSTextUtils.prepareTextPrompt(joined, config: m.config, preserveSentenceBoundaries: chunking.grouping == .adaptive).0
                        let tail = try PocketTTSTextUtils.prepareTextPrompt(chunk.text, config: m.config, preserveSentenceBoundaries: chunking.grouping == .adaptive).1
                        let tokens = m.tokenizer.encode(prepared)
                        var cache = prompt
                        _ = try m.transform(m.textModel, value: Self.ints(tokens), cache: &cache)
                        var input = try Self.floats(m.bos, shape: [1,32])
                        var mimiState = try m.emptyMimiState()
                        if forced {
                            let prefix = [input] + previous.dropLast()
                            // The graph accepts up to 512 tokens per invocation.
                            // Preserve the entire native continuation, including
                            // rare long tails, by causally prefilling in blocks.
                            for start in stride(from: 0, to: prefix.count, by: 512) {
                                let block = prefix[start..<min(start + 512, prefix.count)]
                                _ = try m.transform(m.latentModel, value: Self.floats(block.flatMap { Self.values($0) }, shape: [1, block.count, 32]), cache: &cache)
                            }
                            input = previous.last!
                            for frame in previous.suffix(12) { _ = try m.decode(frame, state: &mimiState) }
                        }
                        // The MLX path consumes one draw after prefill, including
                        // teacher-forcing's discarded last flow output.
                        _ = MLXRandom.normal([1, 32])
                        var eosStep: Int?
                        var current: [MLMultiArray] = []
                        let cap = min(1500, Int(ceil((Double(tokens.count) / 3 + 2) * m.config.mimi.frameRate)))
                        var complete = false
                        for step in 0..<cap {
                            try PocketTTSResourceChecks.checkpoint("frame", backend: "coreml-" + placement.rawValue, samplerSteps: samplerSteps, frameIndex: step, observer: resourceObserver)
                            let result = try m.transform(m.latentModel, value: Self.latentInput(input), cache: &cache)
                            var noise = MLXRandom.normal([1, 32]) * Float(sqrt(temperature))
                            if let clamp = m.config.noiseClamp { noise = MLX.minimum(MLX.maximum(noise, -clamp), clamp) }
                            let next = try m.sample(flow, steps: samplerSteps, condition: result.0, noise: noise.asArray(Float.self))
                            if eosStep == nil && step >= 6 && result.1 > m.config.eosThreshold { eosStep = step }
                            if let eosStep, step >= eosStep + (m.config.framesAfterEOS ?? tail + 2) { complete = true; break }
                            var pcm = try m.decode(next, state: &mimiState)
                            if step == 0 && !forced {
                                for i in 0..<min(120, pcm.count) { pcm[i] *= Float(i) / 119 }
                            }
                            guard pcm.count == 1920, pcm.allSatisfy(\.isFinite) else { throw PocketTTSError.invalidAudio }
                            total += pcm.count
                            guard total <= 24_000 * 300 else { throw PocketTTSError.textTooLong }
                            try Task.checkCancellation()
                            try receive(pcm)
                            try budget?.checkpoint()
                            current.append(next); input = next
                        }
                        guard complete else { throw Failure.generationLimit(tokens: tokens.count, frames: cap) }
                        try Task.checkCancellation()
                        try onTextChunk(.init(text: chunk.text, startSample: chunkStart, endSample: total))
                        previousText = chunk.text; previous = current
                    }
                    guard total > 0 else { throw PocketTTSError.emptyText }
                } catch { loaded = nil; random = nil; throw error }
            }
        } }
    }
    private func load(_ language: String) throws -> PocketCoreMLExecutionPlan {
        if loaded?.language != language {
            loaded = nil
            if models == nil {
                try PocketTTSCoreMLAssets.validate(in: assets, language: language)
            } else {
                try PocketTTSCatalog.validate(PocketTTSCoreMLCatalog.sharedManifest(language: language), in: assets)
            }
            loaded = try autoreleasepool {
                try PocketCoreMLExecutionPlan(language: language, assets: assets, models: models, placement: placement)
            }
            loaded?.collectTimings = collectTimings
        }
        return loaded!
    }
    static func floats(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        guard shape.reduce(1, *) == values.count else { throw Failure.invalidShape }
        let a = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        values.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { a.dataPointer.assumingMemoryBound(to: Float.self).update(from: base, count: src.count) }
        }
        return a
    }
    static func ints(_ values: [Int]) throws -> MLMultiArray {
        let a = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for (i, v) in values.enumerated() { a.dataPointer.assumingMemoryBound(to: Int32.self)[i] = Int32(v) }
        return a
    }
    static func values(_ a: MLMultiArray) -> [Float] {
        // Core ML may return strided output views. Honor strides rather than
        // assuming the backing allocation is a contiguous row-major buffer.
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        let p = a.dataPointer.assumingMemoryBound(to: Float.self)
        var expected = 1, contiguous = true
        for d in shape.indices.reversed() {
            if shape[d] > 1 && strides[d] != expected { contiguous = false }
            expected *= shape[d]
        }
        if contiguous { return Array(UnsafeBufferPointer(start: p, count: a.count)) }
        var result = [Float](repeating: 0, count: a.count)
        let width = strides.last == 1 ? shape.last! : 1
        for i in stride(from: 0, to: a.count, by: width) {
            var n = i, offset = 0
            for d in shape.indices.reversed() { offset += (n % shape[d]) * strides[d]; n /= shape[d] }
            result.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: i).update(from: p.advanced(by: offset), count: width) }
        }
        return result
    }
    static func output(_ result: any MLFeatureProvider, _ name: String) throws -> MLMultiArray {
        guard let value = result.featureValue(for: name)?.multiArrayValue else { throw Failure.missingOutput(name) }
        return value
    }
}
