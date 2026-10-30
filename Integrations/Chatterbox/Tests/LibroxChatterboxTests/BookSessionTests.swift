import Foundation
import Synchronization
import Testing
import KokoroNarration
@testable import LibroxChatterbox
@testable import ChatterboxCoreML

private func writeTestConditioning(to file: URL) throws {
    try Conditionals(speakerEmb: Array(repeating: 0, count: 256), condPromptSpeechTokens: [1],
        genEmbedding: Array(repeating: 0, count: 192), promptTokens: [1],
        promptFeat: Array(repeating: 0, count: 80)).write(to: file)
}

@Test func bookSessionOwnsGroupingOrderedPreparationAndCacheReuse() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("book-session-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let voice = dir.appendingPathComponent("voice"); try writeTestConditioning(to: voice)
    let calls = Mutex(0), indices = Mutex<[Int]>([]), hits = Mutex<[Bool]>([])
    let narrator = ChatterboxNarrator(rendering: { _ in
        calls.withLock { $0 += 1 }
        return try .init(samples: Array(repeating: 0.1, count: 2400))
    })
    let session = try ChatterboxBookSession(narrator: narrator, cacheDirectory: dir.appendingPathComponent("pcm"),
        modelManifestSHA256: String(repeating: "a", count: 64), rendererProfile: "test")
    let source = "La niña esperó. Nadie llamó.\n\nLa noche llegó. La calle estaba vacía."
    for _ in 0..<2 {
        try await session.stream(source, language: "es", narratorID: "v", conditioningFiles: ["v": voice]) { ready in
                indices.withLock { $0.append(ready.index) }
                hits.withLock { $0.append(ready.cacheHit) }
                let context = try #require(ready.unit.request.sourceContext)
                #expect((source as NSString).substring(with: context.range) == ready.unit.request.text)
                #expect(!ready.samples.isEmpty && ready.samples.allSatisfy(\.isFinite))
            }
    }
    #expect(calls.withLock { $0 } == 2)
    #expect(indices.withLock { $0 } == [0, 1, 0, 1])
    #expect(hits.withLock { $0 } == [false, false, true, true])
}

@Test func bookSessionFreezesConditioningAndDeletesOnlyItsPrivateSnapshots() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("book-frozen-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let voice = dir.appendingPathComponent("voice"); try writeTestConditioning(to: voice)
    let paths = Mutex<[URL]>([])
    let narrator = ChatterboxNarrator(rendering: { request in
        let snapshot = try #require(request.conditioningFile)
        #expect(snapshot != voice)
        try ChatterboxVoiceFile.validate(at: snapshot)
        paths.withLock { $0.append(snapshot) }
        return try .init(samples: [0.1])
    })
    let session = try ChatterboxBookSession(narrator: narrator, cacheDirectory: dir.appendingPathComponent("cache"),
        modelManifestSHA256: String(repeating: "a", count: 64), rendererProfile: "test")
    try await session.stream("She waited.\n\nThe rain stopped.\n\nThe street was empty.\n\nThe sun rose.",
        language: "en", narratorID: "v", conditioningFiles: ["v": voice], preparation: .finiteExcerpt) { ready in
            if ready.index == 0 { try Data([1]).write(to: voice, options: .atomic) }
        }
    #expect(paths.withLock { $0.count } == 4)
    #expect(paths.withLock { $0.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } })
    #expect(try Data(contentsOf: voice) == Data([1]))
}

@Test func bookSessionRequiresPlaybackAcknowledgementAndCancellationReleasesWait() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("book-permit-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let voice = dir.appendingPathComponent("voice"); try writeTestConditioning(to: voice)
    let received = Mutex<[ChatterboxPreparedPassage]>([]), calls = Mutex(0)
    let narrator = ChatterboxNarrator(rendering: { _ in
        calls.withLock { $0 += 1 }; return try .init(samples: [0.1])
    })
    let session = try ChatterboxBookSession(narrator: narrator, cacheDirectory: dir.appendingPathComponent("cache"),
        modelManifestSHA256: String(repeating: "a", count: 64), rendererProfile: "test")
    let task = Task {
        try await session.stream("She waited.\n\nThe rain stopped.\n\nThe street was empty.\n\nThe sun rose.\n\nThe day began.",
            language: "en", narratorID: "v", conditioningFiles: ["v": voice]) { ready in
                received.withLock { $0.append(ready) }
            }
    }
    while received.withLock({ $0.count }) < 3 { await Task.yield() }
    #expect(calls.withLock { $0 } == 3)
    let first = received.withLock { $0[0] }
    #expect(await session.didFinishPlaying(index: 0, generationID: UUID()) == false)
    #expect(await session.didFinishPlaying(index: 1, generationID: first.generationID) == false)
    #expect(await session.didFinishPlaying(index: 0, generationID: first.generationID))
    while received.withLock({ $0.count }) < 4 { await Task.yield() }
    #expect(calls.withLock { $0 } == 4)
    task.cancel()
    do { try await task.value; Issue.record("Expected cancellation") }
    catch is CancellationError {} catch { Issue.record("\(error)") }
    try await session.stream("A fresh book.", language: "en", narratorID: "v", conditioningFiles: ["v": voice]) { _ in }
}

@Test func nativeBatchAdapterPrefersLibraryBatchSource() async throws {
    let single = Mutex(0), batch = Mutex(0)
    let narrator = ChatterboxNarrator(rendering: { _ in
        single.withLock { $0 += 1 }; return try .init(samples: [0.1])
    }, batchRendering: { requests, receive in
        batch.withLock { $0 += 1 }
        for (index, request) in requests.enumerated() {
            try await receive(.init(requestIndex: index, chunkIndex: 0, isFinalChunk: true,
                request: request, audio: .init(samples: [0.1])))
        }
    })
    let request = try ChatterboxRequest(text: "Hello.", language: "en")
    try await narrator.streamBatch([request, request]) { _ in }
    try await narrator.stream(request) { _ in }
    #expect(batch.withLock { $0 } == 1)
    #expect(single.withLock { $0 } == 1)
}

@Test func bookSessionCarriesReviewedDirectionsAndDoesNotReuseWrongExpressionAudio() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("book-direction-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let voice = dir.appendingPathComponent("voice"); try writeTestConditioning(to: voice)
    let source = "Come here.", range = NSRange(location: 0, length: source.utf16.count)
    let calls = Mutex<[Float]>([]), hits = Mutex<[Bool]>([])
    let narrator = ChatterboxNarrator(rendering: { request in
        calls.withLock { $0.append(request.exaggeration) }
        #expect(request.text == source)
        #expect(request.sourceContext?.performance.evidence.source == .explicitOverride)
        return try .init(samples: [request.exaggeration * 0.1])
    })
    let session = try ChatterboxBookSession(narrator: narrator, cacheDirectory: dir.appendingPathComponent("pcm"),
        modelManifestSHA256: String(repeating: "a", count: 64), rendererProfile: "test")
    for delivery: NarrationVocalDelivery in [.soft, .shout, .shout] {
        let sidecar = try ChatterboxPerformanceDirections(source: source, annotations: [.init(range: range,
            originalText: source, performance: .init(delivery: delivery, strength: .strong))])
        try await session.stream(source, language: "en", narratorID: "v", conditioningFiles: ["v": voice],
            performanceDirections: sidecar, preparation: .finiteExcerpt) { passage in
                hits.withLock { $0.append(passage.cacheHit) }
                #expect(passage.unit.performance.delivery == delivery)
            }
    }
    #expect(calls.withLock { $0.count } == 2)
    #expect(calls.withLock { $0[0] < $0[1] })
    #expect(hits.withLock { $0 } == [false, false, true])
}
