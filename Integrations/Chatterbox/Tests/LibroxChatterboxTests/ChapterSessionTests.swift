import Foundation
import Testing
import Synchronization
import KokoroNarration
import KokoroPronunciation
@testable import LibroxChatterbox
@testable import ChatterboxCoreML

private final class ChapterSessionFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-scope-" + UUID().uuidString)
    let voice: URL
    init() throws {
        voice = root.appendingPathComponent("stock.safetensors")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Conditionals(speakerEmb: Array(repeating: 0, count: 256), condPromptSpeechTokens: [1],
            genEmbedding: Array(repeating: 0, count: 192), promptTokens: [1], promptFeat: Array(repeating: 0, count: 80)).write(to: voice)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func session(_ narrator: ChatterboxNarrator) throws -> ChatterboxBookSession {
        try .init(narrator: narrator, cacheDirectory: root.appendingPathComponent("cache"),
            modelManifestSHA256: String(repeating: "a", count: 64), rendererProfile: "fake-no-model")
    }
}
private func chapterSamples(_ text: String) -> [Float] { Array(repeating: Float(text.utf8.count % 5 + 1) * 0.1, count: 120) }
private actor ChapterContinuityCollector {
    var count = 0, cursor = 0, frames = 0
    var generationIDs: Set<UUID> = []
    var voicePaths: Set<URL> = []
    var cadence = ChatterboxConversationSession()
    func accept(_ ready: ChatterboxPreparedPassage, source: String) throws {
        #expect(ready.index == count)
        let context = try #require(ready.unit.request.sourceContext)
        let voice = try #require(ready.unit.request.conditioningFile)
        let original = source as NSString
        #expect(Data(original.substring(with: context.range).utf8) == Data(context.originalText.utf8))
        for fragment in ready.unit.sourceFragments {
            try #require(fragment.location >= cursor)
            let gap = original.substring(with: .init(location: cursor, length: fragment.location - cursor))
            let onlyWhitespace = gap.allSatisfy(\.isWhitespace)
            #expect(onlyWhitespace)
            let span = try #require(Range(fragment, in: source))
            #expect(source.indices.contains(span.lowerBound))
            cursor = NSMaxRange(fragment)
        }
        let represented = ready.unit.sourceFragments.map { original.substring(with: $0) }.joined()
            .filter { !$0.isWhitespace }
        let spoken = ready.unit.request.text.filter { !$0.isWhitespace }
        #expect(Data(represented.utf8) == Data(spoken.utf8))
        if ready.index >= 3 { #expect(!ready.unit.timingContext.previousTail.isEmpty) }
        var expected = chapterSamples(ready.unit.request.text)
        try cadence.completeUnit(&expected, context: ready.unit.timingContext)
        #expect(ready.generatedFrames == 120)
        #expect(ready.samples == expected)
        count += 1; frames += ready.samples.count
        generationIDs.insert(ready.generationID); voicePaths.insert(voice)
    }
    func finish(_ source: String, expectedCount: Int) throws {
        #expect(count == expectedCount && count > 128)
        let rest = (source as NSString).substring(from: cursor)
        let onlyWhitespace = rest.allSatisfy(\.isWhitespace)
        #expect(onlyWhitespace)
        #expect(frames > 0 && generationIDs.count == 1 && voicePaths.count == 1)
        #expect(voicePaths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

@Test func chapterPlanAndStreamKeepGlobalCoverageAndCadenceBeyondExcerptLimits() async throws {
    let f = try ChapterSessionFixture()
    let paragraph = "«¡No te rindas!», dijo Ana.\r\n\r\nLa mañana estaba tranquila, y la niña vio el agua desde la puerta. Nadie había olvidado aquella sorpresa. e\u{301} 🙂\u{fffc}\r\n\r\n"
    let source = String(repeating: paragraph, count: 260)
    #expect(source.utf8.count > 32_768 && source.utf16.count < 131_072)
    let units = try ChatterboxBookDirector.plan(source, language: "es", narratorID: "v",
        conditioningFiles: ["v": f.voice], grouping: .compatibleNarration(maxCharacters: 160), scope: .chapterV1)
    #expect(units.count > 128 && units.count <= 4096)
    let calls = Mutex(0)
    let narrator = ChatterboxNarrator(rendering: { request in
        calls.withLock { $0 += 1 }
        return try .init(samples: chapterSamples(request.text))
    })
    let collector = ChapterContinuityCollector(), session = try f.session(narrator)
    try await session.streamChapter(source, language: "es", narratorID: "v", conditioningFiles: ["v": f.voice]) {
        try await collector.accept($0, source: source)
    }
    #expect(calls.withLock { $0 } > 0 && calls.withLock { $0 } <= units.count)
    try await collector.finish(source, expectedCount: units.count)
}

@Test func chapterScopeDoesNotRelaxLegacyScalarUnitOrByteLimits() async throws {
    let f = try ChapterSessionFixture(), story = StoryNarrator()
    let long = String(repeating: "She waited.\n\n", count: 260)
    #expect(throws: ChatterboxBookDirector.PlanningError.tooManyUnits) {
        try ChatterboxBookDirector.plan(long, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice], grouping: .sentences)
    }
    #expect(try ChatterboxBookDirector.plan(long, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice], grouping: .sentences, scope: .chapterV1).count == 260)
    let quotes = String(repeating: "«Hola».\n", count: 300)
    #expect(throws: StoryNarrator.PlanningError.tooManyAnnotations) { try story.quotedCandidates(in: quotes) }
    #expect(try story.quotedChapterCandidates(in: quotes).count == 300)
    #expect(throws: PronunciationError.inputTooLong(limit: PronunciationEngine.maximumInputScalars)) {
        try story.plan(String(repeating: "a", count: 16_385), narratorVoiceID: "v")
    }
    let calls = Mutex(0), source = String(repeating: "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂. ", count: 1000)
    #expect(source.unicodeScalars.count <= 16_384 && source.utf8.count > 32_768)
    // Direct legacy planner had a scalar bound, not the session's byte bound.
    #expect(try ChatterboxBookDirector.plan(source, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice], grouping: .compatibleNarration()).isEmpty == false)
    let session = try f.session(.init(rendering: { _ in calls.withLock { $0 += 1 }; return try .init(samples: [0.1]) }))
    await #expect(throws: ChatterboxNarrationError.textTooLong) {
        try await session.stream(source, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice], preparation: .finiteExcerpt) { _ in }
    }
    #expect(calls.withLock { $0 } == 0)
}

@Test func chapterExpressionAnnotationsHaveSeparateScopeAndRetainActualControls() throws {
    let f = try ChapterSessionFixture(), sentence = "She waited.\n\n", source = String(repeating: sentence, count: 200)
    let controls = try ChatterboxExpressiveControls(exaggeration: 0.9, guidance: 0.3, temperature: 0.8)
    let annotations = try (0..<200).map { index in
        try ChatterboxPerformanceAnnotation(range: .init(location: index * sentence.utf16.count, length: 11),
            originalText: "She waited.", controls: controls)
    }
    #expect(throws: ChatterboxPerformanceDirections.Failure.invalidRange) {
        try ChatterboxPerformanceDirections(source: source, annotations: annotations)
    }
    let directions = try ChatterboxPerformanceDirections(source: source, annotations: annotations, scope: .chapterV1)
    let units = try ChatterboxBookDirector.plan(source, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice],
        grouping: .sentences, performanceDirections: directions, scope: .chapterV1)
    #expect(units.count == 200)
    #expect(units.allSatisfy { $0.request.exaggeration == 0.9 && $0.request.guidance == 0.3 && $0.request.temperature == 0.8 })
    let tiny = "She waited."
    let a = try ChatterboxPerformanceDirections(source: tiny, annotations: [])
    let b = try ChatterboxPerformanceDirections(source: tiny, annotations: [], scope: .chapterV1)
    #expect(a.expressionSHA256 != b.expressionSHA256)
    #expect(throws: ChatterboxPerformanceDirections.Failure.invalidRange) {
        try ChatterboxBookDirector.plan(tiny, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice], performanceDirections: a, scope: .chapterV1)
    }
}

@Test func chapterCacheIdentityAndUnitBudgetFailBeforeAnyPartialRendering() async throws {
    let f = try ChapterSessionFixture(), calls = Mutex(0)
    let session = try f.session(.init(rendering: { _ in calls.withLock { $0 += 1 }; return try .init(samples: [0.1]) }))
    let short = "She waited."
    try await session.stream(short, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice], grouping: .compatibleNarration(maxCharacters: 160), preparation: .finiteExcerpt) { _ in }
    try await session.streamChapter(short, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice]) { _ in }
    try await session.streamChapter(short, language: "en", narratorID: "v", conditioningFiles: ["v": f.voice]) { ready in #expect(ready.cacheHit) }
    #expect(calls.withLock { $0 } == 2)
    await #expect(throws: ChatterboxBookDirector.PlanningError.tooManyUnits) {
        try await session.streamChapter(String(repeating: "She waited.\n\n", count: 4097), language: "en", narratorID: "v",
            conditioningFiles: ["v": f.voice], grouping: .sentences) { _ in Issue.record("Rejected chapter rendered a partial unit") }
    }
    #expect(calls.withLock { $0 } == 2)
    await #expect(throws: ChatterboxNarrationError.textTooLong) {
        try await session.streamChapter(String(repeating: "a", count: 131_073), language: "en", narratorID: "v", conditioningFiles: ["v": f.voice]) { _ in }
    }
}

@Test func chapterQuoteRoleAndAttributionSurviveOldWindowBoundary() throws {
    let f = try ChapterSessionFixture()
    let source = "«" + String(repeating: "We must keep going. ", count: 1800) + "» she said.\n\nThe end."
    let quoteEnd = NSMaxRange((source as NSString).range(of: "»"))
    #expect(quoteEnd > 32_768)
    let units = try ChatterboxBookDirector.plan(source, language: "en", narratorID: "v",
        conditioningFiles: ["v": f.voice], grouping: .sentences, scope: .chapterV1)
    let later = units.filter { ($0.request.sourceContext?.range.location ?? 0) > 32_768 &&
        ($0.request.sourceContext?.range.location ?? Int.max) < quoteEnd }
    #expect(!later.isEmpty)
    #expect(later.allSatisfy { $0.timingContext.nextRole == .dialogue })
    let after = units.filter { ($0.request.sourceContext?.range.location ?? 0) >= quoteEnd }
    #expect(!after.isEmpty)
    #expect(after.allSatisfy { $0.timingContext.nextRole == .narration })
}

private actor ChapterStartGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !opened { await withCheckedContinuation { waiter = $0 } } }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}
@Test func cancelledChapterAdmissionDoesNotRenderAndSessionCanBeReused() async throws {
    let f = try ChapterSessionFixture(), calls = Mutex(0), gate = ChapterStartGate()
    let session = try f.session(.init(rendering: { _ in calls.withLock { $0 += 1 }; return try .init(samples: [0.1]) }))
    let child = Task {
        await gate.wait()
        try await session.streamChapter("She waited.", language: "en", narratorID: "v", conditioningFiles: ["v": f.voice]) { _ in }
    }
    child.cancel(); await gate.open()
    await #expect(throws: CancellationError.self) { try await child.value }
    #expect(calls.withLock { $0 } == 0)
    try await session.streamChapter("She waited.", language: "en", narratorID: "v", conditioningFiles: ["v": f.voice]) { _ in }
    #expect(calls.withLock { $0 } == 1)
}
