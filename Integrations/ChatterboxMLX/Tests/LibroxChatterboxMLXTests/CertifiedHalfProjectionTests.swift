#if os(macOS)
import XCTest
import MLX
@testable import LibroxChatterboxMLX

final class CertifiedHalfProjectionTests: XCTestCase {
    func testExactRounderAndNativeDoubleConversionAtEveryHalfBoundary() throws {
        for raw in 0...65535 {
            let bits = UInt16(raw)
            if bits & 0x7C00 == 0x7C00 {
                XCTAssertThrowsError(try CertifiedHalfProjection.coefficient(bits))
                continue
            }
            let c = try CertifiedHalfProjection.coefficient(bits)
            let expected = bits & 0x7FFF == 0 ? UInt16(0) : bits
            guard CertifiedHalfProjection.roundedHalf(c << 24) == expected,
                Double(c) * 0x1p-24 == Double(Float16(bitPattern: bits)) else {
                XCTFail("finite half inversion: \(bits)"); return
            }
        }
        for raw in 0..<0x7BFF {
            let left = UInt16(raw), right = left + 1
            let l = try CertifiedHalfProjection.coefficient(left) << 24
            let r = try CertifiedHalfProjection.coefficient(right) << 24
            let midpoint = (l + r) / 2
            let even = left & 1 == 0 ? left : right
            for (value, expected) in [(midpoint - 1, left), (midpoint, even), (midpoint + 1, right)] {
                guard CertifiedHalfProjection.roundedHalf(value) == expected,
                    CertifiedHalfProjection.roundedHalf(-value) == expected | 0x8000 else {
                    XCTFail("integer midpoint: \(left)"); return
                }
            }
            let d = (Double(Float16(bitPattern: left)) + Double(Float16(bitPattern: right))) / 2
            guard Float16(d.nextDown).bitPattern == left, Float16(d).bitPattern == even,
                Float16(d.nextUp).bitPattern == right,
                Float16(-d.nextUp).bitPattern == right | 0x8000,
                Float16(-d).bitPattern == even | 0x8000 else {
                XCTFail("binary64 to half midpoint: \(left)"); return
            }
        }
        let overflow = Int128(65520) << 48
        XCTAssertEqual(CertifiedHalfProjection.roundedHalf(overflow - 1), 0x7BFF)
        XCTAssertEqual(CertifiedHalfProjection.roundedHalf(overflow), 0x7C00)
        XCTAssertEqual(CertifiedHalfProjection.roundedHalf(-overflow), 0xFC00)
        XCTAssertEqual(CertifiedHalfProjection.roundedHalf(-1), 0x8000)
        XCTAssertEqual(CertifiedHalfProjection.roundedHalf(0), 0)
    }

    func testCertificateRejectsBoundaryAmbiguityAndExactFallbackResolvesIt() throws {
        XCTAssertEqual(try CertifiedHalfProjection.certificate(sum: 1, k: 1, xMax: 1, wMax: 1), 0x3C00)
        XCTAssertNil(try CertifiedHalfProjection.certificate(sum: 1 + 0x1p-11, k: 2, xMax: 1, wMax: 1))
        XCTAssertEqual(try CertifiedHalfProjection.exact([1, Float16(0x1p-11)], [1, 1], count: 2), 0x3C00)
        XCTAssertNil(try CertifiedHalfProjection.certificate(sum: 0, k: 2, xMax: 1, wMax: 1))
        XCTAssertEqual(try CertifiedHalfProjection.exact([1, -1], [1, 1], count: 2), 0)
        XCTAssertThrowsError(try CertifiedHalfProjection.certificate(sum: .infinity, k: 1, xMax: 1, wMax: 1))
        XCTAssertThrowsError(try CertifiedHalfProjection.certificate(sum: 100, k: 1, xMax: 1, wMax: 1))
        XCTAssertThrowsError(try CertifiedHalfProjection.certificate(sum: 0, k: 1, xMax: 0.1, wMax: 1))
        XCTAssertThrowsError(try CertifiedHalfProjection.exact([.nan], [1], count: 1))
    }

    func testMaximumLengthExactSumsAndSubnormalTies() throws {
        let maximum = [Float16](repeating: 65504, count: 4096)
        XCTAssertEqual(try CertifiedHalfProjection.exact(maximum, maximum, count: 4096), 0x7C00)
        let cancelling = [Float16](repeating: 65504, count: 2048) + [Float16](repeating: -65504, count: 2048)
        XCTAssertEqual(try CertifiedHalfProjection.exact(cancelling, maximum, count: 4096), 0)
        let subnormal = Float16(bitPattern: 1)
        XCTAssertEqual(try CertifiedHalfProjection.exact([subnormal], [1], count: 1), 1)
        XCTAssertEqual(try CertifiedHalfProjection.exact([subnormal], [0.5], count: 1), 0)
        XCTAssertEqual(try CertifiedHalfProjection.exact([-subnormal], [0.5], count: 1), 0x8000)
        XCTAssertEqual(try CertifiedHalfProjection.exact([Float16](repeating: subnormal, count: 4096),
            [Float16](repeating: 1, count: 4096), count: 4096), Float16(0x1p-12).bitPattern)
    }

    func testActualMidpointFallbackKeepsBothEvenRoundingDirections() throws {
        try Device.withDefaultDevice(.cpu) {
            var x = [Float16](repeating: 0, count: 2048)
            x[0] = 1; x[1] = Float16(0x1p-11)
            x[1024] = 1; x[1025] = Float16(3 * 0x1p-11)
            var w = [Float16](repeating: 0, count: 1024 * 1024)
            w[0] = 1; w[1] = 1
            let result = try CertifiedHalfProjection.evaluate(input: MLXArray(x, [2, 1, 1024]),
                weight: MLXArray(w, [1024, 1024]), budget: .init())
            XCTAssertEqual(result.values[0].bitPattern, 0x3C00)
            XCTAssertEqual(result.values[1024].bitPattern, 0x3C02)
            XCTAssertEqual(result.statistics.exactFallback, 2)
            XCTAssertEqual(result.boundaries.map(\.row), [0, 1])
            XCTAssertEqual(result.boundaries.map(\.column), [0, 0])
            XCTAssertEqual(result.boundaries.map(\.exactHalfBits), [0x3C00, 0x3C02])
        }
    }

    func testActualFP64BackendAndConservativeFallbackPreserveCancellation() throws {
        try Device.withDefaultDevice(.cpu) {
            var x = [Float16](repeating: 0, count: 2048)
            for offset in [0, 1024] { x[offset] = 65504; x[offset + 1] = 1; x[offset + 2] = -65504 }
            var w = [Float16](repeating: 0, count: 1024 * 1024)
            w[0] = 65504; w[1] = 1; w[2] = 65504
            let input = MLXArray(x, [2, 1, 1024]), weight = MLXArray(w, [1024, 1024])
            let raw = matmul(input.asType(.float64), weight.asType(.float64).T)
            XCTAssertEqual(raw.dtype, .float64)
            XCTAssertEqual(raw.asArray(Double.self)[0], 1)
            let result = try CertifiedHalfProjection.evaluate(input: input, weight: weight, budget: .init())
            XCTAssertEqual(result.values[0], 1)
            XCTAssertEqual(result.values[1024], 1)
            XCTAssertEqual(result.statistics.exactFallback, 2)
            XCTAssertEqual(result.statistics.outputs, 2048)
            x[2] = 65504
            XCTAssertThrowsError(try CertifiedHalfProjection.evaluate(input: MLXArray(x, [2, 1, 1024]),
                weight: weight, budget: .init()))
        }
    }

    func testFP64InputAndWeightConversionsPreserveHalfSubnormals() throws {
        try Device.withDefaultDevice(.cpu) {
            let tiny = Float16(bitPattern: 1)
            var x = [Float16](repeating: 0, count: 2048)
            for offset in [0, 1024] { x[offset] = tiny; x[offset + 1] = 1 }
            var w = [Float16](repeating: 0, count: 1024 * 1024)
            w[0] = 1; w[1] = tiny
            let input = MLXArray(x, [2, 1, 1024]), weight = MLXArray(w, [1024, 1024])
            let raw = matmul(input.asType(.float64), weight.asType(.float64).T)
            XCTAssertEqual(raw.asArray(Double.self)[0], 0x1p-23)
            let result = try CertifiedHalfProjection.evaluate(input: input, weight: weight, budget: .init())
            XCTAssertEqual(result.values[0].bitPattern, 2)
            XCTAssertEqual(result.values[1024].bitPattern, 2)
            XCTAssertEqual(result.statistics.exactFallback, 0)
        }
    }
}
#endif
