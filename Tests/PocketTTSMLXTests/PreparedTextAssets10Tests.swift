import Foundation
import XCTest
@testable import PocketTTSMLX

final class PreparedTextAssets10Tests: XCTestCase {
    func testLeasesShareImmutableTextAssetsWithoutHidingSourceChanges() throws {
        guard let path = ProcessInfo.processInfo.environment["LIBROX_09_ASSETS"] else { throw XCTSkip("Requires text asset fixtures") }
        let source = URL(fileURLWithPath: path).appendingPathComponent("en")
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["config.json", "tokenizer.json"] { try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name)) }
        var first: PocketPreparedTextAssets? = try .load(root)
        var second: PocketPreparedTextAssets? = try .load(root)
        XCTAssertTrue(first === second)
        let tokens = first!.tokenizer.encode("The door was open.")
        weak var released = first
        first = nil; XCTAssertNotNil(released)
        second = nil; XCTAssertNil(released)
        let restored = try PocketPreparedTextAssets.load(root)
        XCTAssertEqual(tokens, restored.tokenizer.encode("The door was open."))
        let file = root.appendingPathComponent("tokenizer.json"), original = try Data(contentsOf: file)
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try PocketPreparedTextAssets.load(root))
        try original.write(to: file)
        XCTAssertTrue(restored === (try PocketPreparedTextAssets.load(root)))
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try PocketPreparedTextAssets.load(root))
        withExtendedLifetime(restored) {}
    }
}
