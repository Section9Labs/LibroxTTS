import Foundation
import Testing
import LibroxTTS

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []
    private var calls = 0
    func append(_ frame: [Float]) {
        lock.withLock { stored += frame; calls += 1 }
    }
    var samples: [Float] { lock.withLock { stored } }
    var frameCount: Int { lock.withLock { calls } }
}

@Test func pocketFrameFacadeRequiresLoadedMax() async throws {
    let renderer = NarrationRenderer(compactDirectory: URL(fileURLWithPath: "/unused"), harmonicSource: nil)
    let plan = try await NarrationPipeline().plan("The library was quiet.", model: .pocket,
        bookID: "stream", chapterID: "1", narratorVoiceID: "pocket-alba-en-v1", language: "en")
    do {
        try await renderer.renderPocketFrames(try #require(plan.units.first)) { _ in
            Issue.record("An unloaded renderer produced audio")
        }
        Issue.record("An unloaded renderer accepted Max streaming")
    } catch NarrationRenderer.RenderError.unavailable {}
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
func pocketFacadeFramesMatchWholeUnitAndRecoverAfterCancellation() async throws {
    PocketTestMetal.configure()
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_ASSETS"]!)
    let renderer = NarrationRenderer(compactDirectory: root, harmonicSource: nil)
    let plan = try await NarrationPipeline().plan("The library was quiet. She opened the book slowly.", model: .pocket,
        bookID: "stream", chapterID: "1", narratorVoiceID: "pocket-alba-en-v1", language: "en",
        pocketChunking: .carefulReading, pocketSampling: .init(temperature: 0, samplerSteps: 4))
    let unit = try #require(plan.units.first)
    try await renderer.load(.pocket, directory: root, executionContext: .background)
    let whole = try await renderer.render(unit)
    let capture = StreamCapture()
    try await renderer.renderPocketFrames(unit) { frame in capture.append(frame) }
    #expect(capture.frameCount > 1)
    #expect(capture.samples == whole)
    do {
        try await renderer.renderPocketFrames(unit) { _ in throw CancellationError() }
        Issue.record("A cancelled consumer was treated as a completed stream")
    } catch is CancellationError {}
    let recovered = try await renderer.render(unit)
    #expect(recovered == whole)
    await renderer.unload()
}
