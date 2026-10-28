import Foundation
import Testing
import ChatterboxCoreML
import CoreML
@testable import LibroxChatterbox

@Test func computePoliciesPreserveSafeStageDefaults() {
    let automatic = ChatterboxNarrator.pipelineComputeUnits(for: .automatic)
    #expect(automatic.t3 == nil)
    #expect(automatic.cfm == nil)
    let neural = ChatterboxNarrator.pipelineComputeUnits(for: .neuralEngine)
    #expect(neural.t3 == .cpuAndNeuralEngine)
    #expect(neural.encoder == .cpuOnly)
    #expect(neural.cfm == .cpuAndNeuralEngine)
    let t3GPU = ChatterboxNarrator.pipelineComputeUnits(for: .automatic, t3Override: .cpuAndGPU)
    #expect(t3GPU.t3 == .cpuAndGPU)
    #expect(t3GPU.encoder == automatic.encoder)
    #expect(t3GPU.cfm == automatic.cfm)
    #expect(t3GPU.vocoder == automatic.vocoder)
    #expect(t3GPU.watermark == automatic.watermark)
}

@Test func rejectsUnvalidatedGPUReferenceBeforeLoadingModels() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("reference.wav")
    try Data([0]).write(to: audio)
    let narrator = ChatterboxNarrator()
    await #expect(throws: ChatterboxNarrationError.unverifiedGPUTokenizer) {
        try await narrator.prepareReference(audioFile: audio, modelsDirectory: dir,
            outputFile: dir.appendingPathComponent("new.safetensors"), computePolicy: .gpu)
    }
    try await narrator.unload()
}

@Test func referenceDurationBoundsFailBeforeModelLoad() async {
    for seconds in [0, 16] {
        await #expect(throws: ChatterboxError.self) {
            _ = try await VoiceCloner(modelDirectory: URL(fileURLWithPath: "/no-models"),
                                      encoderConditioningSeconds: seconds)
        }
    }
}

/// Opt-in asset test: reads tokenizer JSON only, no model inference/download.
/// Gold IDs came from Python mlx_audio MTLTokenizer with NFKD,fullcase and this
/// pinned Core ML tokenizer.json; Swift adds the explicit SOT=255/EOT=0 pair.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CHATTERBOX_TEST_MODEL_DIR"] != nil))
func englishSpanishFullcaseTokenParity() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["CHATTERBOX_TEST_MODEL_DIR"])
    let tokenizer = try await MTLTextTokenizer(modelFolder: URL(fileURLWithPath: path))
    #expect(tokenizer.encode("Hello WORLD.", language: "en") == [255,708,284,18,84,28,2,299,291,294,288,280,9,0])
    #expect(tokenizer.encode("¿Cómo Estás?", language: "es") == [255,635,360,279,28,764,115,2,281,63,14,764,32,13,0])
}
