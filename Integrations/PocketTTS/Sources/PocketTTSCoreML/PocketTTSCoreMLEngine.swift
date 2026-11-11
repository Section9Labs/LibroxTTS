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
    private var loaded: Loaded?
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
        try Device.withDefaultDevice(.cpu) {
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
                    var previous: [[Float]] = []
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
                        var input = m.bos
                        var mimiState = try m.emptyMimiState()
                        if forced {
                            let prefix = [m.bos] + previous.dropLast()
                            // The graph accepts up to 512 tokens per invocation.
                            // Preserve the entire native continuation, including
                            // rare long tails, by causally prefilling in blocks.
                            for start in stride(from: 0, to: prefix.count, by: 512) {
                                let block = prefix[start..<min(start + 512, prefix.count)]
                                _ = try m.transform(m.latentModel, value: Self.floats(block.flatMap { $0 }, shape: [1, block.count, 32]), cache: &cache)
                            }
                            input = previous.last!
                            for frame in previous.suffix(12) { _ = try m.decode(frame, state: &mimiState) }
                        }
                        // The MLX path consumes one draw after prefill, including
                        // teacher-forcing's discarded last flow output.
                        _ = MLXRandom.normal([1, 32])
                        var eosStep: Int?
                        var current: [[Float]] = []
                        let cap = min(1500, Int(ceil((Double(tokens.count) / 3 + 2) * m.config.mimi.frameRate)))
                        var complete = false
                        for step in 0..<cap {
                            try PocketTTSResourceChecks.checkpoint("frame", backend: "coreml-" + placement.rawValue, samplerSteps: samplerSteps, frameIndex: step, observer: resourceObserver)
                            let result = try m.transform(m.latentModel, value: Self.floats(input, shape: [1, 1, 32]), cache: &cache)
                            var noise = MLXRandom.normal([1, 32]) * Float(sqrt(temperature))
                            if let clamp = m.config.noiseClamp { noise = MLX.minimum(MLX.maximum(noise, -clamp), clamp) }
                            let next = try m.sample(flow, steps: samplerSteps, condition: Self.values(result.0), noise: noise.asArray(Float.self))
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
        }
    }
    private func load(_ language: String) throws -> Loaded {
        if loaded?.language != language {
            loaded = nil
            if models == nil {
                try PocketTTSCoreMLAssets.validate(in: assets, language: language)
            } else {
                try PocketTTSCatalog.validate(PocketTTSCoreMLCatalog.sharedManifest(language: language), in: assets)
            }
            loaded = try autoreleasepool {
                try Loaded(language: language, assets: assets, models: models, placement: placement)
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
    private final class Loaded {
        let language: String
        let root: URL
        let config: PocketTTSModelConfig
        let tokenizer: PocketTTSSentencePieceTokenizer
        let textModel: MLModel, latentModel: MLModel, mimiModel: MLModel
        let modelRoot: URL
        let compiledRoot: URL
        let configuration: MLModelConfiguration
        let bos: [Float]
        var flows: [Int: MLModel] = [:]
        var collectTimings = false
        var timings: [String: StageTiming] = [:]
        private func predict(_ model: MLModel, _ inputs: [String: Any]) throws -> any MLFeatureProvider {
            try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        }
        private func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
            guard collectTimings else { return try body() }
            func cpu() -> Double {
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            }
            let start = ProcessInfo.processInfo.systemUptime, startedCPU = cpu()
            defer {
                var row = timings[name] ?? StageTiming()
                row.calls += 1; row.wallSeconds += ProcessInfo.processInfo.systemUptime - start
                row.cpuSeconds += cpu() - startedCPU; timings[name] = row
            }
            return try body()
        }
        init(language: String, assets: URL, models: URL?, placement: Placement) throws {
            self.language = language; root = assets.appendingPathComponent(language); modelRoot = models?.appendingPathComponent(language) ?? PocketTTSCoreMLAssets.modelDirectory(in: assets, language: language)
            config = try PocketTTSModelConfig.load(from: root.appendingPathComponent("config.json"))
            tokenizer = try PocketTTSSentencePieceTokenizer(nBins: config.flowLM.lookupTable.nBins, modelFolder: root, tokenizerPath: config.tokenizerName)
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: modelRoot.appendingPathComponent("manifest.json"))) as? [String: Any]
            let original = try PocketTTSCatalog.manifest(language: language).installedFiles.first { $0.path == "\(language)/model.safetensors" }
            guard manifest?["snapshot"] as? String == "a7056f505a4a8ca72d8b5fb1440071d6f1a35739",
                  manifest?["weightsSHA256"] as? String == original?.sha256,
                  manifest?["precision"] as? String == "float32", manifest?["gelu"] as? String == "tanh" else { throw Failure.incompatibleModel }
            configuration = MLModelConfiguration()
            switch placement {
            case .cpu: configuration.computeUnits = .cpuOnly
            case .cpuGPU: configuration.computeUnits = .cpuAndGPU
            case .cpuANE: configuration.computeUnits = .cpuAndNeuralEngine
            case .all: configuration.computeUnits = .all
            }
            compiledRoot = models == nil ? modelRoot.appendingPathComponent("compiled") : modelRoot
            textModel = try MLModel(contentsOf: compiledRoot.appendingPathComponent("text.mlmodelc"), configuration: configuration)
            latentModel = try MLModel(contentsOf: compiledRoot.appendingPathComponent("latent.mlmodelc"), configuration: configuration)
            let mimiConfig = MLModelConfiguration(); mimiConfig.computeUnits = .cpuOnly
            mimiModel = try MLModel(contentsOf: compiledRoot.appendingPathComponent("mimi.mlmodelc"), configuration: mimiConfig)
            let data = try Data(contentsOf: modelRoot.appendingPathComponent("bos.bin"))
            bos = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard bos.count == 32 else { throw Failure.invalidShape }
        }
        func flow(_ steps: Int) throws -> MLModel {
            if let value = flows[steps] { return value }
            let value = try autoreleasepool {
                try MLModel(contentsOf: compiledRoot.appendingPathComponent(([4, 8].contains(steps) ? "flow\(steps)" : "flowstep") + ".mlmodelc"), configuration: configuration)
            }
            flows[steps] = value; return value
        }
        func sample(_ model: MLModel, steps: Int, condition: [Float], noise: [Float]) throws -> [Float] {
            try measure("flow") { try autoreleasepool {
                let condition = try PocketTTSCoreMLEngine.floats(condition, shape: [1,1024])
                var latent = try PocketTTSCoreMLEngine.floats(noise, shape: [1,32])
                for index in 0..<([4, 8].contains(steps) ? 1 : steps) {
                    try Task.checkCancellation()
                    var inputs: [String: Any] = ["condition": condition, "noise": latent]
                    if ![4, 8].contains(steps) {
                        inputs["s"] = try PocketTTSCoreMLEngine.floats([Float(Double(index) / Double(steps))], shape: [1,1])
                        inputs["t"] = try PocketTTSCoreMLEngine.floats([Float(Double(index + 1) / Double(steps))], shape: [1,1])
                        inputs["steps"] = try PocketTTSCoreMLEngine.floats([Float(steps)], shape: [1])
                    }
                    let output = try predict(model, inputs)
                    latent = try PocketTTSCoreMLEngine.output(output, "latent")
                }
                return PocketTTSCoreMLEngine.values(latent)
            } }
        }
        func chunks(_ text: String, options: PocketTTSChunkingOptions, role: PocketTTSPassageRole) throws -> [PocketTTSTextChunk] {
            try PocketTTSPassageChunker.plan(text, language: language, role: role, options: options,
                prepare: { try PocketTTSTextUtils.prepareTextPrompt($0, config: self.config, preserveSentenceBoundaries: options.grouping == .adaptive).0 },
                tokenCount: { self.tokenizer.encode($0).count })
        }
        func voice(_ name: String) throws -> [MLMultiArray] {
            try Device.withDefaultDevice(.cpu) {
                let arrays = try MLX.loadArrays(url: root.appendingPathComponent("embeddings/\(name).safetensors"))
                var caches: [MLMultiArray] = []
                for i in 0..<6 {
                    let prefix = "transformer.layers.\(i).self_attn/"
                    guard let kv = arrays[prefix + "cache"], let offset = arrays[prefix + "offset"] else { throw Failure.invalidShape }
                    let n = offset.item(Int.self)
                    guard kv.ndim == 5, kv.shape[0] == 2, kv.shape[1] == 1, kv.shape[3] == 16, kv.shape[4] == 64,
                          n > 0, n <= kv.shape[2], n <= 512 else { throw Failure.invalidShape }
                    for j in 0..<2 {
                        let value = kv[j, 0..., ..<n, 0..., 0...].transposed(0, 2, 1, 3).asType(.float32)
                        caches.append(try PocketTTSCoreMLEngine.floats(value.asArray(Float.self), shape: [1,16,n,64]))
                    }
                }
                return caches
            }
        }
        func transform(_ model: MLModel, value: MLMultiArray, cache: inout [MLMultiArray]) throws -> (MLMultiArray, Float) {
            try measure(model === textModel ? "text" : "latent") { try autoreleasepool {
            try Task.checkCancellation()
            guard cache.count == 12, cache[0].shape[2].intValue <= 4096, value.shape[1].intValue <= 512 else { throw Failure.cacheLimit }
            var input: [String: Any] = ["value": value, "position": try PocketTTSCoreMLEngine.floats([Float(cache[0].shape[2].intValue)], shape: [1])]
            for i in 0..<12 { input["cache\(i)"] = cache[i] }
            let out = try predict(model, input)
            cache = try (0..<12).map { try PocketTTSCoreMLEngine.output(out, "next\($0)") }
            return (try PocketTTSCoreMLEngine.output(out, "hidden"), try PocketTTSCoreMLEngine.output(out, "eos")[0].floatValue)
            } }
        }
        func emptyMimiState() throws -> [String: MLMultiArray] {
            var result: [String: MLMultiArray] = [:]
            for (name, description) in mimiModel.modelDescription.inputDescriptionsByName where name != "latent" {
                guard let shape = description.multiArrayConstraint?.shape.map(\.intValue) else { throw Failure.invalidShape }
                result[name] = try PocketTTSCoreMLEngine.floats([Float](repeating: 0, count: shape.reduce(1,*)), shape: shape)
            }
            return result
        }
        func decode(_ latent: [Float], state: inout [String: MLMultiArray]) throws -> [Float] {
            try measure("mimi") { try autoreleasepool {
            try Task.checkCancellation()
            var input = state; input["latent"] = try PocketTTSCoreMLEngine.floats(latent, shape: [1,32])
            let out = try predict(mimiModel, input)
            for name in state.keys { state[name] = try PocketTTSCoreMLEngine.output(out, "next_\(name)") }
            return PocketTTSCoreMLEngine.values(try PocketTTSCoreMLEngine.output(out, "audio"))
            } }
        }
    }
}
