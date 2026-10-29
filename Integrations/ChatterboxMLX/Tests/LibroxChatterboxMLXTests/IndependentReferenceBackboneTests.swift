#if os(macOS)
import XCTest
import Foundation
import CryptoKit
import MLX
@testable import LibroxChatterboxMLX

final class IndependentReferenceBackboneTests: XCTestCase {
    func testQ8ByteOrderRowsAndGroups() throws {
        let packed = Data((0..<256).map { UInt8(($0 * 37 + 11) % 256) })
        let scales: [Float16] = [0.25, 0.5, 0.125, 0.0625], biases: [Float16] = [-1, 2, 4, -8]
        func bytes(_ x: [Float16]) -> Data {
            var result = Data()
            for f in x { var b = f.bitPattern.littleEndian; withUnsafeBytes(of: &b) { result.append(contentsOf: $0) } }
            return result
        }
        let actual = try ReferenceQ8Reconstruction.decode(packed: packed, scales: bytes(scales), biases: bytes(biases),
            rows: 2, columns: 128, budget: .init())
        var wanted: [Float] = []
        for i in 0..<256 {
            let q = Float((i * 37 + 11) % 256)
            let product: Float = q * Float(scales[i / 64])
            let sum: Float = product + Float(biases[i / 64])
            wanted.append(Float(Float16(sum)))
        }
        XCTAssertEqual(actual.map(\.bitPattern), wanted.map(\.bitPattern))
        XCTAssertThrowsError(try ReferenceQ8Reconstruction.decode(packed: packed.dropLast(), scales: bytes(scales), biases: bytes(biases),
            rows: 2, columns: 128, budget: .init()))
    }
    func testCausalMaskExcludesFutureAtNonzeroOffset() throws {
        let result = try ReferenceCausalProbabilities.make([0, 0, 0, 1000, 0, 0, 0, 0],
            rows: 2, total: 4, incomingOffset: 2, budget: .init(), resolve: { _ in
                XCTFail("These ordinary equal-score rows should certify"); return []
            })
        XCTAssertEqual(result.map(\.bitPattern), [Float](repeating: 1 / 3, count: 3).map(\.bitPattern) + [0] +
            [Float](repeating: 0.25, count: 4).map(\.bitPattern))
    }
    func testFailurePoisonsTrajectoryEvenAfterAllAppends() throws {
        for failureIndex in [0, 15, 30, 31] {
            let lifetime = ReferenceForwardLifetime()
            var appended = 0, accepted = false
            XCTAssertThrowsError(try lifetime.run {
                for index in 0..<32 {
                    if index == failureIndex { throw CancellationError() }
                    if index < 30 { appended += 1 }
                }
                accepted = true
            })
            XCTAssertEqual(appended, min(failureIndex, 30)); XCTAssertFalse(accepted)
            XCTAssertThrowsError(try lifetime.requireValid())
            XCTAssertThrowsError(try lifetime.run { XCTFail("Poisoned trajectory executed work") })
        }
    }
    func testPinnedTableReadsExactBytesAndRejectsSizeAndHashChanges() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data([0, 1, 2, 3]); try data.write(to: file)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ReferencePinnedBytes.load(file, count: 4, sha256: hash, budget: .init()), data)
        try Data([0, 1, 2, 4]).write(to: file)
        XCTAssertThrowsError(try ReferencePinnedBytes.load(file, count: 4, sha256: hash, budget: .init()))
        try Data(repeating: 0, count: 1024).write(to: file)
        XCTAssertThrowsError(try ReferencePinnedBytes.load(file, count: 4, sha256: hash, budget: .init()))
    }
    func testHalfCacheBoundaryAndSnapshotAreIndependent() throws {
        let cache = IndependentReferenceBackbone.Cache(), budget = CertifiedHalfProjection.Budget()
        let prefix = (0..<(32 * 255 * 64)).map { Float(Float16(Float($0 % 31 - 15) / 16)) }
        try cache.append(keys: prefix, values: prefix, rows: 255, offset: 0, budget: budget)
        let before = try cache.snapshot()
        let tail = (0..<(32 * 2 * 64)).map { Float(Float16(Float($0 % 13 - 6) / 8)) }
        try cache.append(keys: tail, values: tail, rows: 2, offset: 255, budget: budget)
        let after = try cache.snapshot()
        XCTAssertEqual(cache.length, 257)
        for head in 0..<32 {
            XCTAssertEqual(Array(after.keys[(head * 257 * 64)..<(head * 257 * 64 + 255 * 64)]).map(\.bitPattern),
                Array(before.keys[(head * 255 * 64)..<((head + 1) * 255 * 64)]).map(\.bitPattern))
            XCTAssertEqual(Array(after.values[(head * 257 * 64 + 255 * 64)..<((head + 1) * 257 * 64)]).map(\.bitPattern),
                Array(tail[(head * 2 * 64)..<((head + 1) * 2 * 64)]).map { Float16($0).bitPattern })
        }
        XCTAssertThrowsError(try cache.append(keys: tail, values: tail, rows: 2, offset: 255, budget: budget))
    }
    func testSummaryFlagsAndAValidRawFileCannotReplaceMissingBoundaryEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let names = ["prefill"] + (0..<8).map { "decode.\($0)" }
        let values = [Float](repeating: 0, count: 16388), hash = ReferenceCacheEvidence.hash(values)
        var arrays: [String: MLXArray] = [:]
        for mode in ["original", "traced", "eager"] { for name in names { arrays[mode + "." + name] = MLXArray(values, [2, 8194]) } }
        let raw = directory.appendingPathComponent("control-logits.safetensors")
        try save(arrays: arrays, url: raw, stream: .cpu)
        let rawHash = try ChatterboxMLXRenderer.digest(raw)
        let conditions: [[String: Any]] = names.enumerated().map { index, name in
            ["name": name, "logits_sha256": hash, "cache": (0..<30).map { layer in
                ["layer": layer, "offset": 80 + index, "capacity": 256, "keys_sha256": hash, "values_sha256": hash] as [String: Any]
            }]
        }
        let arms: [[String: Any]] = ["original", "traced", "eager"].map { mode in
            ["mode": mode, "conditions": conditions,
             "trace": mode == "original" ? [] : names.map { ["name": $0, "boundaries": [:]] as [String: Any] }]
        }
        let report: [String: Any] = ["completed": true, "mode": "cpu-original-trace-eager-control", "case": "en-short",
            "conditions": 9, "input_vectors_sha256": ReferenceAssemblyInputs.sha256,
            "all_trace_boundaries_bit_identical": true, "all_original_traced_eager_logits_caches_bit_identical": true,
            "old22_bit_identical": false, "raw_sha256": rawHash, "arms": arms]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let file = directory.appendingPathComponent("report.json"); try data.write(to: file)
        let reportHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try AssemblyControlGate.verify(file, sha256: reportHash, caseID: "en-short", oracle: nil, budget: .init()))
        XCTAssertThrowsError(try AssemblyControlGate.verify(file, sha256: String(repeating: "0", count: 64), caseID: "en-short", oracle: nil, budget: .init()))
    }
}
#endif
