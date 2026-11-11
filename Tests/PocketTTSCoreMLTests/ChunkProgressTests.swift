import XCTest
import Foundation
import Synchronization
import KokoroCatalog
import PocketTTSCoreML
import PocketTTSMLX

final class ChunkProgressTests: XCTestCase {
    func testContinuousClausePromptKeepsPunctuationCaseAndPlanAcrossBackends() async throws {
        guard let assets = ProcessInfo.processInfo.environment["POCKET_PROGRESS_ASSETS"],
              let models = ProcessInfo.processInfo.environment["POCKET_PROGRESS_MODELS"] else {
            throw XCTSkip("Spanish model assets required")
        }
        let root = URL(fileURLWithPath: assets)
        let config = try PocketTTSModelConfig.load(from: root.appendingPathComponent("es/config.json"))
        for text in ["y puesto que había avalado el préstamo,", "pescado, fruta, almáciga, oud y telas;", "y entonces volvió."] {
            XCTAssertEqual(try PocketTTSTextUtils.prepareTextPrompt(text, config: config,
                preserveSentenceBoundaries: true).0.trimmingCharacters(in: .whitespaces), text)
        }
        let text = "Lo más increíble de todo, ahora que lo pienso, es que aquel asesino siguió visitándonos de tarde en tarde, trayendo regalos como de costumbre, pescado, fruta, almáciga, oud y telas, y en cierta ocasión una reluciente mesita de ébano que mi padre amenazó con destruir pero que acabó en la habitación de la planta baja."
        let core = PocketTTSCoreMLEngine(directory: root, modelsDirectory: URL(fileURLWithPath: models), placement: .cpu)
        let mlx = PocketTTSEngine(directory: root)
        let a = try await core.previewChunks(text, voiceID: "pocket-caro_davy-es-v1", chunking: .carefulReading)
        let b = try await mlx.previewChunks(text, voiceID: "pocket-caro_davy-es-v1", chunking: .carefulReading)
        XCTAssertEqual(a, b)
        XCTAssertGreaterThan(a.count, 1)
        XCTAssertEqual(a.map(\.text).joined(separator: " "), text)
        XCTAssertTrue(a.dropLast().allSatisfy { $0.boundaryAfter == .clause })
        XCTAssertEqual(a.filter(\.startsNewPassage).count, 1)
        await core.unload()
        await mlx.unload()
    }

    func testRejectedFrameDoesNotAnnounceAnUnfinishedTextChunk() async throws {
        guard let assets = ProcessInfo.processInfo.environment["POCKET_PROGRESS_ASSETS"],
              let models = ProcessInfo.processInfo.environment["POCKET_PROGRESS_MODELS"] else {
            throw XCTSkip("Spanish Core ML progress assets required")
        }
        let engine = PocketTTSCoreMLEngine(directory: URL(fileURLWithPath: assets),
            modelsDirectory: URL(fileURLWithPath: models), placement: .cpu)
        let capture = Mutex((frames: 0, events: 0))
        do {
            try await engine.renderFrames("Para entonces Hassan apenas paraba en casa.",
                voiceID: "pocket-caro_davy-es-v1", deliveryStyle: .calm,
                onTextChunk: { _ in capture.withLock { $0.events += 1 } },
                receive: { _ in
                    try capture.withLock { state in
                        state.frames += 1
                        if state.frames == 5 { throw CancellationError() }
                    }
                })
            XCTFail("The receiver's cancellation must terminate synthesis")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(capture.withLock { $0.frames }, 5)
        XCTAssertEqual(capture.withLock { $0.events }, 0)
        await engine.unload()
    }

    func testRealSpanishChunkEventsCoverEmittedPCMWithoutChangingIt() async throws {
        guard let assets = ProcessInfo.processInfo.environment["POCKET_PROGRESS_ASSETS"],
              let models = ProcessInfo.processInfo.environment["POCKET_PROGRESS_MODELS"] else {
            throw XCTSkip("Spanish Core ML progress assets required")
        }
        let engine = PocketTTSCoreMLEngine(directory: URL(fileURLWithPath: assets),
            modelsDirectory: URL(fileURLWithPath: models), placement: .cpu)
        let text = "Para entonces Hassan apenas paraba en casa. Después volvió para hablar con su madre."
        let capture = Mutex((samples: [Float](), events: [PocketTTSChunkProgress](), receivedAtEvent: [Int]()))
        await engine.setRandomSeed(42)
        try await engine.renderFrames(text, voiceID: "pocket-caro_davy-es-v1", chunking: .carefulReading,
            deliveryStyle: .calm, onTextChunk: { event in
                capture.withLock { state in
                    state.events.append(event)
                    state.receivedAtEvent.append(state.samples.count)
                }
            }, receive: { frame in capture.withLock { $0.samples += frame } })
        let actual = capture.withLock { $0 }
        XCTAssertEqual(actual.events.count, 2)
        XCTAssertEqual(actual.events.first?.startSample, 0)
        XCTAssertEqual(actual.events.last?.endSample, actual.samples.count)
        XCTAssertEqual(actual.events.map(\.endSample), actual.receivedAtEvent)
        for (a, b) in zip(actual.events, actual.events.dropFirst()) { XCTAssertEqual(a.endSample, b.startSample) }
        XCTAssertEqual(actual.events.map(\.text).joined(separator: " "), text)
        await engine.setRandomSeed(42)
        let ordinary = try await engine.synthesize(text, voiceID: "pocket-caro_davy-es-v1", chunking: .carefulReading, deliveryStyle: .calm)
        XCTAssertEqual(actual.samples, ordinary.samples, "Enabling metadata must not change any PCM sample")
        await engine.unload()
    }
}
