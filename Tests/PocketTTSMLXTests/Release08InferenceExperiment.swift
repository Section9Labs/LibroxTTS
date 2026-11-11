import CryptoKit
import Foundation
import MLX
import MLXNN
import MLXRandom
import Testing
@testable import PocketTTSMLX

// Benchmark-only capacity cache. Never selected by production inference.
private final class CapacityCache08 {
    private var keys: MLXArray?
    private var values: MLXArray?
    private(set) var offset = 0
    func update(_ key: MLXArray, _ value: MLXArray) -> [MLXArray] {
        let end = offset + key.shape[2]
        if keys == nil || end > keys!.shape[2] {
            let extra = ((end + 255) / 256) * 256 - (keys?.shape[2] ?? 0)
            let padding = MLXArray.zeros([1, 16, extra, 64])
            keys = keys.map { concatenated([$0, padding], axis: 2) } ?? padding
            values = values.map { concatenated([$0, padding], axis: 2) } ?? MLXArray.zeros([1, 16, extra, 64])
        }
        keys![0..., 0..., offset..<end, 0...] = key
        values![0..., 0..., offset..<end, 0...] = value
        offset = end
        return [keys![0..., 0..., ..<end, 0...], values![0..., 0..., ..<end, 0...]]
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIBROX_08_INFERENCE_EXPERIMENT"] == "1"))
func release08InferenceProfileAndCacheExperiment() throws {
    PocketTestMetal.configure()
    let env = ProcessInfo.processInfo.environment
    let assets = URL(fileURLWithPath: try #require(env["POCKET_ASSETS"]))
    let output = URL(fileURLWithPath: try #require(env["LIBROX_08_INFERENCE_OUTPUT"]))
    var profile: [[String: Any]] = [], caches: [[String: Any]] = []
    for backend in ["gpu", "cpu"] {
        try Device.withDefaultDevice(backend == "cpu" ? .cpu : .gpu) {
            let loadStart = ProcessInfo.processInfo.systemUptime
            let model = try PocketTTSModel.fromModelDirectory(assets.appendingPathComponent("en"))
            let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
            model.lsd_decode_steps = 4; model.temp = 0.3
            var reference: Data?
            for iteration in 0..<3 {
                Memory.clearCache(); Memory.peakMemory = 0
                var samples: [Float] = [], stages: [String: Double] = [:]
                var previous = "start", last = ProcessInfo.processInfo.systemUptime
                let start = last
                try withRandomState(MLXRandom.RandomState(seed: 42)) {
                    try model.render(text: "The road followed the river through the valley. At the bridge, she stopped to listen. The wind moved through the trees, and somewhere beyond the fields a bell began to ring.",
                        voice: "alba", chunking: .carefulReading, checkpoint: { phase in
                            let now = ProcessInfo.processInfo.systemUptime
                            stages[previous, default: 0] += now - last
                            previous = phase; last = now
                        }) { samples += $0 }
                }
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let bytes = samples.withUnsafeBytes { Data($0) }
                if let reference { #expect(bytes == reference, "Repeated seeded PCM changed on \(backend)") }
                else { reference = bytes }
                profile.append(["backend": backend, "iteration": iteration, "cold": iteration == 0,
                    "loadSeconds": loadSeconds, "renderSeconds": seconds, "samples": samples.count,
                    "peakMLXBytes": Memory.peakMemory, "intervalSeconds": stages,
                    "pcmSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()])
            }
        }
        Device.withDefaultDevice(backend == "cpu" ? .cpu : .gpu) {
            // ABBA at three history lengths. Six flow-transformer layers, exact
            // append values, and materialization each frame. No attention/codec.
            for steps in [128, 512, 1500] {
                for capacity in [false, true, true, false] {
                    Memory.clearCache(); Memory.peakMemory = 0
                    let ordinary = (0..<6).map { _ in KVCacheSimple() }
                    let reserved = (0..<6).map { _ in CapacityCache08() }
                    let prompt = MLXArray.ones([1, 16, 128, 64])
                    let frame = MLXArray.ones([1, 16, 1, 64]) * 2
                    eval(prompt, frame)
                    var frozen: [MLXArray] = [], final: [MLXArray] = []
                    let start = ProcessInfo.processInfo.systemUptime
                    for step in 0...steps {
                        let value = step == 0 ? prompt : frame
                        var frameState: [MLXArray] = []
                        for layer in 0..<6 {
                            let result: [MLXArray]
                            if capacity { result = reserved[layer].update(value, value) }
                            else {
                                let pair = ordinary[layer].update(keys: value, values: value)
                                result = [pair.0, pair.1]
                            }
                            frameState += result
                            if step == 0, layer == 0 { frozen = result }
                            if step == steps, layer == 0 { final = result }
                        }
                        eval(frameState)
                    }
                    let seconds = ProcessInfo.processInfo.systemUptime - start
                    let peak = Memory.peakMemory
                    #expect(frozen[0].shape == [1, 16, 128, 64])
                    #expect(MLX.all(frozen[0] .== 1).item(Bool.self), "Published snapshot mutated")
                    #expect(MLX.all(frozen[1] .== 1).item(Bool.self))
                    for tensor in final {
                        #expect(tensor.shape == [1, 16, 128 + steps, 64])
                        #expect(MLX.all(tensor[0..., 0..., ..<128, 0...] .== 1).item(Bool.self))
                        #expect(MLX.all(tensor[0..., 0..., 128..., 0...] .== 2).item(Bool.self))
                    }
                    caches.append(["backend": backend, "capacity": capacity, "steps": steps,
                                   "seconds": seconds, "peakMLXBytes": peak])
                }
            }
        }
    }
    let report: [String: Any] = ["profile": profile, "cache": caches,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "note": "Checkpoint intervals include lazy work; before-codec includes deferred flow sampling. Cache timings omit attention and codec and are not end-to-end gains."]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
}
