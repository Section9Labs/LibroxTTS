import XCTest
import Synchronization
import KokoroNarration
import PocketTTSMLX
@testable import LibroxTTS

private actor ControlledMax: NarrationMaxBackend {
    nonisolated let isCoreML = true
    let renderGate: NarrationAdmission
    let configurationGate: NarrationAdmission?
    var events: [String] = []
    var active = 0
    var failure: PocketTTSResourceError?
    var loadedLanguage: String? { "en" }
    init(renderGate: NarrationAdmission = .init(), configurationGate: NarrationAdmission? = nil) {
        self.renderGate = renderGate; self.configurationGate = configurationGate
    }
    func fail(with error: PocketTTSResourceError?) { failure = error }
    func unload() { XCTAssertEqual(active, 0); events.append("unload") }
    func setContext(_ context: NarrationRenderer.ExecutionContext, cpuBudget: Double?) async {
        events.append("context:\(String(describing: cpuBudget))")
        if let configurationGate { await configurationGate.acquire(); configurationGate.release() }
    }
    func setBudget(_ fraction: Double?, context: NarrationRenderer.ExecutionContext) { events.append("budget") }
    func setObserver(_ observer: (@Sendable (PocketTTSResourceSnapshot) -> Void)?) {
        events.append(observer == nil ? "observer-off" : "observer-on")
    }
    func synthesize(_ unit: BookNarrationUnit) async throws -> [Float] {
        try await renderFrames(unit, onTextChunk: { _ in }, receive: { _ in })
        return [Float](repeating: 0.25, count: 1920)
    }
    func renderFrames(_ unit: BookNarrationUnit,
                      onTextChunk: @Sendable (PocketTTSChunkProgress) throws -> Void,
                      receive: @Sendable ([Float]) throws -> Void) async throws {
        events.append("render-start"); active += 1
        defer { active -= 1; events.append("render-finish") }
        await renderGate.acquire(); renderGate.release()
        try Task.checkCancellation()
        if let failure { throw failure }
        try receive([Float](repeating: 0.25, count: 1920))
        try onTextChunk(.init(text: unit.synthesisText, startSample: 0, endSample: 1920))
    }
}

@MainActor final class NarrationLifecycleTests: XCTestCase {
    private var unit: BookNarrationUnit {
        .init(sourceText: "Hello.", sourceRange: NSRange(location: 0, length: 6),
              narratorID: "pocket-caro_davy-en-v1", boundaryAfter: .sentence)
    }
    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        let result = await condition()
        XCTAssertTrue(result)
    }

    func testDefaultLevelUsesVoiceAndStyleWithoutChangingFrameAcceptance() async throws {
        let engine = ControlledMax()
        let renderer = NarrationRenderer(compactDirectory: .temporaryDirectory, admission: .init(), maxFactory: { _, _ in engine })
        try await renderer.load(.pocket, directory: .temporaryDirectory)
        for voice in ["caro_davy", "bill_boerst", "peter_yearsley", "stuart_bell"] {
            for style: PocketTTSDeliveryStyle in [.original, .neutral, .calm, .shout] {
                var passage = BookNarrationUnit(sourceText: "Hello.", sourceRange: NSRange(location: 0, length: 6),
                    narratorID: "pocket-\(voice)-en-v1", boundaryAfter: .sentence)
                passage.pocketDeliveryStyle = style
                let gain = PocketNarrationLevel.gain(voiceID: passage.voiceID, style: style)
                let expected = PocketNarrationLevel.apply([Float](repeating: 0.25, count: 1920), gain: gain)
                let buffered = try await renderer.render(passage)
                XCTAssertEqual(buffered, expected)
                let capture = Mutex((samples: [Float](), events: 0))
                try await renderer.renderPocketFrames(passage, onTextChunk: { event in
                    capture.withLock {
                        XCTAssertEqual(event.startSample, 0)
                        XCTAssertEqual(event.endSample, $0.samples.count)
                        $0.events += 1
                    }
                }, receive: { frame in capture.withLock { $0.samples += frame } })
                XCTAssertEqual(capture.withLock { $0.samples }, buffered)
                XCTAssertEqual(capture.withLock { $0.events }, 1)
            }
        }
        await renderer.unload()
    }

    func testQueuedCancellationAndUnloadCannotOvertakeActiveFrames() async throws {
        let gate = NarrationAdmission(), admission = NarrationAdmission()
        await gate.acquire()
        let engine = ControlledMax(renderGate: gate)
        let renderer = NarrationRenderer(compactDirectory: .temporaryDirectory, admission: admission, maxFactory: { _, _ in engine })
        try await renderer.load(.pocket, directory: .temporaryDirectory)
        let count = Mutex(0)
        let streaming = Task { try await renderer.renderPocketFrames(unit, receive: { frame in count.withLock { $0 += frame.count } }) }
        await waitUntil { await engine.active == 1 }
        let cancelled = Mutex(false)
        let queued = Task {
            do { _ = try await renderer.render(unit); XCTFail("Cancelled work rendered") }
            catch is CancellationError { cancelled.withLock { $0 = true } }
            catch { XCTFail("\(error)") }
        }
        await waitUntil { admission.queuedCount == 1 }
        queued.cancel()
        await waitUntil { cancelled.withLock { $0 } }
        let unload = Task { await renderer.unload() }
        await waitUntil { admission.queuedCount == 1 }
        unload.cancel()
        let before = await engine.events
        XCTAssertFalse(before.contains("unload"))
        gate.release()
        try await streaming.value
        await queued.value; await unload.value
        let after = await engine.events
        XCTAssertEqual(after.suffix(3), ["render-start", "render-finish", "unload"])
        XCTAssertEqual(count.withLock { $0 }, 1920)
        do { _ = try await renderer.render(unit); XCTFail("Retired engine rendered") }
        catch NarrationRenderer.RenderError.invalidAudio {}
    }

    func testReceiverFailureAndResourceErrorsReleaseLeaseAndPreserveErrors() async throws {
        enum ReceiverFailure: Error { case rejected }
        let engine = ControlledMax()
        let renderer = NarrationRenderer(compactDirectory: .temporaryDirectory, admission: .init(), maxFactory: { _, _ in engine })
        try await renderer.load(.pocket, directory: .temporaryDirectory)
        do {
            try await renderer.renderPocketFrames(unit, onTextChunk: { _ in XCTFail("Failed frame completed a chunk") },
                receive: { _ in throw ReceiverFailure.rejected })
            XCTFail("Receiver failure was lost")
        } catch ReceiverFailure.rejected {}
        for resource in [PocketTTSResourceError.memory(availableBytes: 1, requiredBytes: 2), .thermal] {
            await engine.fail(with: resource)
            for streaming in [false, true] {
                do {
                    if streaming { try await renderer.renderPocketFrames(unit, receive: { _ in XCTFail("Resource failure emitted frames") }) }
                    else { _ = try await renderer.render(unit) }
                    XCTFail("Resource error was lost")
                } catch let error as NarrationRenderer.RenderError {
                    switch (resource, error) {
                    case (.memory, .memory), (.thermal, .thermal): break
                    default: XCTFail("Error mapping changed")
                    }
                }
            }
        }
        await engine.fail(with: nil)
        let recovered = try await renderer.render(unit)
        XCTAssertEqual(recovered.count, 1920)
        await renderer.unload()
    }

    func testCancellationDuringConfigurationRetiresUnpublishedEngine() async throws {
        let gate = NarrationAdmission()
        await gate.acquire()
        let engine = ControlledMax(configurationGate: gate)
        let renderer = NarrationRenderer(compactDirectory: .temporaryDirectory, admission: .init(), maxFactory: { _, _ in engine })
        let loading = Task { try await renderer.load(.pocket, directory: .temporaryDirectory) }
        await waitUntil { gate.queuedCount == 1 }
        loading.cancel(); gate.release()
        do { try await loading.value; XCTFail("Cancelled load succeeded") } catch is CancellationError {}
        let events = await engine.events
        XCTAssertEqual(events.last, "unload")
        do { _ = try await renderer.render(unit); XCTFail("Partial load was published") }
        catch NarrationRenderer.RenderError.invalidAudio {}
    }

    func testIdentityReuseFailedReplacementAndPersistentSettings() async throws {
        let engine = ControlledMax(), factories = Mutex(0)
        let missing = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let renderer = NarrationRenderer(compactDirectory: missing, admission: .init(), maxFactory: { _, _ in
            factories.withLock { $0 += 1 }; return engine
        })
        await renderer.setCPUBudget(fraction: 0.2)
        await renderer.setMaxResourceObserver { _ in }
        try await renderer.load(.pocket, directory: missing)
        try await renderer.load(.pocket, directory: missing, executionContext: .foreground)
        XCTAssertEqual(factories.withLock { $0 }, 1)
        do { try await renderer.load(.plus, directory: missing); XCTFail("Missing Plus assets loaded") } catch {}
        do { _ = try await renderer.render(unit); XCTFail("Failed replacement retained old engine") }
        catch NarrationRenderer.RenderError.invalidAudio {}
        try await renderer.load(.pocket, directory: missing)
        XCTAssertEqual(factories.withLock { $0 }, 2)
        let events = await engine.events
        XCTAssertEqual(events.filter { $0 == "unload" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "observer-on" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "context:Optional(0.2)" }.count, 3)
        await renderer.unload()
    }
}
