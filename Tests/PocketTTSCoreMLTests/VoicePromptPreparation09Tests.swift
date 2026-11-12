import CoreML
import CryptoKit
import Foundation
import MLX
import XCTest
@testable import PocketTTSCoreML

final class VoicePromptPreparation09Tests: XCTestCase {
    // Frozen 0.8 conversion for the preparation experiment.
    private func decode(_ url: URL) throws -> [MLMultiArray] {
        try Device.withDefaultDevice(.cpu) {
            let arrays = try MLX.loadArrays(url: url)
            var caches: [MLMultiArray] = []
            for i in 0..<6 {
                let prefix = "transformer.layers.\(i).self_attn/"
                guard let kv = arrays[prefix + "cache"], let offset = arrays[prefix + "offset"] else { throw PocketTTSCoreMLEngine.Failure.invalidShape }
                let n = offset.item(Int.self)
                guard kv.ndim == 5, kv.shape[0] == 2, kv.shape[1] == 1, kv.shape[3] == 16, kv.shape[4] == 64,
                      n > 0, n <= kv.shape[2], n <= 512 else { throw PocketTTSCoreMLEngine.Failure.invalidShape }
                for j in 0..<2 {
                    let value = kv[j, 0..., ..<n, 0..., 0...].transposed(0, 2, 1, 3).asType(.float32)
                    caches.append(try PocketTTSCoreMLEngine.floats(value.asArray(Float.self), shape: [1,16,n,64]))
                }
            }
            return caches
        }
    }
    func testVerifiedPromptReuseExperiment() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LIBROX_09_ASSETS"], let output = env["LIBROX_09_PROMPT_OUTPUT"] else { throw XCTSkip("Opt-in preparation measurement") }
        let url = URL(fileURLWithPath:path).appendingPathComponent("en/embeddings/alba.safetensors")
        let reference = try decode(url)
        var rows: [[String:Any]] = []
        for reuse in [false,true,true,false] {
            var digest: SHA256.Digest?, stored: [MLMultiArray]?
            var timings: [Double] = []
            for _ in 0..<21 {
                let start = ProcessInfo.processInfo.systemUptime
                let result: [MLMultiArray]
                if reuse {
                    let hash = SHA256.hash(data:try Data(contentsOf:url))
                    if digest == hash, let stored { result = stored }
                    else { result = try decode(url); digest = hash; stored = result }
                } else { result = try decode(url) }
                timings.append(ProcessInfo.processInfo.systemUptime-start)
                for (a,b) in zip(reference,result) {
                    XCTAssertEqual(a.shape,b.shape)
                    XCTAssertEqual(PocketTTSCoreMLEngine.values(a),PocketTTSCoreMLEngine.values(b))
                }
            }
            rows.append(["reuse":reuse,"coldSeconds":timings[0],"warmMedianSeconds":timings.dropFirst().sorted()[10],
                "retainedPayloadBytes":reuse ? reference.reduce(0){$0+$1.count*4} : 0])
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
    }
}
