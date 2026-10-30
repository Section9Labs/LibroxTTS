#if os(macOS)
import XCTest
import Foundation
import LibroxChatterbox
@testable import LibroxChatterboxMac
final class LegacySynthesisIdentityTests: XCTestCase {
    func testFrozenLegacyIdentitiesSurviveSharedPlanningMove() throws {
        var output: [String: String] = [:]
        for i in 0..<3 {
            let text = "Keep going."
            let directions = i == 2 ? try ChatterboxPerformanceDirections(source: text, annotations: [
                .init(range: NSRange(location: 0, length: text.utf16.count), originalText: text,
                    performance: .init(delivery: .urgent, strength: .strong), controls: .init(exaggeration: 0.9, guidance: 0.3, temperature: 0.8))
            ], scope: .chapterV1) : nil
            let options = try ChatterboxMacChapterRequest(text: text, language: i == 1 ? "es" : "en",
                delivery: i == 1 ? .lossless : .smaller, direction: i == 1 ? .neutral : .storyteller,
                grouping: i == 1 ? .compatibleNarration(maxCharacters: 160) : .sentences,
                performanceDirections: directions, seed: i == 2 ? .max : 42)
            output["\(i)-synthesis"] = try options.synthesisIdentity(rendererProfile: "synthetic-local-worker-1")
            output["\(i)-delivery"] = try options.deliveryIdentity(rendererProfile: "synthetic-local-worker-1")
        }
        let expected = [
            "0-delivery": "e9e0754e8a5876747265f54052b4f79714f08eea96d4857d461f2889f724e109",
            "0-synthesis": "95daa77f6f51b9bb374d9925e465e1af203ee377ee0487cd959a3b37c03bbb89",
            "1-delivery": "841665d6778ca756702db0822fb160c926d4978ee448fe03a7810e9e85b2826d",
            "1-synthesis": "2f772c2ce59af0c8645ae42cb310ab12b51345ccd86deedfedc34d1e1878cc73",
            "2-delivery": "f2dadfe4113547545f1bbd28640103dc6da894b9b05870d64f8353076a369478",
            "2-synthesis": "60993f73641271d2fe625a977e681a138be9f623010138b804d59ac1cec7e3e0"
        ]
        XCTAssertEqual(output, expected)
    }
}
#endif
