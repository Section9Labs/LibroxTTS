import Foundation
import Darwin
import CoreML
import KokoroCatalog
import PocketTTSMLX
import MLX

/// Resident graphs and bounded input workspaces. Render state remains invocation-owned.
final class PocketCoreMLExecutionPlan {
    let language: String
    let root: URL
    private let textAssets: PocketPreparedTextAssets
    let config: PocketTTSModelConfig
    let tokenizer: PocketTTSSentencePieceTokenizer
    let textModel: MLModel, latentModel: MLModel, mimiModel: MLModel
    let modelRoot: URL
    let compiledRoot: URL
    let configuration: MLModelConfiguration
    let bos: [Float]
    private let workspace = PocketPredictionWorkspace()
    var flows = PocketFlowModels<MLModel>()
    var collectTimings = false
    var timings: [String: PocketTTSCoreMLEngine.StageTiming] = [:]
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
            var row = timings[name] ?? PocketTTSCoreMLEngine.StageTiming()
            row.calls += 1; row.wallSeconds += ProcessInfo.processInfo.systemUptime - start
            row.cpuSeconds += cpu() - startedCPU; timings[name] = row
        }
        return try body()
    }
    init(language: String, assets: URL, models: URL?, placement: PocketTTSCoreMLEngine.Placement) throws {
        self.language = language; root = assets.appendingPathComponent(language); modelRoot = models?.appendingPathComponent(language) ?? PocketTTSCoreMLAssets.modelDirectory(in: assets, language: language)
        let prepared = try PocketPreparedTextAssets.load(root)
        textAssets = prepared; config = prepared.config; tokenizer = prepared.tokenizer
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: modelRoot.appendingPathComponent("manifest.json"))) as? [String: Any]
        let original = try PocketTTSCatalog.manifest(language: language).installedFiles.first { $0.path == "\(language)/model.safetensors" }
        guard manifest?["snapshot"] as? String == "a7056f505a4a8ca72d8b5fb1440071d6f1a35739",
              manifest?["weightsSHA256"] as? String == original?.sha256,
              manifest?["precision"] as? String == "float32", manifest?["gelu"] as? String == "tanh" else { throw PocketTTSCoreMLEngine.Failure.incompatibleModel }
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
        guard bos.count == 32 else { throw PocketTTSCoreMLEngine.Failure.invalidShape }
    }
    func flow(_ steps: Int) throws -> MLModel {
        try flows.model(steps: steps) { graph in
            try autoreleasepool {
                try MLModel(contentsOf: compiledRoot.appendingPathComponent(graph + ".mlmodelc"), configuration: configuration)
            }
        }
    }
    func sample(_ model: MLModel, steps: Int, condition: MLMultiArray, noise: [Float]) throws -> MLMultiArray {
        try measure("flow") { try autoreleasepool {
            let condition = try PocketTTSCoreMLEngine.flowCondition(condition)
            var latent = try workspace.noise(noise)
            for index in 0..<([4, 8].contains(steps) ? 1 : steps) {
                try Task.checkCancellation()
                var inputs: [String: Any] = ["condition": condition, "noise": latent]
                if ![4, 8].contains(steps) {
                    for (name, value) in try workspace.schedule(steps)[index] { inputs[name] = value }
                }
                let output = try predict(model, inputs)
                latent = try PocketTTSCoreMLEngine.output(output, "latent")
            }
            return latent
        } }
    }
    func chunks(_ text: String, options: PocketTTSChunkingOptions, role: PocketTTSPassageRole) throws -> [PocketTTSTextChunk] {
        try PocketTTSPassageChunker.plan(text, language: language, role: role, options: options,
            prepare: { try PocketTTSTextUtils.prepareTextPrompt($0, config: self.config, preserveSentenceBoundaries: options.grouping == .adaptive).0 },
            tokenCount: { self.tokenizer.encode($0).count })
    }
    func voice(_ name: String) throws -> [MLMultiArray] {
        if let native = try? PocketVoiceArchive.read(root.appendingPathComponent("embeddings/\(name).safetensors")) { return native }
        return try Device.withDefaultDevice(.cpu) {
            let arrays = try MLX.loadArrays(url: root.appendingPathComponent("embeddings/\(name).safetensors"))
            var caches: [MLMultiArray] = []
            for i in 0..<6 {
                let prefix = "transformer.layers.\(i).self_attn/"
                guard let kv = arrays[prefix + "cache"], let offset = arrays[prefix + "offset"] else { throw PocketTTSCoreMLEngine.Failure.invalidShape }
                let n = offset.item(Int.self)
                guard kv.ndim == 5, kv.shape[0] == 2, kv.shape[1] == 1, kv.shape[3] == 16, kv.shape[4] == 64,
                      n > 0, n <= kv.shape[2], n <= 512 else { throw PocketTTSCoreMLEngine.Failure.invalidShape }
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
        guard cache.count == 12, cache[0].shape[2].intValue <= 4096, value.shape[1].intValue <= 512 else { throw PocketTTSCoreMLEngine.Failure.cacheLimit }
        var input: [String: Any] = ["value": value, "position": try workspace.position(cache[0].shape[2].intValue)]
        for i in 0..<12 { input["cache\(i)"] = cache[i] }
        let out = try predict(model, input)
        cache = try (0..<12).map { try PocketTTSCoreMLEngine.output(out, "next\($0)") }
        return (try PocketTTSCoreMLEngine.output(out, "hidden"), try PocketTTSCoreMLEngine.output(out, "eos")[0].floatValue)
        } }
    }
    func emptyMimiState() throws -> [String: MLMultiArray] {
        var result: [String: MLMultiArray] = [:]
        for (name, description) in mimiModel.modelDescription.inputDescriptionsByName where name != "latent" {
            guard let shape = description.multiArrayConstraint?.shape.map(\.intValue) else { throw PocketTTSCoreMLEngine.Failure.invalidShape }
            result[name] = try PocketTTSCoreMLEngine.floats([Float](repeating: 0, count: shape.reduce(1,*)), shape: shape)
        }
        return result
    }
    func decode(_ latent: MLMultiArray, state: inout [String: MLMultiArray]) throws -> [Float] {
        try measure("mimi") { try autoreleasepool {
        try Task.checkCancellation()
        var input = state; input["latent"] = latent
        let out = try predict(mimiModel, input)
        for name in state.keys { state[name] = try PocketTTSCoreMLEngine.output(out, "next_\(name)") }
        return PocketTTSCoreMLEngine.values(try PocketTTSCoreMLEngine.output(out, "audio"))
        } }
    }
}
