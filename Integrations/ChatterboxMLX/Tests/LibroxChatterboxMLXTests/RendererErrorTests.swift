import Foundation
import XCTest
@testable import LibroxChatterboxMLX

final class RendererErrorTests: XCTestCase {
    func testExistingNSErrorCodesRemainStable() {
        let resource = ChatterboxMLXRenderer.ResourceGuardDetails(reason: .memory,
            minimumAvailableBytes: 1,
            memory: .init(availableBytes: 0, activeBytes: 0, cacheBytes: 0,
                          peakBytes: 0, lowPowerMode: false, thermalState: 0))
        let errors: [ChatterboxMLXRenderer.RendererError] = [.resourceGuard(resource),
            .precisionPolicy, .identityMismatch, .oracleMismatch, .busy, .missingVoice, .generationLimit]
        for (code, error) in errors.enumerated() {
            let ns = error as NSError
            XCTAssertEqual(ns.code, code)
            XCTAssertEqual(ns.domain, "LibroxChatterboxMLX.ChatterboxMLXRenderer.RendererError")
        }
    }

    func testOracleFailureExportsOnlyFixedFixtureDiagnostics() throws {
        let details = ChatterboxMLXRenderer.OracleValidationDetails(stage: "es.decode.2",
            profileIdentifier: ChatterboxMLXRenderer.DecoderProfile.q8ExperimentalV1.rawValue,
            reason: .numericalMismatch, actualCount: 16_388, expectedCount: 16_388,
            maximumAbsoluteError: 0.125, relativeL2: 0.003, top1Matches: false)
        let error = ChatterboxMLXRenderer.RendererError.oracleValidation(details) as NSError
        XCTAssertEqual(error.code, 7)
        XCTAssertEqual(error.userInfo["oracleStage"] as? String, "es.decode.2")
        XCTAssertEqual(error.userInfo["oracleProfile"] as? String,
                       ChatterboxMLXRenderer.DecoderProfile.q8ExperimentalV1.rawValue)
        XCTAssertEqual(error.userInfo["oracleMaximumAbsoluteError"] as? Double, 0.125)
        XCTAssertEqual(error.userInfo["oracleRelativeL2"] as? Double, 0.003)
        XCTAssertEqual(error.userInfo["oracleTop1Matches"] as? Bool, false)
        XCTAssertEqual(Set(error.userInfo.keys), ["oracleStage", "oracleProfile", "oracleReason",
            "oracleActualCount", "oracleExpectedCount", "oracleMaximumAbsoluteError",
            "oracleRelativeL2", "oracleTop1Matches"])
        _ = try PropertyListSerialization.data(fromPropertyList: error.userInfo, format: .binary, options: 0)
        let decoded = try JSONDecoder().decode(ChatterboxMLXRenderer.OracleValidationDetails.self,
                                              from: JSONEncoder().encode(details))
        XCTAssertEqual(decoded.stage, details.stage)
        XCTAssertEqual(decoded.maximumAbsoluteError, details.maximumAbsoluteError)
    }
}
