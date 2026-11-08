import Foundation
import Testing
import MLX
import MLXNN
@testable import PocketTTSMLX

/// Experiment only: checkpoint-exact BF16 storage, FP32 math. Never installed
/// into the production model by this file. Run alone for meaningful MLX peaks.
private final class CheckpointStoredLinear: Linear {
    var materialize = true
    var asynchronous = false
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let expanded = weight.asType(.float32)
        let output: MLXArray
        if let bias { output = addMM(bias, x, expanded.T) }
        else { output = matmul(x, expanded.T) }
        // Release the expanded weight before the next layer creates its copy.
        if materialize {
            if asynchronous { asyncEval(output) } else { eval(output) }
        }
        return output
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_STORAGE_EXPERIMENT"] == "1"))
func checkpointExactCompactStorageExperiment() throws {
    PocketTestMetal.configure()
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_ASSETS"]!).appendingPathComponent("en")
    let backend = ProcessInfo.processInfo.environment["POCKET_STORAGE_BACKEND"] ?? "gpu"
    let scope = ProcessInfo.processInfo.environment["POCKET_STORAGE_SCOPE"] ?? "transformer"
    let boundaries = ProcessInfo.processInfo.environment["POCKET_STORAGE_BOUNDARIES"] ?? "linear"
    func run(compact: Bool) throws -> [Float] {
        try Device.withDefaultDevice(backend == "cpu" ? .cpu : .gpu) {
        Memory.clearCache()
        let model = try PocketTTSModel.fromModelDirectory(directory)
        model.lsd_decode_steps = 8
        model.temp = 0.3
        var savedBytes = 0
        if compact {
            var replacements: [(String, Module)] = []
            for (path, module) in model.leafModules().flattened() {
                guard path.hasPrefix("flow_lm.transformer."), let linear = module as? Linear else { continue }
                if scope == "feedforward", !path.hasSuffix("linear1"), !path.hasSuffix("linear2") { continue }
                let stored = linear.weight.asType(.bfloat16)
                // This route is exact storage only, never a weight quantizer.
                let exact = MLX.all(linear.weight .== stored.asType(.float32)).item(Bool.self)
                try #require(exact, "Checkpoint values are not BF16-exact at \(path)")
                eval(stored)
                savedBytes += linear.weight.nbytes - stored.nbytes
                let replacement = CheckpointStoredLinear(weight: stored, bias: linear.bias)
                replacement.materialize = boundaries == "linear" || path.hasSuffix("linear2") || path.hasSuffix("out_proj")
                replacement.asynchronous = boundaries == "async"
                replacements.append((path, replacement))
            }
            try model.update(modules: ModuleChildren.unflattened(replacements), verify: .all)
        }
        eval(model)
        Memory.clearCache()
        let resident = Memory.activeMemory
        Memory.peakMemory = 0
        let start = ProcessInfo.processInfo.systemUptime
        var samples: [Float] = []
        try withRandomState(MLXRandom.RandomState(seed: 42)) {
            try model.render(text: "The road followed the river through the valley. At the bridge, she stopped to listen.",
                voice: "alba", checkpoint: { _ in
                    if Memory.cacheMemory > 32 * 1_048_576 { Memory.clearCache() }
                }) { samples += $0 }
        }
        let row: [String: Any] = ["compact": compact, "backend": backend, "boundaries": boundaries, "scope": scope, "residentMLXBytes": resident,
            "peakMLXBytes": Memory.peakMemory, "savedWeightBytes": savedBytes,
            "renderSeconds": ProcessInfo.processInfo.systemUptime - start, "samples": samples.count]
        print("STORAGE " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        return samples
        }
    }
    let baseline = try run(compact: false)
    let compact = try run(compact: true)
    #expect(baseline.count == compact.count)
    let maxError = zip(baseline, compact).map { abs($0 - $1) }.max() ?? 0
    print("STORAGE maximumPCMError=\(maxError)")
    #expect(maxError == 0)
}
