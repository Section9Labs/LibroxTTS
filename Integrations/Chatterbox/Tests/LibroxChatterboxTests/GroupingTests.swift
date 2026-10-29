import Foundation
import Testing
@testable import LibroxChatterbox

@Test func groupingPreservesExactUnicodeSourceAndParagraphs() throws {
    for (language, text) in [("en", "The rain stopped. She waited by the door. Nobody came.\n\nThe lamps went out."),
                             ("es", "La niña esperó. La mañana estaba tranquila. Nadie llamó.\n\nEl café se enfrió.")] {
        let voice = URL(fileURLWithPath: "/test/voice.safetensors")
        let baseline = try ChatterboxBookDirector.plan(text, language: language, narratorID: "v", conditioningFiles: ["v": voice])
        let grouped = try ChatterboxBookDirector.plan(text, language: language, narratorID: "v",
            conditioningFiles: ["v": voice], grouping: .compatibleNarration())
        #expect(grouped.count < baseline.count)
        #expect(grouped.count == 2)
        #expect(grouped.first!.sourceFragments.count == 3)
        for unit in grouped {
            let context = try #require(unit.request.sourceContext)
            #expect((text as NSString).substring(with: context.range) == unit.request.text)
            #expect(!unit.request.text.contains("\n"))
            #expect(unit.request.conditioningFile == voice)
            for fragment in unit.sourceFragments {
                #expect(NSIntersectionRange(fragment, context.range) == fragment)
            }
        }
        let covered = baseline.map { $0.request.text }.joined(separator: " ")
        #expect(grouped.map { $0.request.text }.joined(separator: " ") == covered)
    }
}

@Test func groupingNeverAbsorbsQuotedSpeechOrItsDelivery() throws {
    let text = "Clara esperó. La calle estaba vacía. \"¡Aléjate!\", gritó Daniel. \"Ven aquí\", susurró Clara."
    let voice = URL(fileURLWithPath: "/test/voice.safetensors")
    let baseline = try ChatterboxBookDirector.plan(text, language: "es", narratorID: "v", conditioningFiles: ["v": voice])
    let grouped = try ChatterboxBookDirector.plan(text, language: "es", narratorID: "v",
        conditioningFiles: ["v": voice], grouping: .compatibleNarration())
    let a = baseline.filter { $0.timingContext.nextRole == .dialogue }
    let b = grouped.filter { $0.timingContext.nextRole == .dialogue }
    #expect(a.map(\.request.text) == b.map(\.request.text))
    #expect(a.map(\.request.exaggeration) == b.map(\.request.exaggeration))
    #expect(a.map(\.performance) == b.map(\.performance))
}

@Test func groupingKeepsBoundedRequestsAndRejectsInvalidBudgets() throws {
    let text = String(repeating: "The quiet street was empty. ", count: 30)
    let voice = URL(fileURLWithPath: "/test/voice.safetensors")
    let units = try ChatterboxBookDirector.plan(text, language: "en", narratorID: "v",
        conditioningFiles: ["v": voice], grouping: .compatibleNarration(maxCharacters: 100))
    #expect(units.allSatisfy { $0.request.text.count <= 100 })
    #expect(units.count > 1)
    #expect(ChatterboxBookDirector.Grouping.sentences.cacheRevision !=
            ChatterboxBookDirector.Grouping.compatibleNarration().cacheRevision)
    #expect(throws: ChatterboxBookDirector.PlanningError.self) {
        try ChatterboxBookDirector.plan(text, language: "en", narratorID: "v",
            conditioningFiles: ["v": voice], grouping: .compatibleNarration(maxCharacters: 301))
    }
}
