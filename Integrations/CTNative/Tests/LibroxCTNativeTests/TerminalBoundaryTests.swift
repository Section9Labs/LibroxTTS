import XCTest
@testable import LibroxCTNative

final class TerminalBoundaryTests: XCTestCase {
    func testRequiredCarryContract() throws {
        XCTAssertNoThrow(try CTContextStyleDiagnostic.validateRequiredCarry(mode: nil, revision: nil, configured: .disabled))
        XCTAssertNoThrow(try CTContextStyleDiagnostic.validateRequiredCarry(mode: "linear-two-step",
            revision: CTContextStyleDiagnostic.carryRevision, configured: .linearTwoStep))
        XCTAssertThrowsError(try CTContextStyleDiagnostic.validateRequiredCarry(mode: "linear-two-step",
            revision: CTContextStyleDiagnostic.carryRevision, configured: .disabled))
        XCTAssertThrowsError(try CTContextStyleDiagnostic.validateRequiredCarry(mode: "linear-two-step",
            revision: "unknown", configured: .linearTwoStep))
        XCTAssertThrowsError(try CTContextStyleDiagnostic.validateRequiredCarry(mode: nil,
            revision: CTContextStyleDiagnostic.carryRevision, configured: .linearTwoStep))
    }
    func testEndingSelectionAndLexicalPreservation() throws {
        for (language, spoken, ending) in [("en", "<en>\"We made it.\"</en>", ".\"</en>"),
            ("es", "<es>«¿Ya llegó?»</es>", "?»</es>"), ("en", "<en>Wait</en>", "</en>"),
            ("es", "<es>¡No…! </es>", "…! </es>")] {
            let input = try CTTerminalBoundary(normalized: spoken, language: language)
            let scalars = Array(spoken.unicodeScalars)
            XCTAssertEqual(String(String.UnicodeScalarView(input.protectedIndices.map { scalars[$0] })), ending)
            XCTAssertFalse(input.usedFallback)
            let ones = try CTTerminalBoundary(normalized: spoken, language: language, allOnes: true)
            XCTAssertTrue(ones.protectedIndices.isEmpty)
        }
    }
    func testMalformedEnvelopeFallsBack() throws {
        for text in ["Hello.", "<en>Hello.</es>", "<en>Hello."] {
            let input = try CTTerminalBoundary(normalized: text, language: "en")
            XCTAssertTrue(input.usedFallback)
            XCTAssertTrue(input.protectedIndices.isEmpty)
        }
    }
    func testPunctuationOnlyAndInternalPunctuation() throws {
        let text = "<en>First. Last!</en>"
        let input = try CTTerminalBoundary(normalized: text, language: "en")
        let scalars = Array(text.unicodeScalars)
        XCTAssertEqual(String(String.UnicodeScalarView(input.protectedIndices.map { scalars[$0] })), "!</en>")
        XCTAssertEqual(try CTTerminalBoundary(normalized: "<en>...</en>", language: "en").protectedIndices.count, 8)
    }
}
