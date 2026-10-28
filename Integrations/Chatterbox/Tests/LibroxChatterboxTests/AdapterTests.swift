import Foundation
import Testing
@testable import LibroxChatterbox

@Test func validatesNaturalTextAndLanguage() throws {
    let request = try ChatterboxRequest(text: "¿Cómo estás?", language: "es", exaggeration: 0.7, guidance: 0.4)
    #expect(request.options.language == "es")
    #expect(request.options.exaggeration == 0.7)
    #expect(request.options.cfgWeight == 0.4)
    #expect(request.options.sentencePause == 0)
    #expect(throws: ChatterboxNarrationError.emptyText) { try ChatterboxRequest(text: " \n", language: "en") }
    #expect(throws: ChatterboxNarrationError.unsupportedLanguage("spanish")) { try ChatterboxRequest(text: "Hola", language: "spanish") }
    #expect(throws: ChatterboxNarrationError.textTooLong) { try ChatterboxRequest(text: String(repeating: "x", count: 2001), language: "en") }
    #expect(throws: ChatterboxNarrationError.invalidOptions) { try ChatterboxRequest(text: "Hello", language: "en", exaggeration: .nan) }
    #expect(throws: ChatterboxNarrationError.invalidOptions) { try ChatterboxRequest(text: "Hello", language: "en", maxTokens: 0) }
}

@Test func validatesAudioClockAndSamples() throws {
    #expect(throws: ChatterboxNarrationError.invalidSampleRate(16000)) { try ChatterboxAudioChunk(samples: [0], sampleRate: 16000) }
    #expect(throws: ChatterboxNarrationError.invalidAudio) { try ChatterboxAudioChunk(samples: [.nan]) }
    #expect(throws: ChatterboxNarrationError.invalidAudio) { try ChatterboxAudioChunk(samples: []) }
    #expect(try ChatterboxAudioChunk(samples: [0.1]).sampleRate == 24000)
}

private actor Capture {
    var samples: [Float] = []
    func append(_ chunk: ChatterboxAudioChunk) { samples += chunk.samples }
}

@Test func streamsInOrderAndReleasesLease() async throws {
    let narrator = ChatterboxNarrator { _ in
        AsyncThrowingStream { c in
            c.yield(try! ChatterboxAudioChunk(samples: [0.1, 0.2]))
            c.yield(try! ChatterboxAudioChunk(samples: [0.3])); c.finish()
        }
    }
    let capture = Capture()
    try await narrator.stream(ChatterboxRequest(text: "Hello", language: "en")) { await capture.append($0) }
    #expect(await capture.samples == [0.1, 0.2, 0.3])
    try await narrator.unload()
    await #expect(throws: ChatterboxNarrationError.notLoaded) {
        try await narrator.stream(ChatterboxRequest(text: "Hello", language: "en")) { _ in }
    }
}

@Test func preventsReentrantUnload() async throws {
    let narrator = ChatterboxNarrator { _ in AsyncThrowingStream { c in
        c.yield(try! ChatterboxAudioChunk(samples: [0.1])); c.finish()
    } }
    try await narrator.stream(ChatterboxRequest(text: "Hello", language: "en")) { _ in
        await #expect(throws: ChatterboxNarrationError.busy) { try await narrator.unload() }
    }
    try await narrator.unload()
}

@Test func cancellationTerminatesUpstream() async throws {
    let (stream, continuation) = AsyncThrowingStream<ChatterboxAudioChunk, Error>.makeStream()
    let terminated = Capture()
    continuation.onTermination = { _ in Task { await terminated.append(try! ChatterboxAudioChunk(samples: [1])) } }
    let narrator = ChatterboxNarrator { _ in stream }
    let task = Task { try await narrator.stream(ChatterboxRequest(text: "Hello", language: "en")) { _ in } }
    // Cancellation while awaiting the upstream iterator must release the actor lease.
    try await Task.sleep(for: .milliseconds(20)); task.cancel()
    do { try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("\(error)") }
    try await narrator.unload()
    for _ in 0..<100 where await terminated.samples.isEmpty { await Task.yield() }
    #expect(await terminated.samples == [1])
}
