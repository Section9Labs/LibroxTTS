import Foundation
import Testing
@testable import LibroxChatterbox

@Test func directorPreservesSourceAndExternalVoiceIdentityAndUsesDeliveryCues() throws {
    let text = "Clara esperó.\n\n\"Ven aquí\", susurró Clara. \"¡Aléjate!\", gritó Daniel."
    let id = UUID().uuidString
    let voice = URL(fileURLWithPath: "/saved/conditioning.safetensors")
    let units = try ChatterboxBookDirector.plan(text, language: "es", narratorID: id, conditioningFiles: [id: voice], seed: 42)
    #expect(units.count >= 3)
    for unit in units {
        let context = try #require(unit.request.sourceContext)
        #expect(context.voiceID == id)
        #expect((text as NSString).substring(with: context.range) == unit.request.text)
        #expect(unit.request.conditioningFile == voice)
    }
    #expect(units.contains { $0.performance.delivery == .whisper })
    #expect(units.contains { $0.performance.delivery == .shout })
    #expect(units.first { $0.performance.delivery == .whisper }!.request.exaggeration
            < units.first { $0.performance.delivery == .shout }!.request.exaggeration)
}

private actor HeldRenderer {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func render() async throws -> ChatterboxAudioChunk {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return try .init(samples: [0.1])
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Test func directRendererCancellationKeepsBusyLeaseUntilRendererReturns() async throws {
    let held = HeldRenderer()
    let narrator = ChatterboxNarrator(rendering: { _ in try await held.render() })
    let task = Task { try await narrator.stream(ChatterboxRequest(text: "Hello", language: "en")) { _ in } }
    while !(await held.started) { await Task.yield() }
    task.cancel()
    await #expect(throws: ChatterboxNarrationError.busy) { try await narrator.unload() }
    await held.release()
    do { try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("\(error)") }
    try await narrator.unload()
}
