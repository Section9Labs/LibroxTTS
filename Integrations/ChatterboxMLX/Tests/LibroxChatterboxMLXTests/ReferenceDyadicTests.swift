#if os(macOS)
import XCTest
import Foundation
@testable import LibroxChatterboxMLX

final class ReferenceDyadicTests: XCTestCase {
    func testFiniteHalfEncodingsAndMidpointRounding() throws {
        for b in UInt32(0)..<65536 where b & 0x7C00 != 0x7C00 {
            let value = Float(Float16(bitPattern: UInt16(b)))
            let t = try ReferenceDyadic.term(value)
            let round = ReferenceDyadic.rounded(t.coefficient, exponent: t.exponent, output: .f16)
            XCTAssertEqual(round, value == 0 ? 0 : b)
        }
        for b in UInt16(0)..<0x7BFF {
            let a = Double(Float16(bitPattern: b)), c = Double(Float16(bitPattern: b + 1))
            let midpoint = Float((a + c) / 2)
            for probe in [midpoint.nextDown, midpoint, midpoint.nextUp] {
                let t = try ReferenceDyadic.term(probe)
                XCTAssertEqual(ReferenceDyadic.rounded(t.coefficient, exponent: t.exponent, output: .f16),
                               UInt32(Float16(Double(probe)).bitPattern))
                XCTAssertEqual(ReferenceDyadic.rounded(-t.coefficient, exponent: t.exponent, output: .f16),
                               UInt32(Float16(-Double(probe)).bitPattern))
            }
        }
        let overflow = try ReferenceDyadic.term(65520)
        XCTAssertEqual(ReferenceDyadic.rounded(overflow.coefficient, exponent: overflow.exponent, output: .f16), 0x7C00)
    }
    func testF32BoundariesAndOverwideReductionFailsBeforeShift() throws {
        for b: UInt32 in [1, 0x007FFFFF, 0x00800000, 0x3F7FFFFF, 0x3F800000, 0x7F7FFFFF, 0x80000001] {
            let t = try ReferenceDyadic.term(Float(bitPattern: b))
            XCTAssertEqual(ReferenceDyadic.rounded(t.coefficient, exponent: t.exponent, output: .f32), b)
        }
        let x: [Float] = [.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude]
        XCTAssertThrowsError(try ReferenceDyadic.dot(x[...], [Float](repeating: 1, count: 3)[...], output: .f32)) { error in
            guard case ReferenceDyadic.Failure.span = error else { return XCTFail("Wrong failure: \(error)") }
        }
    }
    func testInverseRootExactSpecialCasesAndDomain() throws {
        for (x, expected): (Float, Float) in [(1, 1), (4, 0.5), (0.25, 2), (16, 0.25), (0x1p-126, 0x1p63)] {
            XCTAssertEqual(try ReferenceDyadic.inverseRoot(x), expected)
        }
        XCTAssertThrowsError(try ReferenceDyadic.inverseRoot(0))
        XCTAssertThrowsError(try ReferenceDyadic.inverseRoot(-1))
    }
    func testNonPowerOfTwoGEMMAndFailurePropagation() throws {
        let b = CertifiedHalfProjection.Budget()
        let statistics = CertifiedReferenceMatrix.Statistics()
        let w = try CertifiedReferenceMatrix.prepare([Float](repeating: 0.25, count: 96), rows: 1, columns: 96, budget: b)
        let result = try CertifiedReferenceMatrix.multiply([Float](repeating: 0.5, count: 96), rows: 1, weight: w,
            output: .f32, budget: b, statistics: statistics, resolver: { _ in XCTFail("Unexpected fallback"); return [] })
        XCTAssertEqual(result, [12])
        // The assembled decoder's projection branch requests F16, unlike the
        // 182 F32 operator outputs. Cover that branch at real projection K and
        // a non-power-of-two K against the older independent integer helper.
        for k in [96, 1024, 1536, 4096] {
            let hx = (0..<(3 * k)).map { Float16(Float($0 % 17 - 8) / 16) }
            let hw = (0..<(2 * k)).map { Float16(Float($0 % 13 - 6) / 8) }
            let prepared = try CertifiedReferenceMatrix.prepare(hw.map(Float.init), rows: 2, columns: k, budget: b)
            let y = try CertifiedReferenceMatrix.multiply(hx.map(Float.init), rows: 3, weight: prepared, output: .f16,
                budget: b, statistics: statistics, resolver: { _ in XCTFail("Unexpected wide half reduction"); return [] })
            for row in 0..<3 { for column in 0..<2 {
                let expected = try CertifiedHalfProjection.exact(hx, hw, xOffset: row * k, wOffset: column * k, count: k)
                XCTAssertEqual(Float16(y[row * 2 + column]).bitPattern, expected)
            } }
        }
        let tiny: [Float] = [.leastNonzeroMagnitude]
        let t = try CertifiedReferenceMatrix.prepare([1], rows: 1, columns: 1, budget: b)
        XCTAssertEqual(try CertifiedReferenceMatrix.multiply(tiny, rows: 1, weight: t, output: .f32,
            budget: b, statistics: statistics, resolver: { _ in throw NSError(domain: "unexpected", code: 1) }), tiny)
        let wide = try CertifiedReferenceMatrix.prepare([1, 1, 1], rows: 1, columns: 3, budget: b)
        var called = false
        XCTAssertThrowsError(try CertifiedReferenceMatrix.multiply([.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude],
            rows: 1, weight: wide, output: .f32, budget: b, statistics: statistics, resolver: { _ in
                called = true; throw NSError(domain: "forced exact resolver failure", code: 1)
            }))
        XCTAssertTrue(called)
    }
    func testCancelledTaskReturnsNoNorm() async {
        let accepted = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try CertifiedReferenceMatrix.norm([Float](repeating: 1, count: 1024), weights: [Float](repeating: 1, count: 1024),
                    budget: .init(), statistics: .init(), resolver: { _ in [] })
                return true
            } catch { return false }
        }.value
        XCTAssertFalse(accepted)
    }
}
#endif
