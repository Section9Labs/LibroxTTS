import Foundation
import Testing
import MLX
import LibroxTTS
@testable import PocketTTSMLX

@Suite(.serialized)
struct PocketResourceTests {
    // Even CPU MLX initialization needs its compiled Metal library in SwiftPM
    // test runners. Run this runtime fixture with the same explicit prerequisite
    // as the real-assets tests; admission/cancellation logic stays unconditional.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_METALLIB"] != nil))
    func residualResetDiscardsUnmatchedAudio() {
        PocketTestMetal.configure()
        Device.withDefaultDevice(.cpu) {
            let add = StreamingAdd()
            _ = add.step(lhs: MLXArray([Float(1)]).reshaped([1, 1, 1]),
                         rhs: MLXArray([Float(10), 20]).reshaped([1, 1, 2]))
            add.resetState()
            let fresh = add.step(lhs: MLXArray([Float(3)]).reshaped([1, 1, 1]),
                                 rhs: MLXArray([Float(4)]).reshaped([1, 1, 1]))
            #expect(fresh.asArray(Float.self) == [7])
        }
    }

    @Test func admissionUsesAvailableProcessBudget() throws {
        #expect(PocketTTSResourceMonitor.loadReservation(fileBytes: 100) == 200)
        #expect(PocketTTSResourceMonitor.loadReservation(fileBytes: UInt64.max) == UInt64.max)
        try PocketTTSResourceMonitor.check(available: 200, required: 200, criticalThermal: false)
        try PocketTTSResourceMonitor.check(available: nil, required: 200, criticalThermal: false)
        #expect(throws: PocketTTSResourceError.memory(availableBytes: 199, requiredBytes: 200)) {
            try PocketTTSResourceMonitor.check(available: 199, required: 200, criticalThermal: false)
        }
        #expect(throws: PocketTTSResourceError.thermal) {
            try PocketTTSResourceMonitor.check(available: 300, required: 200, criticalThermal: true)
        }
    }

    @Test func explicitCancellationWinsOverResourceFallback() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try PocketTTSResourceMonitor.check(available: 0, required: 200, criticalThermal: true)
        }
        do { try await task.value; Issue.record("Cancellation was lost") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
    func repeatedSamplingProfilesReportRetainedMemory() async throws {
        PocketTestMetal.configure()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_ASSETS"]!)
        let engine = PocketTTSEngine(directory: directory)
        await engine.setResourceObserver { snapshot in
            if snapshot.phase == "operation-complete", let data = try? JSONEncoder().encode(snapshot) {
                print("RESOURCE " + String(decoding: data, as: UTF8.self))
            }
        }
        for steps in [1, 2, 4, 8, 8, 4, 2, 1] {
            let result = try await engine.synthesize(
                "The road followed the river through the valley. At the bridge, she stopped to listen. " +
                "Water moved over the stones, and somewhere beyond the trees a bird answered another bird.",
                voiceID: "pocket-alba-en-v1", samplerSteps: steps)
            #expect(!result.samples.isEmpty)
            #expect(result.samples.allSatisfy { $0.isFinite })
        }
        await engine.unload()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
    func cancelledPhasesRetireAndSameEngineRendersAgain() async throws {
        PocketTestMetal.configure()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_ASSETS"]!)
        let engine = PocketTTSEngine(directory: directory)
        for phase in ["load-weights", "load-tensor", "load-conditioning", "before-prefill", "before-flow", "before-codec", "after-codec"] {
            await engine.unload()
            await engine.setResourceObserver { snapshot in
                if snapshot.phase == phase { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let operation = Task {
                try await engine.synthesize("A quiet room.", voiceID: "pocket-alba-en-v1", samplerSteps: 2)
            }
            do { _ = try await operation.value; Issue.record("No cancellation at \(phase)") }
            catch is CancellationError {}
            await engine.setResourceObserver(nil)
            let result = try await engine.synthesize("The morning was bright.", voiceID: "pocket-alba-en-v1", samplerSteps: 2)
            #expect(!result.samples.isEmpty)
            #expect(result.samples.allSatisfy { $0.isFinite })
        }
        await engine.unload()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
    func cancelledFacadeRenderRetiresBeforeUnrelatedReplacement() async throws {
        PocketTestMetal.configure()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_ASSETS"]!)
        let renderer = NarrationRenderer(compactDirectory: directory, harmonicSource: nil)
        let pipeline = NarrationPipeline()
        let oldPlan = try await pipeline.plan("The river ran beneath the bridge.", model: .pocket,
            bookID: "fixture", chapterID: "old", narratorVoiceID: "pocket-alba-en-v1", language: "en",
            pocketSampling: .init(temperature: 0.3, samplerSteps: 8))
        let newPlan = try await pipeline.plan("Outside, the morning was bright.", model: .pocket,
            bookID: "fixture", chapterID: "new", narratorVoiceID: "pocket-alba-en-v1", language: "en",
            pocketSampling: .init(temperature: 0, samplerSteps: 8))
        let oldUnit = try #require(oldPlan.units.first)
        let newUnit = try #require(newPlan.units.first)
        let reference = PocketTTSEngine(directory: directory)
        let expected = try await reference.synthesize(newUnit.synthesisText, voiceID: newUnit.voiceID,
            temperature: 0, samplerSteps: 8).samples
        await reference.unload()
        for phase in ["load-tensor", "before-prefill", "before-flow", "after-codec"] {
            await renderer.unload()
            await renderer.setMaxResourceObserver { snapshot in
                if snapshot.phase == phase { withUnsafeCurrentTask { $0?.cancel() } }
            }
            try await renderer.load(.pocket, directory: directory, executionContext: .foreground)
            let operation = Task { try await renderer.render(oldUnit) }
            do { _ = try await operation.value; Issue.record("Cancelled facade unit returned audio") }
            catch is CancellationError {}
            await renderer.setMaxResourceObserver(nil)
            // No new renderer or model-selection rewrite after cancellation.
            let replacement = try await renderer.render(newUnit)
            #expect(!replacement.isEmpty)
            #expect(replacement.allSatisfy { $0.isFinite })
            #expect(replacement.count == expected.count)
            #expect(zip(replacement, expected).allSatisfy { abs($0 - $1) < 0.000001 })
        }
        await renderer.unload()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
    func decoderStateIsReleasedOnCallbackFailureAndCompletion() throws {
        PocketTestMetal.configure()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_ASSETS"]!).appendingPathComponent("en")
        let model = try PocketTTSModel.fromModelDirectory(directory)
        model.lsd_decode_steps = 1
        do {
            try model.render(text: "A quiet room.", voice: "alba") { _ in throw CancellationError() }
            Issue.record("Expected callback failure")
        } catch is CancellationError {}
        #expect(model.mimi.decoderCache.allSatisfy { $0.state.isEmpty && $0.offset == 0 })
        var count = 0
        try model.render(text: "The morning was bright.", voice: "alba") { count += $0.count }
        #expect(count > 0)
        #expect(model.mimi.decoderCache.allSatisfy { $0.state.isEmpty && $0.offset == 0 })
    }
}
