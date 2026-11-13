import Foundation
import XCTest
import KokoroCatalog
@testable import KokoroNarration

final class PocketNarrationLevelTests: XCTestCase {
    func testCatalogueCoverageAndBoundedGain() throws {
        var count = 0
        for voice in PocketTTSCatalog.voices {
            for style in PocketTTSDeliveryCatalog.publishedStyles(voiceID: voice.id) {
                let gain = try XCTUnwrap(PocketNarrationLevelProfiles.gains[voice.id + "|" + style.rawValue])
                XCTAssertTrue(gain.isFinite && gain > 0 && gain <= 2.8183832)
                count += 1
            }
        }
        XCTAssertEqual(count, 525)
        XCTAssertEqual(PocketNarrationLevelProfiles.gains.count, count)
        XCTAssertEqual(PocketNarrationLevel.gain(voiceID: "unknown", style: .original), 1)
    }

    func testUniformGainRetainsSamplesDynamicsSilenceAndInputOwnership() {
        let input: [Float] = [0, -0.0, 0.01, -0.02, 0.1, -0.2, 0.4]
        let before = input.map(\.bitPattern)
        for gain: Float in [0.25, 0.8, 1, 1.5, 1.9952623] {
            let output = PocketNarrationLevel.apply(input, gain: gain)
            XCTAssertEqual(output.map(\.bitPattern), input.map { ($0 * gain).bitPattern })
            XCTAssertEqual(input.map(\.bitPattern), before)
        }
    }

    func testEveryFramePartitionMatchesBufferedOutputIncludingPeakSafety() {
        let input = (0..<8201).map { Float(sin(Double($0) * 0.071)) * 0.8 }
        let expected = PocketNarrationLevel.apply(input, gain: 1.8).map(\.bitPattern)
        for width in [1, 127, 1920, 4096, input.count] {
            var output: [Float] = []
            for start in stride(from: 0, to: input.count, by: width) {
                output += PocketNarrationLevel.apply(Array(input[start..<min(start + width, input.count)]), gain: 1.8)
            }
            XCTAssertEqual(output.map(\.bitPattern), expected)
            XCTAssertEqual(output.count, input.count)
            XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= Float(0.98) })
        }
    }

    func testPeakSafetyIsContinuousAndNeverTouchesAttenuationOrUnity() {
        let input: [Float] = [-2, -0.450001, -0.45, 0, 0.45, 0.450001, 2, .greatestFiniteMagnitude]
        let output = PocketNarrationLevel.apply(input, gain: 2)
        XCTAssertEqual(output[2], -0.9); XCTAssertEqual(output[4], 0.9)
        XCTAssertLessThan(abs(output[5] - output[4]), 0.00001)
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= Float(0.98) })
        XCTAssertEqual(PocketNarrationLevel.apply(input, gain: 1).map(\.bitPattern), input.map(\.bitPattern))
        XCTAssertEqual(PocketNarrationLevel.apply(input, gain: 0.25), input.map { $0 * 0.25 })
    }

    func testOnlyMaxDeliveryCacheIdentityChanges() {
        XCTAssertTrue(NarrationModel.pocket.deliveryIdentity.contains(PocketNarrationLevel.revision))
        XCTAssertEqual(NarrationModel.plus.deliveryIdentity, "dk-delivery-v1:native44100:source-boundaries:native-dynamics")
        XCTAssertEqual(NarrationModel.kokoroDesktop.deliveryIdentity, "profiled-narration-runtime-1")
        var unit = BookNarrationUnit(sourceText: "The door was open.", sourceRange: NSRange(location: 0, length: 18),
                                     narratorID: "pocket-caro_davy-en-v1", boundaryAfter: .sentence)
        let original = NarrationModel.pocket.renderIdentity(for: unit)
        unit.pocketDeliveryStyle = .shout
        XCTAssertNotEqual(original, NarrationModel.pocket.renderIdentity(for: unit))
    }
}
