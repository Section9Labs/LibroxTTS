import Foundation
import MLX
import PocketTTSCoreML
import PocketTTSMLX
import Synchronization
import XCTest
@testable import LibroxTTS

final class NarrationBackendParityTests: XCTestCase {
    private struct Event: Decodable, Equatable {
        let text: String
        let start: Int
        let end: Int
        let accepted: Int
    }
    private struct Receipt: Decodable { let events: [Event] }

    func testMLXFacadeMatchesDirectEngineOnCPUAndGPU() async throws {
        guard let assets = ProcessInfo.processInfo.environment["LIBROX_08_MLX_ASSETS"] else {
            throw XCTSkip("Verified local MLX assets are required")
        }
        if let path = ProcessInfo.processInfo.environment["POCKET_METALLIB"] {
            GPU.metallib = URL(fileURLWithPath: path)
        }
        let root = URL(fileURLWithPath: assets)
        let engine = PocketTTSEngine(directory: root)
        let renderer = NarrationRenderer(compactDirectory: root, admission: .init(), maxFactory: { _, _ in
            PocketNarrationBackend.mlx(engine)
        })
        let text = "The door was open."
        var unit = BookNarrationUnit(sourceText: text, sourceRange: NSRange(location: 0, length: text.utf16.count),
                                     narratorID: "pocket-alba-en-v1", boundaryAfter: .sentence)
        unit.pocketChunking = .carefulReading
        unit.pocketSampling = .init(temperature: 0.3, samplerSteps: 4)
        await renderer.setCPUBudget(fraction: nil)
        for context: NarrationRenderer.ExecutionContext in [.foreground, .background] {
            try await renderer.load(.pocket, directory: root, executionContext: context)
            await engine.setRandomSeed(42)
            let coldReference = try await engine.synthesize(text, voiceID: unit.voiceID, chunking: .carefulReading,
                                                       samplerSteps: 4).samples
            // Model initialization consumes RNG in the existing engine. Compare
            // matching residency states; do not change its cold/warm sequence.
            await engine.unload()
            await engine.setRandomSeed(42)
            let coldComplete = try await renderer.render(unit)
            XCTAssertEqual(coldComplete.withUnsafeBytes { Data($0) }, coldReference.withUnsafeBytes { Data($0) })
            await engine.setRandomSeed(42)
            let reference = try await engine.synthesize(text, voiceID: unit.voiceID, chunking: .carefulReading,
                                                       samplerSteps: 4).samples
            await engine.setRandomSeed(42)
            let complete = try await renderer.render(unit)
            XCTAssertEqual(complete.withUnsafeBytes { Data($0) }, reference.withUnsafeBytes { Data($0) })
            await engine.setRandomSeed(42)
            let frames = Mutex([Float]())
            try await renderer.renderPocketFrames(unit, receive: { frame in frames.withLock { $0 += frame } })
            XCTAssertEqual(frames.withLock { $0.withUnsafeBytes { Data($0) } }, reference.withUnsafeBytes { Data($0) })
        }
        await renderer.unload()
    }

    func testRealFacadeMatches062PCMEventsAndRecoversAfterReceiverCancellation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let assets = env["LIBROX_08_POCKET_ASSETS"], let recordings = env["LIBROX_07_AUDIO_BASELINE"] else {
            throw XCTSkip("Verified Core ML assets and the frozen 0.6.2 recordings are required")
        }
        let root = URL(fileURLWithPath: assets), baseline = URL(fileURLWithPath: recordings)
        for (language, text) in [("en", "The door was open."), ("es", "La puerta estaba abierta.")] {
            try PocketTTSCoreMLAssets.prepare(in: root, language: language)
            let engine = PocketTTSCoreMLEngine(directory: root)
            let renderer = NarrationRenderer(compactDirectory: root, admission: .init(), maxFactory: { _, _ in
                PocketNarrationBackend.coreML(engine)
            })
            var unit = BookNarrationUnit(sourceText: text, sourceRange: NSRange(location: 0, length: text.utf16.count),
                                         narratorID: "pocket-caro_davy-\(language)-v1", boundaryAfter: .sentence)
            unit.pocketChunking = .carefulReading; unit.pocketDeliveryStyle = .calm
            try await renderer.load(.pocket, directory: root, executionContext: .foreground)
            let name = "pocket-\(language)-3-steps4"
            let expected = try Data(contentsOf: baseline.appendingPathComponent(name + ".f32"))
            await engine.setRandomSeed(42)
            let complete = try await renderer.render(unit)
            XCTAssertEqual(complete.withUnsafeBytes { Data($0) }, expected)
            await engine.setRandomSeed(42)
            let capture = Mutex((samples: [Float](), events: [Event]()))
            try await renderer.renderPocketFrames(unit, onTextChunk: { event in
                capture.withLock { $0.events.append(Event(text: event.text, start: event.startSample,
                    end: event.endSample, accepted: $0.samples.count)) }
            }, receive: { frame in capture.withLock { $0.samples += frame } })
            let result = capture.withLock { $0 }
            XCTAssertEqual(result.samples.withUnsafeBytes { Data($0) }, expected)
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: baseline.appendingPathComponent(name + ".json")))
            XCTAssertEqual(result.events, receipt.events)
            do {
                try await renderer.renderPocketFrames(unit, onTextChunk: { _ in XCTFail("Cancelled chunk completed") },
                    receive: { _ in throw CancellationError() })
                XCTFail("Cancellation was lost")
            } catch is CancellationError {}
            let retired = await renderer.loadedPocketLanguage
            XCTAssertNil(retired)
            await engine.setRandomSeed(42)
            let recovered = try await renderer.render(unit)
            XCTAssertEqual(recovered.withUnsafeBytes { Data($0) }, expected)
            await renderer.unload()
        }
    }
}
