#if os(macOS)
import Foundation
import XCTest
import MLX
@testable import LibroxChatterboxMLX

final class SemanticHalfRoPETests: XCTestCase {
    func testCorruptedOrTruncatedTablesFailClosed() throws {
        let original = try SemanticHalfRoPE.bundledBytes()
        XCTAssertThrowsError(try SemanticHalfRoPE(data: original.dropLast()))
        var changed = original; changed[128] ^= 1
        XCTAssertThrowsError(try SemanticHalfRoPE(data: changed))
    }
    func testAllPositionsAndBothLanesMatchIndependentHalfBoundaries() throws {
        let data = try SemanticHalfRoPE.bundledBytes()
        func table(_ offset: Int) -> [Float16] {
            data.withUnsafeBytes { raw in (0..<49152).map {
                Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + $0 * 2, as: UInt16.self)))
            } }
        }
        let c = table(128), s = table(128 + 49152 * 2)
        let x: [Float16] = (0..<(2 * 1536 * 64)).map { Float16(Float($0 % 257 - 128) / 128) }
        var expected = [Float16](repeating: 0, count: x.count)
        for lane in 0..<2 { for row in 0..<1536 { for d in 0..<32 {
            let i = (lane * 1536 + row) * 64 + d
            let result = try IndependentReferenceBackbone.rotate(Float(x[i]), Float(x[i + 32]),
                cosine: c[row * 32 + d], sine: s[row * 32 + d])
            expected[i] = Float16(result.0); expected[i + 32] = Float16(result.1)
        } } }
        try Device.withDefaultDevice(.gpu) {
            let rope = try SemanticHalfRoPE(data: data)
            let output = rope(MLXArray(x, [2, 1, 1536, 64]), offset: 0)
            eval(output)
            XCTAssertEqual(output.asArray(Float16.self).map(\.bitPattern), expected.map(\.bitPattern))
            // Nonzero offsets exercise slicing, including the independently
            // audited position494 and the final permitted context position.
            let start = 491, rows = 1045
            let suffix = (0..<2).flatMap { lane in Array(x[((lane * 1536 + start) * 64)..<((lane + 1) * 1536 * 64)]) }
            let wanted = (0..<2).flatMap { lane in Array(expected[((lane * 1536 + start) * 64)..<((lane + 1) * 1536 * 64)]) }
            let partial = rope(MLXArray(suffix, [2, 1, rows, 64]), offset: start); eval(partial)
            XCTAssertEqual(partial.asArray(Float16.self).map(\.bitPattern), wanted.map(\.bitPattern))
        }
    }
}
#endif
