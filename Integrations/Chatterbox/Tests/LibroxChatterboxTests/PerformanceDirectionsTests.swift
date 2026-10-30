import Foundation
import Testing
import KokoroNarration
@testable import LibroxChatterbox

private let annotationVoice = URL(fileURLWithPath: "/test/stock.safetensors")
private func directed(_ text: String, language: String = "en", directions: ChatterboxPerformanceDirections? = nil,
                      grouping: ChatterboxBookDirector.Grouping = .sentences,
                      mode: ChatterboxBookDirector.Direction = .storyteller) throws -> [ChatterboxDirectedUnit] {
    try ChatterboxBookDirector.plan(text, language: language, narratorID: "stock", conditioningFiles: ["stock": annotationVoice],
        direction: mode, grouping: grouping, performanceDirections: directions, seed: 42)
}
private func sidecar(_ source: String, range: NSRange, delivery: NarrationVocalDelivery,
                     strength: NarrationPerformanceStrength = .moderate) throws -> ChatterboxPerformanceDirections {
    let text = (source as NSString).substring(with: range)
    return try .init(source: source, annotations: [.init(range: range, originalText: text,
        performance: .init(delivery: delivery, strength: strength))])
}

@Test func reviewedDirectionPreservesSpokenSourceVoiceAndUnmappedMeaning() throws {
    for (language, source) in [("en", "The door was open. Come here."), ("es", "La puerta estaba abierta. Ven aquí.")] {
        let baseline = try directed(source, language: language)
        let selected = try #require(baseline.last?.request.sourceContext?.range)
        let directions = try sidecar(source, range: selected, delivery: .whisper)
        let units = try directed(source, language: language, directions: directions)
        #expect(units.map(\.request.text) == baseline.map(\.request.text))
        #expect(units.first!.request.exaggeration == baseline.first!.request.exaggeration)
        let last = try #require(units.last), context = try #require(last.request.sourceContext)
        #expect(context.range == selected && context.voiceID == "stock")
        #expect(context.originalText == (source as NSString).substring(with: selected))
        #expect(last.request.conditioningFile == annotationVoice)
        #expect(last.request.maxTokens == baseline.last!.request.maxTokens)
        #expect(last.request.seed == 42)
        #expect(last.performance.evidence.source == .explicitOverride)
        #expect(last.performance.chatterboxSuggestion.unmappedDelivery == .whisper)
        #expect(last.request.exaggeration == last.performance.chatterboxSuggestion.exaggeration)
        #expect(last.request.guidance == last.performance.chatterboxSuggestion.cfgWeight)
        #expect(!last.request.text.contains("[whisper]"))
    }
}

@Test func directionsRespectStrengthAndTakePrecedenceOverAutomaticNeutral() throws {
    let source = "Come here.", range = NSRange(location: 0, length: source.utf16.count)
    let subtle = try sidecar(source, range: range, delivery: .shout, strength: .subtle)
    let strong = try sidecar(source, range: range, delivery: .shout, strength: .strong)
    let a = try #require(directed(source, directions: subtle, mode: .neutral).first)
    let b = try #require(directed(source, directions: strong, mode: .neutral).first)
    #expect(a.request.exaggeration < b.request.exaggeration)
    #expect(a.performance.chatterboxSuggestion.unmappedDelivery == .shout)
    #expect(subtle.expressionSHA256 != strong.expressionSHA256)
    let hash = String(repeating: "a", count: 64)
    #expect(try a.request.cacheKey(modelManifestSHA256: hash, conditioningSHA256: hash)
        != b.request.cacheKey(modelManifestSHA256: hash, conditioningSHA256: hash))
}

@Test func directionsRejectStaleTextCanonicalChangesSurrogatesAndOverlap() throws {
    let source = "🙂 e\u{301}. Wait.", range = NSRange(location: 0, length: source.utf16.count)
    let directions = try sidecar(source, range: range, delivery: .soft)
    #expect(throws: ChatterboxPerformanceDirections.Failure.sourceMismatch) {
        try directed("🙂 é. Wait.", directions: directions)
    }
    #expect(throws: ChatterboxPerformanceDirections.Failure.invalidRange) {
        try ChatterboxPerformanceDirections(source: source, annotations: [.init(range: .init(location: 1, length: 1),
            originalText: "x", performance: .init(delivery: .soft))])
    }
    let a = try ChatterboxPerformanceAnnotation(range: range, originalText: source, performance: .init(delivery: .soft))
    #expect(throws: ChatterboxPerformanceDirections.Failure.overlappingRanges) {
        try ChatterboxPerformanceDirections(source: source, annotations: [a, a])
    }
    #expect(throws: ChatterboxPerformanceDirections.Failure.sourceMismatch) {
        try ChatterboxPerformanceDirections(source: source, annotations: [.init(range: .init(location: 3, length: 3),
            originalText: "abc", performance: .init(delivery: .soft))])
    }
}

@Test func partialUnitDirectionsFailAndGroupingDoesNotEraseReviewBoundaries() throws {
    let source = "The rain stopped. She waited. Nobody came."
    let baseline = try directed(source), first = try #require(baseline.first?.request.sourceContext?.range)
    let partial = try sidecar(source, range: .init(location: first.location, length: 3), delivery: .urgent)
    #expect(throws: ChatterboxPerformanceDirections.Failure.partialUnit) { try directed(source, directions: partial) }
    let reviewed = try sidecar(source, range: first, delivery: .urgent)
    let units = try directed(source, directions: reviewed, grouping: .compatibleNarration())
    #expect(units.count == 2)
    #expect(units.first?.sourceFragments == [first])
    #expect(units.first?.performance.evidence.source == .explicitOverride)
    #expect(units.last?.performance.evidence.source != .explicitOverride)
    let none = try ChatterboxPerformanceDirections(source: source, annotations: [])
    let unchanged = try directed(source, directions: none)
    #expect(unchanged.map(\.request.text) == baseline.map(\.request.text))
    #expect(unchanged.map(\.request.exaggeration) == baseline.map(\.request.exaggeration))
    #expect(unchanged.map(\.request.guidance) == baseline.map(\.request.guidance))
}

@Test func annotationDigestIsCanonicalAndCoversWholeSpokenUnits() throws {
    let source = "Hello. Goodbye.", baseline = try directed(source)
    let a = try #require(baseline.first?.request.sourceContext?.range), b = try #require(baseline.last?.request.sourceContext?.range)
    let annotations = try [a, b].map { range in
        try ChatterboxPerformanceAnnotation(range: range, originalText: (source as NSString).substring(with: range),
                                            performance: .init(delivery: .firm))
    }
    let x = try ChatterboxPerformanceDirections(source: source, annotations: annotations)
    let y = try ChatterboxPerformanceDirections(source: source, annotations: annotations.reversed())
    #expect(x.expressionSHA256 == y.expressionSHA256)
    let all = try sidecar(source, range: .init(location: 0, length: source.utf16.count), delivery: .tender)
    let both = try directed(source, directions: all)
    #expect(both.count == 2 && both.allSatisfy { $0.performance.delivery == .tender })
}

@Test func actualExpressiveControlsReachDirectorAtFullExistingBounds() throws {
    let text = "Look! The ship is coming.", range = NSRange(location: 0, length: text.utf16.count)
    let directions = try ChatterboxPerformanceDirections(source: text, annotations: [.init(range: range, originalText: text,
        controls: .init(exaggeration: 2, guidance: 0.3, temperature: 0.9))])
    let units = try directed(text, directions: directions)
    #expect(units.allSatisfy { $0.request.exaggeration == 2 && $0.request.guidance == 0.3 && $0.request.temperature == 0.9 })
    let baseline = try directed(text)
    #expect(units.map(\.request.text) == baseline.map(\.request.text))
    for value in [Float.nan, Float.infinity, -Float.infinity, -0.1, 2.01] {
        #expect(throws: ChatterboxNarrationError.invalidOptions) { try ChatterboxExpressiveControls(exaggeration: value, guidance: 0.3) }
        #expect(throws: ChatterboxNarrationError.invalidOptions) { try ChatterboxExpressiveControls(exaggeration: 1, guidance: value) }
    }
    #expect(throws: ChatterboxNarrationError.invalidOptions) { try ChatterboxExpressiveControls(exaggeration: 1, guidance: 0.3, temperature: 0) }
}
