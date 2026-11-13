import Foundation
import CryptoKit
import XCTest
import KokoroCatalog
@testable import KokoroNarration

/// Opt-in offline audit of the production transform over raw calibration/holdout PCM.
/// Rendering models is separate, so this also measures delivery overhead in isolation.
final class PocketNarrationLevelAuditTests: XCTestCase {
    func testApplyProductionLevelsToMeasuredCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard let reports = env["LIBROX_LEVEL_REPORTS"], let destination = env["LIBROX_LEVEL_DELIVERED"] else {
            throw XCTSkip("Opt-in measured corpus delivery audit")
        }
        let output = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var totalSamples = 0, kneeSamples = 0, count = 0
        var seconds = 0.0
        var lookupSeconds = 0.0, firstLookupSeconds = 0.0
        for path in reports.split(separator: ":") {
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: String(path)))) as? [String: Any])
            XCTAssertEqual(report["complete"] as? Bool, true)
            for source in try XCTUnwrap(report["rows"] as? [[String: Any]]) {
                try autoreleasepool {
                    let voiceID = try XCTUnwrap(source["voiceID"] as? String)
                    let style = try XCTUnwrap(PocketTTSDeliveryStyle(rawValue: source["style"] as? String ?? "original"))
                    let data = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(source["pcm"] as? String)))
                    XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), source["sha256"] as? String)
                    XCTAssertEqual(data.count, (source["samples"] as? Int ?? -1) * 4)
                    var samples = [Float](repeating: 0, count: data.count / 4)
                    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                    let lookupStart = ContinuousClock.now
                    let gain = PocketNarrationLevel.gain(voiceID: voiceID, style: style)
                    let lookupDuration = lookupStart.duration(to: .now).components
                    let lookupElapsed = Double(lookupDuration.seconds) + Double(lookupDuration.attoseconds) / 1e18
                    lookupSeconds += lookupElapsed
                    if count == 0 { firstLookupSeconds = lookupElapsed }
                    let affected = gain > 1 ? samples.lazy.filter { abs($0 * gain) > Float(PocketNarrationLevelProfiles.softKnee) }.count : 0
                    let sampleCount = samples.count
                    let start = ContinuousClock.now
                    let delivered = PocketNarrationLevel.apply(consume samples, gain: gain)
                    let duration = start.duration(to: .now).components
                    seconds += Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                    XCTAssertEqual(delivered.count, sampleCount)
                    XCTAssertTrue(delivered.allSatisfy(\.isFinite))
                    let bytes = delivered.withUnsafeBytes { Data($0) }
                    var row = source
                    for field in ["integratedLUFS", "truePeakDBFS", "pcm"] { row.removeValue(forKey: field) }
                    row["rawSHA256"] = source["sha256"]
                    row["sha256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    row["gain"] = gain; row["kneeSamples"] = affected
                    row["levelRevision"] = PocketNarrationLevel.revision
                    let backend = try XCTUnwrap(source["backend"] as? String)
                    let passage = try XCTUnwrap(source["passage"] as? Int)
                    let name = "\(backend)-\(voiceID)-\(style.rawValue)-\(passage)"
                    try bytes.write(to: output.appendingPathComponent(name + ".f32"), options: .atomic)
                    try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                        .write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
                    totalSamples += sampleCount; kneeSamples += affected; count += 1
                }
            }
        }
        let summary: [String: Any] = ["recordings": count, "samples": totalSamples, "kneeSamples": kneeSamples,
            "transformSeconds": seconds, "gainLookupSeconds": lookupSeconds, "firstGainLookupSeconds": firstLookupSeconds,
            "audioSeconds": Double(totalSamples) / 24000,
            "nanosecondsPerSample": seconds * 1e9 / Double(totalSamples), "revision": PocketNarrationLevel.revision]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.receipt"), options: .atomic)
        try Data("complete".utf8).write(to: output.appendingPathComponent("complete.txt"), options: .atomic)
    }
}
