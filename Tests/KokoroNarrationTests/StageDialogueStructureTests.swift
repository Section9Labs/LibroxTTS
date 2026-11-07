// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import Testing
@testable import KokoroNarration

struct StageDialogueStructureTests {
    private func whole(_ text: String, speaker: String? = "felipe") -> StageDialogueRange {
        .init(range: NSRange(location: 0, length: (text as NSString).length), speakerID: speaker)
    }
    private func coverage(_ text: String, _ result: StageDialogueResult) {
        #expect(result.spans.map(\.text).joined() == text)
        var cursor = 0
        for span in result.spans {
            #expect(span.range.location == cursor)
            #expect(span.range.length == span.text.utf16.count)
            #expect(Range(span.range, in: text) != nil)
            #expect((text as NSString).substring(with: span.range) == span.text)
            cursor = NSMaxRange(span.range)
        }
        #expect(cursor == text.utf16.count)
    }

    @Test func splitsDirectionPreservingKnownSpeaker() {
        let text = "—Lo que tiene... (Expresando con voz y gesto la inmensidad.) no se acierta a contar."
        let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [whole(text)])
        #expect(r.accepted)
        #expect(r.spans.map(\.role) == [.dialogue, .stageDirection, .dialogue])
        #expect(r.spans.map(\.speakerID) == ["felipe", nil, "felipe"])
        #expect(r.spans[1].associatedSpeakerID == "felipe")
        coverage(text, r)
    }

    @Test func parsesTheatricalLabelsAutomatically() {
        let text = "IDO DEL SAGRARIO.—(Con solemnidad.) Tan deseosos estamos.\n\nARISTO.—(Quitándose la capa.) Como usted quiera."
        let r = StageDialogueStructure.parse(text, languageCode: "es-ES")
        #expect(r.spans.filter { $0.role == .speakerLabel }.count == 2)
        #expect(r.spans.filter { $0.role == .stageDirection }.count == 2)
        #expect(r.spans.contains { $0.role == .dialogue && $0.text.contains("Tan deseosos") && $0.speakerID == "stage-label:ido del sagrario" })
        #expect(r.spans.contains { $0.role == .dialogue && $0.text.contains("Como usted") && $0.speakerID == "stage-label:aristo" })
        coverage(text, r)
    }

    @Test func resolvesRegisteredColonAndDashLabels() {
        let text = "Elena: (Con alegría.) Ya estás aquí.\n\nELENA—No te vayas."
        let r = StageDialogueStructure.parse(text, languageCode: "es", knownSpeakerLabels: ["Elena": "cast-elena"])
        #expect(r.spans.filter { $0.role == .speakerLabel }.count == 2)
        #expect(r.spans.filter { $0.role == .dialogue }.allSatisfy { $0.speakerID == "cast-elena" })
        coverage(text, r)
    }

    @Test func doesNotTreatOrdinaryHeadingsAsCharacters() {
        let text = "NOTA: Lea con cuidado.\n\nElena: este es el nombre escrito en la puerta.\n\nCAPÍTULO.—La llegada."
        let r = StageDialogueStructure.parse(text, languageCode: "es")
        #expect(r.spans.allSatisfy { $0.role == .narration })
        coverage(text, r)
    }

    @Test func ordinaryNarrativeParenthesesStayNarration() {
        let text = "La niña (Con orgullo.) miraba la casa."
        let r = StageDialogueStructure.parse(text, languageCode: "es")
        #expect(r.spans.allSatisfy { $0.role == .narration })
        coverage(text, r)
    }

    @Test func ordinarySpokenAsidesAreNotStageDirections() {
        let text = "—La casa (la vieja casa) estaba vacía. La cena (Con pan.) era sencilla."
        let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [whole(text)])
        #expect(r.spans.map(\.role) == [.dialogue])
        coverage(text, r)
    }

    @Test func doesNotAlternateUnknownDashesOrCarryLabelAcrossParagraph() {
        let text = "IDO.—Hola.\n\n—¿Quién eres?\n\n—No lo sé."
        let ns = text as NSString
        let second = ns.range(of: "—¿Quién eres?")
        let third = ns.range(of: "—No lo sé.")
        let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [.init(range: second), .init(range: third)])
        #expect(r.spans.filter { $0.text.contains("¿Quién") || $0.text.contains("No lo sé") }.allSatisfy { $0.speakerID == nil })
        coverage(text, r)
    }

    @Test func nestedDirectionsKeepSourceAndSurrogates() {
        let text = "🙂 —Sí. (Con alegría (y mirando a José).) ¡Sí!"
        let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [whole(text)])
        #expect(r.spans.filter { $0.role == .stageDirection }.count == 1)
        coverage(text, r)
    }

    @Test func malformedAndOversizedParenthesesRemainDialogue() {
        for text in ["—Sí. (Con orgullo.", "—Sí. (Con orgullo " + String(repeating: "x", count: 1_024) + ")"] {
            let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [whole(text)])
            #expect(r.spans.allSatisfy { $0.role == .dialogue })
            coverage(text, r)
        }
    }

    @Test func invalidSeedFailsClosedWithoutDroppingText() {
        let text = "🙂 Hola."
        for range in [NSRange(location: 1, length: 1), NSRange(location: -1, length: 1), NSRange(location: 0, length: Int.max), NSRange(location: 50, length: 1)] {
            let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [.init(range: range)])
            #expect(r.status == .invalidDialogueRanges)
            coverage(text, r)
        }
        let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [whole(text), whole(text)])
        #expect(r.status == .invalidDialogueRanges)
        coverage(text, r)
    }

    @Test func refusesOversizedInputAndLeavesEnglishUntouched() {
        let text = "ELENA.—(Con alegría.) Hola."
        let en = StageDialogueStructure.parse(text, languageCode: "xx", establishedDialogue: [whole(text)])
        #expect(en.status == .unsupportedLanguage)
        coverage(text, en)
        let huge = String(repeating: "a", count: StageDialogueStructure.maximumUTF16Length + 1)
        let r = StageDialogueStructure.parse(huge, languageCode: "es")
        #expect(r.status == .inputLimit)
        coverage(huge, r)
    }

    @Test func aliasesDoNotInventGenderOrChangeVoice() {
        let text = "ARISTO.—(Con orgullo.) ¡Capitalista!"
        let r = StageDialogueStructure.parse(text, languageCode: "es", knownSpeakerLabels: ["Aristo": "existing-felipe"])
        #expect(r.spans.filter { $0.role == .dialogue }.allSatisfy { $0.speakerID == "existing-felipe" })
        #expect(r.spans.filter { $0.role != .dialogue }.allSatisfy { $0.speakerID == nil })
        coverage(text, r)
    }

    @Test func matchingKnownSeedsMergeBeforeDirectionSplit() {
        let text = "—Sí. (Con orgullo.) Lo hice."
        let cut = (text as NSString).range(of: "orgullo").location
        let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [
            .init(range: NSRange(location: 0, length: cut), speakerID: "a"),
            .init(range: NSRange(location: cut, length: text.utf16.count - cut), speakerID: "a")])
        #expect(r.spans.map(\.role) == [.dialogue, .stageDirection, .dialogue])
        coverage(text, r)
    }
    @Test(arguments: [
        "(Siguiendo hacia la derecha.)", "(Deteniéndose amenazador.)",
        "(Observa atento al embozado segundo.)", "(Dejando caer el embozo y abriendo los brazos.)",
        "(Con solemnidad, depositando sobre la mesa sus dos codos.)",
        "(Quitándose la capa y poniéndola muy bien doblada.)", "(Con orgullo.)",
        "(Expresando con voz y gesto la inmensidad.)", "(Sin disimular sus ganas de reír.)",
        "(Con alborozo y soltando del inferior labio hilos de transparente baba.)"
    ]) func recognizesReviewedDirectionForms(_ direction: String) {
        let text = "—Sí. " + direction + " Lo sé."
        let r = StageDialogueStructure.parse(text, languageCode: "es", establishedDialogue: [whole(text)])
        #expect(r.spans.filter { $0.role == .stageDirection }.map(\.text) == [direction])
        #expect(r.spans.filter { $0.role == .dialogue }.allSatisfy { $0.speakerID == "felipe" })
        coverage(text, r)
    }

}
