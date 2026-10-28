import Foundation
import Testing
import KokoroNarration
@testable import ChatterboxCoreML
@testable import LibroxChatterbox

private enum BatchTestFailure: Error { case consumer, gateClosed }

/// Single waiter per signal; AsyncStream cancellation wakes a suspended test leg.
private struct Signal: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func open() { continuation.yield(()); continuation.finish() }
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        if await iterator.next() == nil {
            try Task.checkCancellation()
            throw BatchTestFailure.gateClosed
        }
        try Task.checkCancellation()
    }
}

private actor BatchRecorder {
    var values: [Int] = []
    var producerEnded = false
    var consumerEnded = false
    func record(_ value: Int) { values.append(value) }
    func endProducer() { producerEnded = true }
    func endConsumer() { consumerEnded = true }
}

@Test(.timeLimit(.minutes(1)))
func batchOverlapsLegsWithoutReordering() async throws {
    let firstSynth = Signal(), secondDecode = Signal()
    let output = BatchRecorder()
    try await BoundedBatchPipeline<Int>.run { channel in
        try await channel.send(0)
        // Cannot decode unit 1 until synth unit 0 has actually started.
        try await firstSynth.wait()
        secondDecode.open()
        try await channel.send(1)
        try await channel.send(2)
    } consume: { value in
        if value == 0 {
            firstSynth.open()
            // The two legs must run concurrently to satisfy this handshake.
            try await secondDecode.wait()
        }
        await output.record(value)
    }
    #expect(await output.values == [0, 1, 2])
}

@Test(.timeLimit(.minutes(1)))
func slowCallbackBoundsDecodedQueue() async throws {
    let firstSynth = Signal(), fourthAttempt = Signal(), release = Signal()
    let sent = BatchRecorder(), output = BatchRecorder()
    let task = Task {
        try await BoundedBatchPipeline<Int>.run(capacity: 2) { channel in
            for value in 0..<8 {
                if value == 1 { try await firstSynth.wait() }
                if value == 3 { fourthAttempt.open() }
                try await channel.send(value)
                await sent.record(value)
            }
        } consume: { value in
            if value == 0 { firstSynth.open(); try await release.wait() }
            await output.record(value)
        }
    }
    try await fourthAttempt.wait()
    // One consumer-held value + two queued; the fourth send must be suspended.
    #expect(await sent.values == [0, 1, 2])
    release.open()
    try await task.value
    #expect(await output.values == Array(0..<8))
}

@Test(.timeLimit(.minutes(1)))
func cancellationWakesFullQueueAndJoinsBothLegs() async throws {
    let firstSynth = Signal(), blockedSend = Signal(), never = Signal()
    let state = BatchRecorder()
    let task = Task {
        try await BoundedBatchPipeline<Int>.run(capacity: 1) { channel in
            do {
                try await channel.send(0)
                try await firstSynth.wait()
                try await channel.send(1)
                blockedSend.open()
                try await channel.send(2)
                await state.endProducer()
            } catch { await state.endProducer(); throw error }
        } consume: { _ in
            do { firstSynth.open(); try await never.wait(); await state.endConsumer() }
            catch { await state.endConsumer(); throw error }
        }
    }
    try await blockedSend.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await state.producerEnded)
    #expect(await state.consumerEnded)
}

@Test(.timeLimit(.minutes(1)))
func cancellationWakesEmptyQueue() async throws {
    let started = Signal(), never = Signal()
    let task = Task {
        try await BoundedBatchPipeline<Int>.run { _ in started.open(); try await never.wait() }
            consume: { _ in Issue.record("No value was produced") }
    }
    try await started.wait(); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test(.timeLimit(.minutes(1)))
func callbackFailureStopsAndJoinsProducer() async throws {
    let state = BatchRecorder()
    await #expect(throws: BatchTestFailure.self) {
        try await BoundedBatchPipeline<Int>.run(capacity: 1) { channel in
            do {
                for value in 0..<100 { try await channel.send(value) }
                await state.endProducer()
            } catch { await state.endProducer(); throw error }
        } consume: { value in
            await state.record(value)
            throw BatchTestFailure.consumer
        }
    }
    #expect(await state.values == [0])
    #expect(await state.producerEnded)
}

@Test func batchBoundsRejectBeforeProducerRuns() async throws {
    let narrator = ChatterboxNarrator(batchSource: { _, _ in Issue.record("Invalid batch reached model") })
    let one = try ChatterboxRequest(text: "Hello.", language: "en")
    await #expect(throws: ChatterboxNarrationError.invalidBatch) {
        try await narrator.streamBatch([]) { _ in }
    }
    await #expect(throws: ChatterboxNarrationError.invalidBatch) {
        try await narrator.streamBatch(Array(repeating: one, count: 9)) { _ in }
    }
    let wide = try ChatterboxRequest(text: String(repeating: "漢", count: 2000), language: "zh")
    await #expect(throws: ChatterboxNarrationError.invalidBatch) {
        try await narrator.streamBatch(Array(repeating: wide, count: 6)) { _ in }
    }
    try await narrator.unload()
}

@Test(.timeLimit(.minutes(1)))
func callbackFailureCancelsProducerOutsideChannel() async throws {
    let never = Signal(), state = BatchRecorder()
    await #expect(throws: BatchTestFailure.self) {
        try await BoundedBatchPipeline<Int>.run { channel in
            do {
                try await channel.send(0)
                try await never.wait()
            } catch { await state.endProducer(); throw error }
        } consume: { _ in throw BatchTestFailure.consumer }
    }
    #expect(await state.producerEnded)
}

@Test func batchPreservesRequestIdentityAndOwnsBusyLease() async throws {
    let source = ChatterboxSourceContext(range: NSRange(location: 13, length: 6),
        originalText: "Hello!", voiceID: "cast-a", speakerID: "speaker-a",
        performance: NarrationPerformance.analyze(text: "Hello!", languageCode: "en"))
    let requests = [
        try ChatterboxRequest(text: "Hello!", language: "en", exaggeration: 0.8, seed: 7, sourceContext: source),
        try ChatterboxRequest(text: "¿Vienes?", language: "es", guidance: 0.7, seed: 9),
    ]
    let narrator = ChatterboxNarrator(batchSource: { input, receive in
        for (index, request) in input.enumerated() {
            try await receive(ChatterboxBatchChunk(requestIndex: index, chunkIndex: 0, isFinalChunk: true,
                request: request, audio: ChatterboxAudioChunk(samples: [Float(index)])))
        }
    })
    let output = BatchRecorder()
    try await narrator.streamBatch(requests) { value in
        let original = requests[value.requestIndex]
        #expect(value.request.text == original.text)
        #expect(value.request.language == original.language)
        #expect(value.request.exaggeration == original.exaggeration)
        #expect(value.request.guidance == original.guidance)
        #expect(value.request.seed == original.seed)
        #expect(value.request.sourceContext?.range == original.sourceContext?.range)
        #expect(value.request.sourceContext?.originalText == original.sourceContext?.originalText)
        #expect(value.request.sourceContext?.voiceID == original.sourceContext?.voiceID)
        #expect(value.request.sourceContext?.speakerID == original.sourceContext?.speakerID)
        #expect(value.request.sourceContext?.performance == original.sourceContext?.performance)
        #expect(value.isFinalChunk && value.chunkIndex == 0)
        await #expect(throws: ChatterboxNarrationError.busy) { try await narrator.unload() }
        await output.record(value.requestIndex)
    }
    #expect(await output.values == [0, 1])
    try await narrator.unload()
}
