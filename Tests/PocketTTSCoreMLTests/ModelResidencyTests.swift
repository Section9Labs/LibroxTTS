import XCTest
@testable import PocketTTSCoreML

final class ModelResidencyTests: XCTestCase {
    private final class Model {}

    func testAllSamplerCountsLoadOnlyThreeGraphsAndReuseTheirIdentity() {
        var cache = PocketFlowModels<Model>()
        var loads: [String] = []
        let models = (1...8).map { steps in
            cache.model(steps: steps) { graph in loads.append(graph); return Model() }
        }
        XCTAssertEqual(loads, ["flowstep", "flow4", "flow8"])
        for steps in [1, 2, 3, 5, 6, 7] { XCTAssertTrue(models[steps - 1] === models[0]) }
        XCTAssertFalse(models[3] === models[0])
        XCTAssertFalse(models[7] === models[3])
        for steps in (1...8).reversed() {
            let reused = cache.model(steps: steps) { _ in XCTFail("Reloaded a resident graph"); return Model() }
            XCTAssertTrue(reused === models[steps - 1])
        }
    }

    func testFailedLoadsAreRetriedAndNewLanguageOwnsFreshModels() throws {
        enum Failure: Error { case load }
        var cache = PocketFlowModels<Model>()
        XCTAssertThrowsError(try cache.model(steps: 2) { _ in throw Failure.load })
        let loaded = cache.model(steps: 3) { _ in Model() }
        XCTAssertTrue(cache.model(steps: 2) { _ in XCTFail("Lost loaded graph"); return Model() } === loaded)
        weak var retained = loaded
        cache = PocketFlowModels<Model>()
        let replacement = cache.model(steps: 2) { _ in Model() }
        XCTAssertFalse(replacement === retained)
    }

    func testRetiringLanguageReleasesAllGraphs() {
        var cache = PocketFlowModels<Model>()
        weak var generic = cache.model(steps: 1) { _ in Model() }
        weak var four = cache.model(steps: 4) { _ in Model() }
        weak var eight = cache.model(steps: 8) { _ in Model() }
        XCTAssertNotNil(generic); XCTAssertNotNil(four); XCTAssertNotNil(eight)
        cache = PocketFlowModels<Model>()
        XCTAssertNil(generic); XCTAssertNil(four); XCTAssertNil(eight)
    }
}
