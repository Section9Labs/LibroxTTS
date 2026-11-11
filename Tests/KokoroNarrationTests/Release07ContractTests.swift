import Foundation
import XCTest
import KokoroCatalog
import KokoroPronunciation
import KokoroNarration

/// Recorded against v0.6.2 before changing the runtime. The recording destination
/// is explicit and never the bundled fixture; normal tests only read the fixture.
final class Release07ContractTests: XCTestCase {
    struct Snapshot: Codable, Equatable {
        var normalized: [String: String] = [:]
        var plans: [String: [[String: String]]] = [:]
    }

    static let readings = [
            "", "La puerta estaba abierta y nadie regresaba,", "alle una", "Alle una",
            "Capítulo XII. Chapter IV. 第IV章", "XII\n\nMIX\n\nI", "Cafe\u{301}...\r\n\r\n«Sí?!»",
            "21 libros y 21 personas; 2.000.001 páginas", "2024-02-29 2023-02-29 14:01 24:00",
            "€21,01 $1.50 £2.01 R$2,00 ₹21.50 12%", "1,234.56 1.234,56 1234567890123456",
            "٠١٢ １２３ २१ 2人 4時 2个", "v1.2.3 12/03/2026 abc12 A_21", "\"\"___😀\u{00A0}−0.01",
            "第Ⅻ章 Ⅳ", "He paused\n\nthen returned."
    ]

    static func capture() throws -> Snapshot {
        var result = Snapshot()
        for language in PronunciationLanguage.allCases {
            for (index, input) in readings.enumerated() {
                result.normalized["\(language.rawValue)/\(index)"] = TextNormalizer.normalize(input, language: language)
            }
        }
        let cases: [(String, String, String)] = [
            ("clauses", "es", String(repeating: "La puerta estaba abierta y nadie regresaba, ", count: 14)),
            ("numbers", "es", String(repeating: "21 páginas, 14:01 y €21,01; ", count: 12)),
            ("paragraphs", "en", "“Wait,” she said.\n\nHe returned—quietly.\r\n\r\nThe door was open."),
            ("unicode", "fr", String(repeating: "Cafe\u{301}, «bonjour» et l’été; ", count: 22)),
            ("cjk", "ja", String(repeating: "第IV章。彼は二人の友達を待った。", count: 24)),
            ("dictionary", "es", String(repeating: "Dr. Ada cerró QX y R2. ", count: 28)),
            ("unbroken", "en", String(repeating: "a", count: 520)),
            ("italian", "it", "Alle una era lì; alle una tornò. 21:01.")
        ]
        for model in [NarrationModel.plus, .pocket] {
            for (name, language, text) in cases where model.supportedLanguageCodes.contains(language) {
                let lexicon = SpokenTextLexicon(entries: [
                    .init(written: "Dr.", spoken: "doctor", language: language),
                    .init(written: "QX", spoken: "un nombre extraordinariamente largo", language: language),
                    .init(written: "R2", spoken: "R", language: language)
                ])
                let voice = model == .plus ? "plus-f1-\(language)-v1" : "pocket-caro_davy-\(language)-v1"
                let options = PocketTTSChunkingOptions(maximumUnitScalars: 256)
                let units = try TextNativeNarrationPlanner.plan(text, voiceID: voice, lexicon: lexicon,
                                                               model: model, pocketChunking: options)
                result.plans["\(model.rawValue)/\(name)"] = units.map { unit in
                    ["text": unit.text, "spoken": unit.synthesisText, "voice": unit.voiceID,
                     "range": "\(unit.range.location):\(unit.range.length)", "phonemes": unit.phonemes,
                     "boundary": unit.boundaryAfter.rawValue, "role": unit.role.rawValue,
                     "expression": unit.expression.rawValue, "speaker": unit.speakerID ?? "nil",
                     "prosody": unit.prosody.map { "\($0.terminal.rawValue):\($0.questionKind.rawValue):\($0.expression.rawValue):\($0.hasMultipleSentences):\($0.terminalPhonemes)" } ?? "nil",
                     // Runtime routing varies by platform; keep its prefix separately tested.
                     "identity": model.renderIdentity(for: unit).replacingOccurrences(of: model.deliveryIdentity, with: "<runtime>"),
                     "diagnostics": unit.pronunciationDiagnostics.map { "\($0.code.rawValue):\($0.detail)" }.joined(separator: "\n")]
                }
            }
        }
        return result
    }

    func testFrozen062NormalizationAndPlans() throws {
        let actual = try Self.capture()
        if let destination = ProcessInfo.processInfo.environment["LIBROX_07_RECORD_CONTRACTS"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(actual).write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
            return
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "release-062-contracts", withExtension: "json"))
        let expected = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(actual.normalized, expected.normalized)
        XCTAssertEqual(actual.plans, expected.plans)
    }

    func testSavedSettingsAndRenderDefaultsRemainCompatible() throws {
        let decoder = JSONDecoder()
        for raw in ["compact", "enhanced", "kokoroDesktop", "qwenDesktop", "ctPlusV1", "pocketTTSV1"] {
            let model = try decoder.decode(NarrationModel.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(model.rawValue, raw)
            XCTAssertEqual(model.outputSampleRate, model == .plus ? 44_100 : 24_000)
        }
        let sampling = try decoder.decode(PocketTTSSamplingOptions.self,
            from: Data(#"{"temperature":0.3,"samplerSteps":4}"#.utf8))
        XCTAssertEqual(sampling, .init())
        XCTAssertEqual(sampling.cacheIdentity, "pocket-sampling-1:temperature0.3:steps4")
        XCTAssertEqual(PocketTTSChunkingOptions.revision, "pocket-continuous-clauses-2")
        for steps in 1...8 { XCTAssertNoThrow(try PocketTTSSamplingOptions(samplerSteps: steps).validate()) }
        XCTAssertThrowsError(try PocketTTSSamplingOptions(samplerSteps: 0).validate())
        XCTAssertThrowsError(try PocketTTSSamplingOptions(temperature: .nan).validate())
        let preset = try PocketTTSNarratorPreset.defaultNarrator(language: "es")
        XCTAssertEqual(preset.voiceID, "pocket-caro_davy-es-v1")
        XCTAssertEqual(preset.delivery.narratorStyle, .calm)
        XCTAssertEqual(preset.chunking, .carefulReading)
    }

    func testConcurrentNormalizationMatchesFrozenReadings() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "release-062-contracts", withExtension: "json"))
        let expected = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url)).normalized
        DispatchQueue.concurrentPerform(iterations: 32) { iteration in
            let language = PronunciationLanguage.allCases[iteration % PronunciationLanguage.allCases.count]
            for (index, input) in Self.readings.enumerated() {
                XCTAssertEqual(TextNormalizer.normalize(input, language: language), expected["\(language.rawValue)/\(index)"])
            }
        }
    }

    func testPlanningLimitsAndProtectedPassagesRemainErrors() {
        XCTAssertThrowsError(try TextNativeNarrationPlanner.plan(String(repeating: "a", count: 16_385), voiceID: "plus-f1-en-v1")) {
            XCTAssertEqual($0 as? PronunciationError, .inputTooLong(limit: 16_384))
        }
        XCTAssertThrowsError(try TextNativeNarrationPlanner.plan(String(repeating: "word ", count: 100),
            voiceID: "pocket-caro_davy-en-v1", model: .pocket,
            pocketChunking: .init(maximumUnitScalars: 128, grouping: .keepTogether))) {
            guard case TextNativeNarrationPlanner.PlanningError.unbreakableText = $0 else {
                return XCTFail("Changed protected-passage error: \($0)")
            }
        }
    }
}
