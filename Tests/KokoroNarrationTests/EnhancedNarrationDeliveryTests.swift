// SPDX-License-Identifier: Apache-2.0 OR MIT
import Testing
import Foundation
@testable import KokoroNarration
import KokoroPronunciation

@Test func enhancedConditioningKeepsPackKeyConvention() {
    #expect(NarrationStylePolicy.length.row(phonemeCount: 51) == 51)
    #expect(NarrationStylePolicy.fixed.row(phonemeCount: 51) == 158)
    #expect(NarrationStylePolicy.boundedLength.row(phonemeCount: 400) == 240)
}

@Test func shortSpanishConditioningKeepsBrutoConnectedAndLeavesEnglishAlone() {
    func make(_ voice: String = "ef_dora", _ phones: String = "bɾˈuto! ") -> BookNarrationUnit {
        var unit = BookNarrationUnit(text: "¡Bruto!", range: .init(location: 12, length: 7),
            voiceID: voice, phonemes: phones, boundaryAfter: .sentence)
        unit.role = .dialogue
        return unit
    }
    var unit = make()
    #expect(EnhancedNarrationDelivery.shortSpanishStyleRow(for: unit) == 80)
    #expect(EnhancedNarrationDelivery.shortSpanishStyleRow(for: unit, reference: 158) == 158)
    #expect(unit.phonemes == "bɾˈuto! " && unit.text == "¡Bruto!" && unit.range.location == 12)
    #expect(EnhancedNarrationDelivery.focus(for: unit).isEmpty)
    #expect(EnhancedNarrationDelivery.shortSpanishStyleRow(for: make("em_santa")) == 80)
    #expect(EnhancedNarrationDelivery.shortSpanishStyleRow(for: make("af_heart")) == 8)
    unit.role = .narration
    #expect(EnhancedNarrationDelivery.shortSpanishStyleRow(for: unit) == 8)
    #expect(EnhancedNarrationDelivery.shortSpanishStyleRow(for: make("ef_dora", String(repeating: "a", count: 20))) == 20)
    #expect(EnhancedNarrationDelivery.shortSpanishStyleRow(for: make("ef_dora", "! ")) == 2)
}

@Test func localExpressionAbstainsOnNarrationAndAmbiguousQuestions() {
    var unit = BookNarrationUnit(text: "¿Vienes?", range: .init(location: 0, length: 8),
        voiceID: "ef_dora", phonemes: "bjˈenes?", boundaryAfter: .sentence)
    #expect(EnhancedNarrationDelivery.focus(for: unit).isEmpty)
    unit.role = .dialogue
    #expect(EnhancedNarrationDelivery.focus(for: unit).count == 1)
    unit = .init(text: "¿Vienes o te quedas?", range: .init(location: 0, length: 19),
        voiceID: "ef_dora", phonemes: "bjˈenes o te kˈeðas?", boundaryAfter: .sentence)
    unit.role = .dialogue
    #expect(EnhancedNarrationDelivery.focus(for: unit).isEmpty)
    unit = .init(text: "你来吗？", range: .init(location: 0, length: 4),
        voiceID: "zf_xiaobei", phonemes: "ni lai ma?", boundaryAfter: .sentence)
    unit.role = .dialogue
    #expect(EnhancedNarrationDelivery.focus(for: unit).isEmpty)
}

@Test func realSpanishQuestionsRemainOneConnectedUnitWithLocalFocus() {
    let text = "—¿Pero dónde te metes, hijo? ¿Qué es de tu vida?"
    let phones = "—peɾo ðˈonde te mˈetes, ˈixo? kˈe ˈes ðe tu βˈiða?"
    var unit = BookNarrationUnit(text: text, range: .init(location: 0, length: text.utf16.count),
        voiceID: "ef_dora", phonemes: phones, boundaryAfter: .sentence)
    unit.role = .dialogue
    let focus = EnhancedNarrationDelivery.focus(for: unit)
    #expect(focus.count == 2)
    let scalars = Array(phones.unicodeScalars)
    #expect(focus.map { String(String.UnicodeScalarView(scalars[$0.phonemeRange])) } == ["ðˈonde", "kˈe"])
    #expect(unit.text == text && unit.phonemes == phones)
}

@Test func localFocusRequiresAlignedPunctuationAndPreservesWaitAsOneWord() {
    var unit = BookNarrationUnit(text: "Wait!", range: .init(location: 0, length: 5),
        voiceID: "af_heart", phonemes: "wˈeɪt!", boundaryAfter: .sentence)
    unit.role = .dialogue
    #expect(EnhancedNarrationDelivery.focus(for: unit).first?.phonemeRange == 0..<5)
    unit = .init(text: "¿Dónde estás? ¿Vienes?", range: .init(location: 0, length: 22),
        voiceID: "ef_dora", phonemes: "dˈonde estˈas?", boundaryAfter: .sentence)
    unit.role = .dialogue
    #expect(EnhancedNarrationDelivery.focus(for: unit).isEmpty)
}

@Test func shortExclamationProminenceTargetsStressedVowelNotWholeWord() {
    func make(_ text: String, _ phones: String, _ voice: String = "ef_dora") -> BookNarrationUnit {
        var u = BookNarrationUnit(text: text, range: .init(location: 0, length: text.utf16.count),
            voiceID: voice, phonemes: phones, boundaryAfter: .sentence)
        u.role = .dialogue
        return u
    }
    let unit = make("¡Bruto!\n", "bɾˈuto! ")
    let focus = EnhancedNarrationDelivery.shortSpanishExclamationFocus(for: unit)
    #expect(focus.map(\.phonemeRange) == [3..<4, 5..<6])
    #expect(focus.map(\.semitones) == [1.3, -0.65])
    for other in [make("El bruto será él.", "el βɾˈuto seɾˈa ˈel."),
                  make("¿Bruto?", "bɾˈuto?"), make("¡Bruto!", "bruto!"),
                  make("Bruto!", "bɾˈuto!", "af_heart"), make("¡No, bruto!", "nˈo bɾˈuto!")] {
        #expect(EnhancedNarrationDelivery.shortSpanishExclamationFocus(for: other).isEmpty)
    }
    var narration = unit; narration.role = .narration
    #expect(EnhancedNarrationDelivery.shortSpanishExclamationFocus(for: narration).isEmpty)
}

@Test func shortSpanishContextPreservesSourceAndNeverCrossesDifferentVoices() {
    func fixture(_ voice: String = "ef_dora", labelVoice: String = "ef_dora") -> [BookNarrationUnit] {
        let texts = ["Era de noche.\n\n", "Embozado primero.—", "¡Bruto!\n", "El bruto será él."]
        let phones = ["eɾa ðe nˈoʧe. ", "emboθˈaðo pɾimˈeɾo—", "bɾˈuto! ", "el βɾˈuto seɾˈa ˈel."]
        var start = 0
        return zip(texts, phones).enumerated().map { i, pair in
            var u = BookNarrationUnit(text: pair.0, range: .init(location: start, length: pair.0.utf16.count),
                voiceID: i == 1 ? labelVoice : voice, phonemes: pair.1, boundaryAfter: .sentence)
            start += pair.0.utf16.count
            u.role = i == 0 ? .narration : i == 1 ? .attribution : .dialogue
            return u
        }
    }
    let original = fixture()
    let result = EnhancedNarrationDelivery.shortSpanishContextUnits(original)
    #expect(result.count == 2)
    #expect(result.map(\.text).joined() == original.map(\.text).joined())
    #expect(result.map(\.phonemes).joined() == original.map(\.phonemes).joined())
    #expect(result[1].text == original[3].text && result[1].range == original[3].range)
    #expect(result[0].range.length == original.prefix(3).reduce(0) { $0 + $1.range.length })
    #expect(EnhancedNarrationDelivery.shortSpanishContextUnits(fixture(labelVoice: "em_santa")).count == 4)
    #expect(EnhancedNarrationDelivery.shortSpanishContextUnits(fixture("af_heart", labelVoice: "af_heart")).count == 4)
}
