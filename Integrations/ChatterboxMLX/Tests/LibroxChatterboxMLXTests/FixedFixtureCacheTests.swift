import XCTest
import MLX
@testable import LibroxChatterboxMLX

final class FixedFixtureCacheTests: XCTestCase {
    func testSnapshotIsIndependentAndRestorePreservesAppendLayout() throws {
        try Device.withDefaultDevice(.cpu) {
            let cache = KVCache()
            let keys = MLXArray.ones([2, 16, 93, 64], dtype: .float16)
            let values = keys * MLXArray(Float16(2))
            _ = cache.update(keys: keys, values: values)
            let snapshot = try cache.fixedFixtureSnapshot()
            let restored = try KVCache.restoringFixedFixture(
                keys: MLXArray(snapshot.keys, [2, 16, 93, 64]),
                values: MLXArray(snapshot.values, [2, 16, 93, 64]))
            let restoredSnapshot = try restored.fixedFixtureSnapshot()
            XCTAssertEqual(restored.offset, 93)
            XCTAssertEqual(snapshot.keys.map(\.bitPattern), restoredSnapshot.keys.map(\.bitPattern))
            XCTAssertEqual(snapshot.values.map(\.bitPattern), restoredSnapshot.values.map(\.bitPattern))
            let next = MLXArray.zeros([2, 16, 1, 64], dtype: .float16)
            let appended = restored.update(keys: next, values: next)
            XCTAssertEqual(restored.offset, 94)
            XCTAssertEqual(appended.0.shape, [2, 16, 94, 64])
            XCTAssertEqual(appended.0[.ellipsis, ..<93, 0...].asArray(Float16.self), snapshot.keys)
            XCTAssertTrue(appended.0[.ellipsis, 93, 0...].asArray(Float16.self).allSatisfy { $0 == 0 })
            // Deliberately overwrite the original prefix, not merely append to
            // it, so an accidentally aliased snapshot would change here.
            cache.offset = 0
            let overwrite = MLXArray.zeros([2, 16, 93, 64], dtype: .float16)
            _ = cache.update(keys: overwrite, values: overwrite)
            let overwritten = try cache.fixedFixtureSnapshot()
            XCTAssertTrue(overwritten.keys.allSatisfy { $0 == 0 })
            XCTAssertTrue(overwritten.values.allSatisfy { $0 == 0 })
            XCTAssertTrue(snapshot.keys.allSatisfy { $0 == 1 })
            XCTAssertTrue(snapshot.values.allSatisfy { $0 == 2 })
        }
    }

    func testRestoreRejectsWrongPublicFixtureBeforeUse() throws {
        try Device.withDefaultDevice(.cpu) {
            let wrong = MLXArray.zeros([2, 16, 92, 64], dtype: .float16)
            XCTAssertThrowsError(try KVCache.restoringFixedFixture(keys: wrong, values: wrong))
            let wrongType = MLXArray.zeros([2, 16, 93, 64], dtype: .float32)
            XCTAssertThrowsError(try KVCache.restoringFixedFixture(keys: wrongType, values: wrongType))
        }
    }
}
