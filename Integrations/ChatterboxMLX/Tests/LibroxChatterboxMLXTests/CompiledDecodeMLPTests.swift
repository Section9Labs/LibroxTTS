#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import Testing
import MLX
import MLXNN
import Cmlx
import ChatterboxCoreML
import LibroxChatterbox
@testable import LibroxChatterboxMLX

struct DecoderExecutionIdentityTests {
    @Test func explicitTrialSeparatesCachesWithoutChangingDefault() throws {
        let units = PipelineComputeUnits()
        let original = ChatterboxMLXRenderer.renderingProfileIdentifier(decoderProfile: .mixedFloat16Accurate,
            acousticComputeUnits: units)
        let eager = ChatterboxMLXRenderer.renderingProfileIdentifier(decoderProfile: .mixedFloat16Accurate,
            acousticComputeUnits: units, decoderExecution: .eager)
        let trial = ChatterboxMLXRenderer.renderingProfileIdentifier(decoderProfile: .mixedFloat16Accurate,
            acousticComputeUnits: units, decoderExecution: .compiledDecodeMLPTrial)
        #expect(original == eager)
        #expect(trial == original + ":decoderexecution=compiled-decode-mlp-1")
        let request = try ChatterboxRequest(text: "Hello.", language: "en", seed: 42)
        let sha = String(repeating: "a", count: 64)
        let a = try request.cacheKey(modelManifestSHA256: sha, conditioningSHA256: sha, rendererProfile: original)
        let b = try request.cacheKey(modelManifestSHA256: sha, conditioningSHA256: sha, rendererProfile: trial)
        #expect(a != b)
    }
}

struct CompiledDecodeMLPTests {
    private enum Failure: Error { case control }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHATTERBOX_COMPILED_MLP_TEST_REPORT"] != nil,
                   "Explicit tiny GPU compilation qualification only"))
    func liveWeightUpdatesAndNoRetainCycle() throws {
        guard let path = ProcessInfo.processInfo.environment["CHATTERBOX_TOY_METALLIB"],
              let report = ProcessInfo.processInfo.environment["CHATTERBOX_COMPILED_MLP_TEST_REPORT"] else { throw Failure.control }
        let began = ContinuousClock.now
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try #require(fd >= 0)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat(); try #require(fstat(fd, &info) == 0)
        try #require(info.st_mode & S_IFMT == S_IFREG && info.st_size == 2_401_016)
        let data = try file.read(upToCount: 2_401_017) ?? Data()
        try #require(data.count == 2_401_016)
        try #require(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() ==
                     "282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f")
        let rc = path.withCString { mlx_metal_set_metallib_path($0) }; try #require(rc == 0)
        try #require(!FileManager.default.fileExists(atPath: report))
        func healthy() throws {
            try Task.checkCancellation()
            guard began.duration(to: .now) < .seconds(15), Memory.activeMemory < 128 * 1024 * 1024,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled,
                  ProcessInfo.processInfo.thermalState != .serious,
                  ProcessInfo.processInfo.thermalState != .critical else { throw Failure.control }
        }
        struct Receipt: Codable { let completed, sameBitsBeforeUpdate, sameBitsAfterUpdate, outputChanged, ownerReleased, childReleased: Bool }
        let result = try Device.withDefaultDevice(.gpu) {
            var config = LlamaBackboneConfig.llama520M
            config.hiddenSize = 8; config.intermediateSize = 16
            let eager = T3MLP(config)
            var candidate: T3MLP? = T3MLP(config, compiledDecode: true)
            weak var owner = candidate
            weak var child = candidate?.gate
            func load(_ module: T3MLP, factor: Float) throws {
                let weights = ["gate_proj.weight": MLXArray.ones([16, 8], dtype: .float16) * factor,
                    "up_proj.weight": MLXArray.ones([16, 8], dtype: .float16) * Float(0.125),
                    "down_proj.weight": MLXArray.ones([8, 16], dtype: .float16) * Float(0.125)]
                try module.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
                eval(module)
            }
            func bits(_ module: T3MLP) throws -> [UInt32] {
                try healthy()
                let x = MLXArray.ones([2, 1, 8], dtype: .float32) * Float(0.25)
                let y = module(x, projectionType: .float16, accurateActivations: true)
                eval(y); try healthy()
                guard y.dtype == .float32, y.shape == [2, 1, 8] else { throw Failure.control }
                return y.asArray(Float.self).map(\.bitPattern)
            }
            try load(eager, factor: 0.125); try load(candidate!, factor: 0.125)
            let before = try bits(eager), compiledBefore = try bits(candidate!)
            try load(eager, factor: 0.25); try load(candidate!, factor: 0.25)
            let after = try bits(eager), compiledAfter = try bits(candidate!)
            candidate = nil
            return Receipt(completed: before == compiledBefore && after == compiledAfter && compiledBefore != compiledAfter && owner == nil && child == nil, sameBitsBeforeUpdate: before == compiledBefore,
                sameBitsAfterUpdate: after == compiledAfter, outputChanged: compiledBefore != compiledAfter,
                ownerReleased: owner == nil, childReleased: child == nil)
        }
        try healthy()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: report), options: .withoutOverwriting)
        try #require(result.sameBitsBeforeUpdate && result.sameBitsAfterUpdate && result.outputChanged && result.ownerReleased && result.childReleased)
    }
}
#endif
