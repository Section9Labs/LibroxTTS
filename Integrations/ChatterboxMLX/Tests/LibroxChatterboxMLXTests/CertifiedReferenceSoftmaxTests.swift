#if os(macOS)
import XCTest
@testable import LibroxChatterboxMLX

final class CertifiedReferenceSoftmaxTests: XCTestCase {
    func testPolynomialBoundsAndRejectedDomain() throws {
        for x: Double in [-256, -200, -50, -10, -1, -0.125, -Double(Float.leastNonzeroMagnitude), 0] {
            let bounds = try CertifiedReferenceSoftmax.exponential(.init(x))
            let crossCheck = Foundation.exp(x)
            XCTAssertLessThanOrEqual(bounds.low, crossCheck)
            XCTAssertGreaterThanOrEqual(bounds.high, crossCheck)
        }
        XCTAssertThrowsError(try CertifiedReferenceSoftmax.exponential(.init(-257)))
        XCTAssertThrowsError(try CertifiedReferenceSoftmax.exponential(.init(1)))
    }
    func testStableSoftmaxAndNoSilentApproximation() throws {
        XCTAssertEqual(try CertifiedReferenceSoftmax.probabilities([0, 0, 0, 0]).values, [0.25, 0.25, 0.25, 0.25])
        XCTAssertEqual(try CertifiedReferenceSoftmax.probabilities([1000, 0]).values, [1, 0])
        XCTAssertEqual(try CertifiedReferenceSoftmax.probabilities([200, 200, -200]).values, [0.5, 0.5, 0])
        let nearMidpoint = try CertifiedReferenceSoftmax.probabilities([0, 0x1p-23])
        XCTAssertNil(nearMidpoint.values)
        XCTAssertGreaterThan(nearMidpoint.unresolvedComponents, 0)
        XCTAssertThrowsError(try CertifiedReferenceSoftmax.probabilities([]))
        XCTAssertThrowsError(try CertifiedReferenceSoftmax.probabilities([.nan]))
    }
    func testTwoSumContainsExactDifferencesForF32Range() {
        // Exact reals are -1±2^-149, although naive Double subtraction gives-1.
        // These explicit endpoints fail if the residual is dropped or reversed.
        let below = CertifiedReferenceSoftmax.difference(-Float.leastNonzeroMagnitude, maximum: 1)
        XCTAssertEqual(below.low, (-Double(1)).nextDown)
        XCTAssertEqual(below.high, -1)
        let above = CertifiedReferenceSoftmax.difference(Float.leastNonzeroMagnitude, maximum: 1)
        XCTAssertEqual(above.low, -1)
        XCTAssertEqual(above.high, (-Double(1)).nextUp)
        for (a, b): (Float, Float) in [(-1, 1), (-Float.leastNonzeroMagnitude, 1),
            (-Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude), (0, 0)] {
            let bounds = CertifiedReferenceSoftmax.difference(a, maximum: b)
            XCTAssertLessThanOrEqual(bounds.low, Double(a) - Double(b))
            XCTAssertGreaterThanOrEqual(bounds.high, Double(a) - Double(b))
            XCTAssertLessThanOrEqual(bounds.high, 0)
        }
    }
}
#endif
