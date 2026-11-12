import XCTest
@testable import PronunciationEnglish

final class LexiconOwnershipTests: XCTestCase {
    private final class Resource: Sendable {}
    private enum Failure: Error { case load }
    func testLastOwnerReleasesResourceAndFailuresAreNotCached() throws {
        let cache = WeakResourceCache<Bool, Resource>()
        XCTAssertThrowsError(try cache.value(for: false) { throw Failure.load })
        var first: Resource? = cache.value(for: false) { Resource() }
        weak var weakOwner = first
        var second: Resource? = cache.value(for: false) { XCTFail("Reloaded a live resource"); return Resource() }
        XCTAssertTrue(first === second)
        first = nil; XCTAssertNotNil(weakOwner)
        second = nil; XCTAssertNil(weakOwner)
        let replacement = cache.value(for: false) { Resource() }
        withExtendedLifetime(replacement) {}
    }
    func testConcurrentLexiconsShareOnlyTheMatchingDialect() async throws {
        let us = try Lexicon(), gb = try Lexicon(british: true)
        XCTAssertNotEqual(us.resourceIdentity,gb.resourceIdentity)
        try await withThrowingTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<16 { group.addTask { try Lexicon().resourceIdentity } }
            for try await identity in group { XCTAssertEqual(identity,us.resourceIdentity) }
        }
        XCTAssertEqual(try Lexicon().getNNP("Alice").0,us.getNNP("Alice").0)
        XCTAssertEqual(try Lexicon(british:true).getNNP("Alice").0,gb.getNNP("Alice").0)
    }
}
