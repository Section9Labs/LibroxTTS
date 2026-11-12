import XCTest
import KokoroCatalog
import PocketTTSMLX

final class RequestPreparationTests: XCTestCase {
    func testCompleteAndStreamedRequestsKeepValidationPrecedenceWithoutLoading() async throws {
        let engine = PocketTTSEngine(directory: URL(fileURLWithPath:"/tmp/libroxtts-request-no-assets"))
        for (steps, temperature, voice, expected) in [
            (0,Float.nan,"invalid","invalidSamplerSteps"),
            (4,Float(0.3),"invalid","invalidVoice")
        ] {
            for streamed in [false,true] {
                do {
                    if streamed { try await engine.renderFrames("hello",voiceID:voice,temperature:temperature,samplerSteps:steps,receive:{_ in XCTFail("Invalid request delivered audio")}) }
                    else { _ = try await engine.synthesize("hello",voiceID:voice,temperature:temperature,samplerSteps:steps) }
                    XCTFail("Invalid request succeeded")
                } catch { XCTAssertEqual(String(describing:error),expected) }
                let loaded = await engine.loadedLanguage
                XCTAssertNil(loaded)
            }
        }
    }
}
