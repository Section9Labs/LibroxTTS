import Foundation
import XCTest
import ChatterboxCoreML
import LibroxChatterbox
@testable import LibroxChatterboxMLX

final class RendererErrorTests: XCTestCase {
    func testAudioCacheSeparatesLegacyLayoutAndEachAcousticPolicy() throws {
        let decoder = ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate
        let cpu = PipelineComputeUnits(encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly)
        let request = try ChatterboxRequest(text: "Hello.", language: "en", seed: 42)
        let hash = String(repeating: "a", count: 64)
        func key(_ units: PipelineComputeUnits, reuse: Bool = false) throws -> String {
            try request.cacheKey(modelManifestSHA256: hash, conditioningSHA256: hash,
                rendererProfile: ChatterboxMLXRenderer.renderingProfileIdentifier(
                    decoderProfile: decoder, acousticComputeUnits: units, reuseAcousticInputs: reuse))
        }
        let base = try key(cpu)
        XCTAssertEqual(base, try key(cpu))
        XCTAssertNotEqual(base, try request.cacheKey(modelManifestSHA256: hash,
            conditioningSHA256: hash, rendererProfile: decoder.rawValue))
        for stage in 0..<4 {
            var changed = cpu
            switch stage {
            case 0: changed.encoder = .cpuAndGPU
            case 1: changed.cfm = .cpuAndGPU
            case 2: changed.vocoder = .cpuAndGPU
            default: changed.watermark = .cpuAndGPU
            }
            XCTAssertNotEqual(base, try key(changed))
        }
        XCTAssertNotEqual(base, try key(.init()))
        XCTAssertNotEqual(base, try key(cpu, reuse: true))
    }

    func testExplicitWatermarkOptOutHasSeparateAudioIdentity() throws {
        let units = PipelineComputeUnits(encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly)
        let profile = ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate
        let legacy = profile.rawValue + ":" + ChatterboxRequest.adapterRevision + ":acoustics=0,0,0,0:reuse=0"
        let marked = ChatterboxMLXRenderer.renderingProfileIdentifier(decoderProfile: profile, acousticComputeUnits: units)
        XCTAssertEqual(marked, legacy)
        let unmarked = ChatterboxMLXRenderer.renderingProfileIdentifier(decoderProfile: profile,
            acousticComputeUnits: units, watermarkPolicy: .disabled)
        XCTAssertNotEqual(marked, unmarked)
        let request = try ChatterboxRequest(text: "Hello.", language: "en", seed: 42)
        let hash = String(repeating: "a", count: 64)
        XCTAssertNotEqual(try request.cacheKey(modelManifestSHA256: hash, conditioningSHA256: hash, rendererProfile: marked),
                          try request.cacheKey(modelManifestSHA256: hash, conditioningSHA256: hash, rendererProfile: unmarked))
        XCTAssertEqual(ChatterboxWatermarkPolicy(rawValue: "disabled-1"), .disabled)
        XCTAssertNil(ChatterboxWatermarkPolicy(rawValue: "automatic-fallback"))
    }

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
            profileIdentifier: ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate.rawValue,
            reason: .numericalMismatch, actualCount: 16_388, expectedCount: 16_388,
            maximumAbsoluteError: 0.125, relativeL2: 0.003, top1Matches: false)
        let error = ChatterboxMLXRenderer.RendererError.oracleValidation(details) as NSError
        XCTAssertEqual(error.code, 7)
        XCTAssertEqual(error.userInfo["oracleStage"] as? String, "es.decode.2")
        XCTAssertEqual(error.userInfo["oracleProfile"] as? String,
                       ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate.rawValue)
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
