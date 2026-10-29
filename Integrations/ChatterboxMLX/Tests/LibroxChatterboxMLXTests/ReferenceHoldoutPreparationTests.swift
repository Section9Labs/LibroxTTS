#if os(macOS)
import XCTest
@testable import LibroxChatterboxMLX

final class ReferenceHoldoutPreparationTests: XCTestCase {
    private func ids(rows: Int) -> [Int32] { [255] + [Int32](repeating: 1, count: rows - 38) + [0] }
    func testWholeWordSelectionUsesLastBoundaryAndFirstLongWithoutMonotonicAssumption() throws {
        let text = "one  two\nthree four five"
        let counts = ["one": 251, "one  two": 260, "one  two\nthree": 254,
            "one  two\nthree four": 503, text: 501]
        var visits: [String] = []
        let boundary = try ReferenceHoldoutPreparation.select(text: text, kind: "boundary", encode: {
            visits.append($0); return self.ids(rows: counts[$0]!)
        }, check: {})
        XCTAssertEqual(boundary.text, "one  two\nthree")
        XCTAssertEqual(boundary.rows, 254); XCTAssertEqual(boundary.wordCount, 3)
        XCTAssertEqual(visits.count, 5)
        let long = try ReferenceHoldoutPreparation.select(text: text, kind: "long",
            encode: { self.ids(rows: counts[$0]!) }, check: {})
        XCTAssertEqual(long.text, "one  two\nthree four"); XCTAssertEqual(long.rows, 503)
    }
    func testInvalidCasesAndCancellationCannotProduceSelection() throws {
        XCTAssertThrowsError(try ReferenceHoldoutPreparation.select(text: "one", kind: "short",
            encode: { _ in self.ids(rows: 129) }, check: {}))
        XCTAssertThrowsError(try ReferenceHoldoutPreparation.select(text: "one", kind: "long",
            encode: { _ in self.ids(rows: 513) }, check: {}))
        XCTAssertThrowsError(try ReferenceHoldoutPreparation.select(text: "one", kind: "short",
            encode: { _ in [255, 2454, 0] }, check: {}))
        XCTAssertThrowsError(try ReferenceHoldoutPreparation.select(text: "one", kind: "boundary",
            encode: { _ in XCTFail("Cancellation must precede tokenization"); return [] },
            check: { throw CancellationError() }))
    }
}
#endif
