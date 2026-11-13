import Foundation
import CryptoKit
import XCTest
import MLX
import KokoroCatalog
import PocketTTSCoreML
import PocketTTSMLX

/// Neutral calibration and disjoint holdout passages. Raw samples remain local;
/// the offline BS.1770 audit generates delivery profiles, not model weights.
final class Release10LoudnessTests: XCTestCase {
    func testRecordNeutralVoiceLevels() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LIBROX_LEVEL_ASSETS"], let destination = env["LIBROX_LEVEL_OUTPUT"],
              let corpusPath = env["LIBROX_LEVEL_CORPUS"] else {
            throw XCTSkip("Opt-in voice calibration with pinned assets")
        }
        let corpus = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let languages = (env["LIBROX_LEVEL_LANGUAGES"] ?? "en,es").split(separator: ",").map(String.init)
        let coreML = env["LIBROX_LEVEL_BACKEND"] == "coreml"
        if let metal = env["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: metal) }
        let root = URL(fileURLWithPath: path), output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let core = PocketTTSCoreMLEngine(directory: root)
        let mlx = PocketTTSEngine(directory: root, backend: .cpu)
        await core.setCPUBudgetFraction(nil); await mlx.setCPUBudgetFraction(nil)
        for language in languages {
            let texts = try XCTUnwrap(corpus[language]); XCTAssertEqual(texts.count, 5)
            let firstVoice = "pocket-caro_davy-\(language)-v1"
            if coreML { _ = try await core.previewChunks(texts[0], voiceID: firstVoice) }
            else { _ = try await mlx.previewChunks(texts[0], voiceID: firstVoice) }
            let styled = env["LIBROX_LEVEL_STYLES"] == "all"
            let voices = styled ? PocketTTSDeliveryCatalog.referenceVoiceNames : PocketTTSCatalog.voiceNames
            for voice in voices {
                let id = "pocket-\(voice)-\(language)-v1"
                let styles: [PocketTTSDeliveryStyle] = styled
                    ? PocketTTSDeliveryCatalog.publishedStyles(voiceID: id).filter { $0 != .original }
                    : [.original]
                for style in styles {
                for (index, text) in texts.enumerated() {
                    let name = "\(language)-\(voice)\(style == .original ? "" : "__" + style.rawValue)-\(index)"
                    // Resume only complete local records; no production cache is involved.
                    let receipt = output.appendingPathComponent(name + ".json")
                    if FileManager.default.fileExists(atPath: receipt.path) {
                        let existing = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
                        XCTAssertEqual(existing["text"] as? String, text)
                        XCTAssertEqual(existing["voiceID"] as? String, id)
                        XCTAssertEqual(existing["style"] as? String ?? "original", style.rawValue)
                        XCTAssertEqual(existing["backend"] as? String, coreML ? "coreml-cpu" : "mlx-cpu")
                        XCTAssertEqual(existing["seed"] as? Int, 42)
                        let pcm = try Data(contentsOf: output.appendingPathComponent(name + ".f32"))
                        XCTAssertEqual(pcm.count, (existing["samples"] as? Int ?? -1) * 4)
                        XCTAssertEqual(SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined(), existing["sha256"] as? String)
                        continue
                    }
                    let samples: [Float]
                    if coreML {
                        await core.setRandomSeed(42)
                        samples = try await core.synthesize(text, voiceID: id, role: .dialogue, samplerSteps: 4, deliveryStyle: style).samples
                    } else {
                        await mlx.setRandomSeed(42)
                        samples = try await mlx.synthesize(text, voiceID: id, role: .dialogue, samplerSteps: 4, deliveryStyle: style).samples
                    }
                    XCTAssertFalse(samples.isEmpty); XCTAssertTrue(samples.allSatisfy(\.isFinite))
                    try autoreleasepool {
                        let pcm = samples.withUnsafeBytes { Data($0) }
                        let row: [String: Any] = ["language":language,"voice":voice,"voiceID":id,"passage":index,
                            "style":style.rawValue,"split":index < 3 ? "calibration" : "holdout","text":text,"samples":samples.count,
                            "sampleRate":24_000,"backend":coreML ? "coreml-cpu" : "mlx-cpu", "seed":42,
                            "sha256":SHA256.hash(data:pcm).map { String(format:"%02x",$0) }.joined()]
                        try pcm.write(to:output.appendingPathComponent(name + ".f32"),options:.atomic)
                        try JSONSerialization.data(withJSONObject:row,options:[.prettyPrinted,.sortedKeys])
                            .write(to:output.appendingPathComponent(name + ".json"),options:.atomic)
                    }
                }
                }
            }
            await core.unload(); await mlx.unload()
        }
        try Data("complete".utf8).write(to:output.appendingPathComponent("complete.txt"),options:.atomic)
    }
}
