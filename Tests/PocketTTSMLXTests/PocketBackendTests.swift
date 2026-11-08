import Foundation
import Testing
import MLX
import LibroxTTS
import PocketTTSMLX

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
func pocketCPUAndGPUTransitionsKeepSamplingAndText() async throws {
    let env = ProcessInfo.processInfo.environment
    PocketTestMetal.configure()
    let directory = URL(fileURLWithPath: env["POCKET_ASSETS"]!)
    let engine = PocketTTSEngine(directory: directory, backend: .cpu)
    let text = "The library was quiet."
    let voice = "pocket-alba-en-v1"
    let initial = try await engine.synthesize(text, voiceID: voice, temperature: 0, samplerSteps: 8)
    #expect(initial.samples.count > 24_000)
    #expect(initial.samples.allSatisfy { $0.isFinite })
    await engine.setBackend(.gpu)
    let gpu = try await engine.synthesize(text, voiceID: voice, temperature: 0, samplerSteps: 8)
    #expect(gpu.samples.count > 24_000)
    #expect(gpu.samples.allSatisfy { $0.isFinite })
    await engine.setBackend(.cpu)
    let repeated = try await engine.synthesize(text, voiceID: voice, temperature: 0, samplerSteps: 8)
    #expect(repeated.samples.count == initial.samples.count)
    #expect(zip(repeated.samples, initial.samples).allSatisfy { abs($0 - $1) < 0.00001 })
    let renderer = NarrationRenderer(compactDirectory: directory, harmonicSource: nil)
    let plan = try await NarrationPipeline().plan(text, model: .pocket, bookID: "test", chapterID: "cpu",
        narratorVoiceID: voice, language: "en", pocketSampling: .init(temperature: 0, samplerSteps: 8))
    for context: NarrationRenderer.ExecutionContext in [.background, .foreground, .background] {
        try await renderer.load(.pocket, directory: directory, executionContext: context)
        let result = try await renderer.render(try #require(plan.units.first))
        #expect(result.count > 24_000)
        #expect(result.allSatisfy { $0.isFinite })
    }
    await renderer.unload()
    await engine.unload()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
func pocketCancelledRenderDoesNotPublishAndCanChangeBackend() async throws {
    let env = ProcessInfo.processInfo.environment
    PocketTestMetal.configure()
    let directory = URL(fileURLWithPath: env["POCKET_ASSETS"]!)
    let engine = PocketTTSEngine(directory: directory)
    // Cancel at a real frame boundary while GPU model and random state exist.
    // The callback's error must escape rather than return a successful unit.
    let work = Task {
        try await engine.renderFrames("The library was quiet. She opened the book slowly.",
            voiceID: "pocket-alba-en-v1", samplerSteps: 8) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
    }
    do {
        try await work.value
        Issue.record("Cancelled frame stream was published as a completed render")
    } catch is CancellationError {}
    await engine.setBackend(.cpu)
    await engine.setRandomSeed(42)
    let recovered = try await engine.synthesize("She opened the book.", voiceID: "pocket-alba-en-v1", samplerSteps: 8)
    #expect(recovered.samples.count > 24_000)
    #expect(recovered.samples.allSatisfy { $0.isFinite })
    await engine.unload()
}
