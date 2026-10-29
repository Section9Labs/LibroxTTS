#if os(macOS)
import XCTest
import MLX
import MLXFast
import MLXNN
@testable import LibroxChatterboxMLX

final class DiagnosticArithmeticTests: XCTestCase {
    private func fixture(_ shape: [Int]) -> MLXArray {
        MLXArray((0..<shape.reduce(1, *)).map { Float(($0 % 31) - 15) / 19 }, shape)
    }

    func testExplicitNormMatchesCPUFallbackWithNonuniformWeights() throws {
        try Device.withDefaultDevice(.cpu) {
            let layer = RMSNorm(dimensions: 64, eps: 0.00001)
            try layer.update(parameters: ModuleParameters.unflattened([
                ("weight", MLXArray((0..<64).map { Float($0 + 1) / 37 }))]), verify: .all)
            let input = fixture([2, 5, 64])
            let expected = layer(input), actual = DiagnosticArithmetic.norm(input, layer)
            XCTAssertEqual(actual.asArray(Float.self).map(\.bitPattern), expected.asArray(Float.self).map(\.bitPattern))
        }
    }

    func testMaterializedAttentionMatchesCPUForCausalPrefillAndSingleDecode() {
        Device.withDefaultDevice(.cpu) {
            for (qLength, kLength) in [(5, 5), (1, 8)] {
                let q = fixture([2, 16, qLength, 64]), k = fixture([2, 16, kLength, 64])
                let v = fixture([2, 16, kLength, 64]) * 0.3
                let expected = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v,
                    scale: 0.125, mask: qLength > 1 ? .causal : .none)
                let actual = DiagnosticArithmetic.attention(queries: q, keys: k, values: v, scale: 0.125)
                XCTAssertEqual(actual.asArray(Float.self).map(\.bitPattern), expected.asArray(Float.self).map(\.bitPattern))
            }
        }
    }

    func testHalfRotationTableMatchesCPUFallbackAtEverySupportedPosition() {
        Device.withDefaultDevice(.cpu) {
            let frequencies = (0..<32).map { Float($0 + 1) * 1.75 }
            let tables = DiagnosticHalfRoPE.makeCPUTables(frequencies: frequencies, capacity: 1536)
            let rotation = DiagnosticHalfRoPE(cosines: MLXArray(tables.0, [1536, 32]),
                sines: MLXArray(tables.1, [1536, 32]))
            let input = fixture([1, 1, 1536, 64]).asType(.float16)
            let expected = MLXFast.RoPE(input, dimensions: 64, traditional: false,
                base: nil, scale: 1, offset: 0, freqs: MLXArray(frequencies))
            XCTAssertEqual(rotation(input, offset: 0).asArray(Float16.self).map(\.bitPattern),
                expected.asArray(Float16.self).map(\.bitPattern))
        }
    }

    func testFixedFixtureRejectsMissingExtraNonfiniteAndNonpositiveInputs() throws {
        try Device.withDefaultDevice(.cpu) {
            var arrays: [String: MLXArray] = [
                "rope.cosines": MLXArray.ones([1536, 32], dtype: .float16),
                "rope.sines": MLXArray.zeros([1536, 32], dtype: .float16)]
            let tiny = MLXArray.ones([2, 16, 1, 64], dtype: .float16)
            let history = MLXArray.ones([2, 16, 95, 64], dtype: .float16)
            for i in 0..<60 {
                arrays["rope.\(i).input"] = tiny; arrays["rope.\(i).output"] = tiny
                arrays["rope.\(i).frequencies"] = MLXArray.ones([32])
            }
            for i in 0..<30 { arrays["layer.\(i).keys"] = history; arrays["layer.\(i).values"] = history }
            try DiagnosticRoPEFixture.validate(arrays)
            var invalid = arrays; invalid.removeValue(forKey: "rope.0.input")
            XCTAssertThrowsError(try DiagnosticRoPEFixture.validate(invalid))
            invalid = arrays; invalid["extra"] = tiny
            XCTAssertThrowsError(try DiagnosticRoPEFixture.validate(invalid))
            invalid = arrays; invalid["rope.0.input"] = tiny * Float.nan
            XCTAssertThrowsError(try DiagnosticRoPEFixture.validate(invalid))
            invalid = arrays; invalid["rope.0.frequencies"] = MLXArray.zeros([32])
            XCTAssertThrowsError(try DiagnosticRoPEFixture.validate(invalid))
        }
    }
}
#endif
