import Foundation
import Testing
@testable import LibroxCTNative

private func carryTensor(_ value: Float, length: Int = 8) throws -> CTTensor {
    try CTTensor([Float](repeating: value, count: 256 * length), shape: [1, 256, length])
}

@Test func contextCarryUsesOnlyContextDifferenceWithFixedTaper() throws {
    let result = try CTContextCarry.prepare(contextual: carryTensor(5), reference: carryTensor(2),
        late: carryTensor(10), mode: .linearTwoStep)
    #expect(try result.residual.floats().allSatisfy { $0 == 3 })
    #expect(try result.step3.floats().allSatisfy { $0 == 12 })
    #expect(try result.step4.floats().allSatisfy { $0 == 11 })
}

@Test func contextCarryZeroControlAndZeroDifferenceKeepLateBytes() throws {
    let zeros = (0..<2048).map { $0.isMultiple(of: 2) ? Float.zero : -Float.zero }
    let late = try CTTensor(zeros, shape: [1, 256, 8])
    let zeroControl = try CTContextCarry.prepare(contextual: carryTensor(5), reference: carryTensor(2),
        late: late, mode: .zeroControl)
    let zeroDifference = try CTContextCarry.prepare(contextual: carryTensor(5), reference: carryTensor(5),
        late: late, mode: .linearTwoStep)
    for prepared in [zeroControl, zeroDifference] {
        #expect(prepared.step3.data == late.data)
        #expect(prepared.step4.data == late.data)
    }
}

@Test func contextCarryRejectsShapeNonfiniteAndOverflow() throws {
    #expect(throws: CTError.self) { try CTContextCarry.prepare(contextual: carryTensor(1),
        reference: carryTensor(1, length: 9), late: carryTensor(1), mode: .linearTwoStep) }
    #expect(throws: CTError.self) { try CTContextCarry.prepare(contextual: carryTensor(.nan),
        reference: carryTensor(1), late: carryTensor(1), mode: .linearTwoStep) }
    #expect(throws: CTError.self) { try CTContextCarry.prepare(contextual: carryTensor(.greatestFiniteMagnitude),
        reference: carryTensor(-Float.greatestFiniteMagnitude), late: carryTensor(1), mode: .zeroControl) }
}
