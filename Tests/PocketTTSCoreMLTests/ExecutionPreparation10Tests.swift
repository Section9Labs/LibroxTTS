import CoreML
import Foundation
import MLX
import XCTest
@testable import PocketTTSCoreML

final class ExecutionPreparation10Tests: XCTestCase {
    func testGenericSchedulesKeepOriginalFloatConversion() throws {
        let workspace = PocketPredictionWorkspace()
        for steps in 1...8 {
            let schedule = try workspace.schedule(steps)
            for i in 0..<steps {
                XCTAssertEqual(schedule[i]["s"]![0].floatValue.bitPattern, Float(Double(i)/Double(steps)).bitPattern)
                XCTAssertEqual(schedule[i]["t"]![0].floatValue.bitPattern, Float(Double(i+1)/Double(steps)).bitPattern)
                XCTAssertEqual(schedule[i]["steps"]![0].floatValue, Float(steps))
            }
        }
    }
    func testNativePromptBytesMatchMLXForEveryInstalledVoice() throws {
        guard let root = ProcessInfo.processInfo.environment["LIBROX_09_ASSETS"] else { throw XCTSkip("Requires installed voice fixtures") }
        for language in ["en", "es"] {
            let directory = URL(fileURLWithPath: root).appendingPathComponent(language + "/embeddings")
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "safetensors" {
                let native = try XCTUnwrap(PocketVoiceArchive.read(url))
                try Device.withDefaultDevice(.cpu) {
                    let arrays = try MLX.loadArrays(url: url)
                    for i in 0..<6 {
                        let prefix = "transformer.layers.\(i).self_attn/"
                        let kv = try XCTUnwrap(arrays[prefix + "cache"]), count = try XCTUnwrap(arrays[prefix + "offset"]).item(Int.self)
                        for j in 0..<2 {
                            let old = kv[j,0...,..<count,0...,0...].transposed(0,2,1,3).asType(.float32).asArray(Float.self)
                            XCTAssertEqual(PocketTTSCoreMLEngine.values(native[i*2+j]).map(\.bitPattern), old.map(\.bitPattern), url.lastPathComponent)
                        }
                    }
                }
            }
        }
    }
    func testUnsupportedArchiveRetainsFallback() throws {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for bytes in [Data(), Data(repeating: 255, count: 32), Data("bad data".utf8)] {
            try bytes.write(to: url)
            XCTAssertNil(try PocketVoiceArchive.read(url))
        }
    }
}
