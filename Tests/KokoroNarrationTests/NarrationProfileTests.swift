import Foundation
import Testing
import KokoroCatalog
import KokoroPronunciation
@testable import KokoroNarration

private struct ShortFixture: Decodable {
    let language: PronunciationLanguage
    let voice: String
    let text: String
}

@Test(arguments: PronunciationLanguage.allCases)
func runtimePreservesLanguageDiagnosticsAndBounds(language: PronunciationLanguage) async throws {
    let url = try #require(Bundle.module.url(forResource: "MultilingualShortUtterances", withExtension: "json"))
    let cases = try JSONDecoder().decode([ShortFixture].self, from: Data(contentsOf: url))
    let fixture = try #require(cases.first { $0.language == language })
    let cast = try BookVoiceCast(bookID: "short-utterances", language: language, narratorVoiceID: fixture.voice, voicePool: [])
    let planner = BookNarrationPlanner()
    for profile in NarrationProfile.allCases {
        // This release retains main's pronunciation resources. Profiles must
        // preserve their diagnostics, including existing French limitations.
        let baseline = try await planner.plan(fixture.text, chapterID: "1", cast: cast,
            targetPhonemes: profile.targetPhonemes, prosody: profile.prosody)
        let plan = try await planner.plan(fixture.text, chapterID: "1", cast: cast, profile: profile)
        #expect(plan.units.flatMap(\.pronunciationDiagnostics).map(\.code)
            == baseline.units.flatMap(\.pronunciationDiagnostics).map(\.code))
        #expect(plan.units.map(\.text).joined() == fixture.text)
        #expect(plan.cast.narratorVoiceID == cast.narratorVoiceID)
        #expect(plan.cast.characterVoices.isEmpty)
        for unit in plan.units {
            #expect((fixture.text as NSString).substring(with: unit.range) == unit.text)
            #expect(!unit.requiresRendererSplit)
            #expect(unit.voiceID == fixture.voice)
            if ![.english, .spanish].contains(language) { #expect(profile.focus(for: unit).isEmpty) }
        }
    }
}

@Test func integratedContextRetainsAcceptedBrutoAndBasicCompatibility() async throws {
    let text = "Esquina de las Descalzas. Dos embozados, que entran en escena por opuesto lado, tropiezan uno con otro. Es de noche.\n\nEmbozado primero.—¡Bruto!\n\nEmbozado segundo.—El bruto será él.\n"
    let cast = try BookVoiceCast(bookID: "bruto", language: .spanish, narratorVoiceID: "ef_dora", voicePool: [])
    let planner = BookNarrationPlanner()
    let old = try await planner.plan(text, chapterID: "1", cast: cast, targetPhonemes: 320)
    let basic = try await planner.plan(text, chapterID: "1", cast: cast, profile: .basic)
    #expect(old.units.map(\.phonemes) == basic.units.map(\.phonemes))
    #expect(old.units.map(\.text) == basic.units.map(\.text))
    #expect(basic.units.allSatisfy { NarrationProfile.basic.styleRow(for: $0) == 158 && NarrationProfile.basic.focus(for: $0).isEmpty })
    let enhanced = try await planner.plan(text, chapterID: "1", cast: cast, profile: .enhanced)
    #expect(enhanced.units.map(\.text).joined() == text)
    let word = try #require(enhanced.units.first { $0.text.contains("¡Bruto!") })
    #expect(word.text.contains("Esquina") && word.text.contains("Embozado primero"))
    #expect(word.phonemes.contains("bɾˈuto"))
    #expect(NarrationProfile.enhanced.focus(for: word).isEmpty)
    #expect(enhanced.units.contains { $0.text == "El bruto será él.\n" })
}

@Test func contextNeverMergesDifferentCharactersEvenWhenTheyShareAVoice() {
    var a = BookNarrationUnit(text: "¡No!", range: .init(location: 0, length: 4), voiceID: "ef_dora", phonemes: "nˈo!", boundaryAfter: .sentence)
    var b = BookNarrationUnit(text: "¡Sí!", range: .init(location: 4, length: 4), voiceID: "ef_dora", phonemes: "sˈi!", boundaryAfter: .sentence)
    a.role = .dialogue; b.role = .dialogue; a.speakerID = "ana"; b.speakerID = "luis"
    #expect(BoundedNarrationContext.prepare([a,b]).count == 2)
    b.speakerID = "ana"
    #expect(BoundedNarrationContext.prepare([a,b]).count == 1)
    a.speakerID = nil; b.speakerID = nil
    #expect(BoundedNarrationContext.prepare([a,b]).count == 2)
}

@Test func runtimeCacheDistinguishesQualityAndResolvedQuestionFocus() {
    var unit = BookNarrationUnit(text: "¿Vienes?", range: .init(location: 0, length: 8), voiceID: "ef_dora", phonemes: "bjˈenes?", boundaryAfter: .sentence)
    let narrative = NarrationProfile.enhanced.renderIdentity(for: unit)
    unit.role = .dialogue
    #expect(narrative != NarrationProfile.enhanced.renderIdentity(for: unit))
    #expect(NarrationProfile.enhanced.renderIdentity(for: unit) != NarrationProfile.basic.renderIdentity(for: unit))
    #expect(NarrationProfile.enhanced.speed(for: unit) == 1)
}

@Test func runtimeCadenceRetainsChapterBreathingRoomAndResetsForSeek() {
    let unit = BookNarrationUnit(text: "Llegó.", range: .init(location: 0, length: 6), voiceID: "ef_dora", phonemes: "ʝeɣˈo.", boundaryAfter: .sentence)
    let original = [Float](repeating: 0.1, count: 2_400)
    var cadence = NarrationPlaybackCadence(profile: .enhanced)
    var first = original; #expect(cadence.apply(to: &first, unit: unit) == 0)
    var next = original; let pause = cadence.apply(to: &next, unit: unit, chapterBreak: true)
    #expect(pause == 24_000 && Array(next.suffix(original.count)) == original)
    cadence = NarrationPlaybackCadence(profile: .enhanced)
    var sought = original; #expect(cadence.apply(to: &sought, unit: unit) == 0)
}
