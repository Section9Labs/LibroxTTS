import Foundation
import Testing
@testable import LibroxCTNative

private func poolBinding(_ text: String, spoken: String, language: String) throws -> CTTextContext.Binding {
    try CTTextContext.bind(contextText: text, spokenRange: (text as NSString).range(of: spoken),
        spokenText: spoken, language: language, modelFingerprint: "fixture", styleID: "F1")
}

@Test func quotePoolExcludesOnlyBoundSpokenTokensAndWrappers() throws {
    for (language, before, spoken, after) in [
        ("en", "The footsteps stopped. ", "\"Come with me,\"", " said Mara."),
        ("es", "Los pasos se detuvieron. ", "\"Ven conmigo,\"", " dijo María.")
    ] {
        let binding = try poolBinding(before + spoken + after, spoken: spoken, language: language)
        let input = try CTQuotePoolInputs(binding: binding)
        let values = try input.tensor.floats()
        #expect(input.excludedCount == binding.gatherIndices.count)
        #expect(!input.usedFallback)
        #expect(input.lexicalOutsideCount > 0)
        #expect(input.tensor.shape == [1, binding.normalizedContext.unicodeScalars.count, 1])
        #expect(values.enumerated().allSatisfy { binding.gatherIndices.contains($0.offset) ? $0.element == 0 : $0.element == 1 })
        #expect(try CTQuotePoolInputs(binding: binding, allOnesControl: true).tensor.floats().allSatisfy { $0 == 1 })
    }
}

@Test func quotePoolFallsBackForIdentityAndPunctuationOnlyOutside() throws {
    for text in ["\"Come back.\"", "... \"Come back.\" ..."] {
        let binding = try poolBinding(text, spoken: "\"Come back.\"", language: "en")
        let input = try CTQuotePoolInputs(binding: binding)
        #expect(input.usedFallback)
        #expect(input.lexicalOutsideCount == 0)
        #expect(input.excludedCount == 0)
        #expect(try input.tensor.floats().allSatisfy { $0 == 1 })
    }
}

@Test func quotePoolRejectsTamperedGatherPositions() throws {
    let binding = try poolBinding("She waited. \"Come back.\"", spoken: "\"Come back.\"", language: "en")
    let data = try JSONEncoder().encode(binding)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["gatherIndices"] = [Int](repeating: 0, count: binding.gatherIndices.count)
    let altered = try JSONDecoder().decode(CTTextContext.Binding.self,
        from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: CTError.self) { try CTQuotePoolInputs(binding: altered) }
}
