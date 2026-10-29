import CoreML
import Testing
@testable import ChatterboxCoreML

@Test func reusableAcousticInputPreservesFloatBitsAndRejectsWrongContracts() throws {
    let initial: [Float] = [0, -0.0, 0.1, -0.2, .leastNonzeroMagnitude, 123.5]
    let array = try MLMultiArray.float32(initial, shape: [1, 2, 3])
    let updated = initial.reversed().map { $0 }
    try array.replaceContiguousFloat32(with: updated)
    #expect(array.toFloatArray().map(\.bitPattern) == updated.map(\.bitPattern))
    #expect(throws: ChatterboxError.self) { try array.replaceContiguousFloat32(with: [1]) }
    let integers = try MLMultiArray.int32([1, 2], shape: [1, 2])
    #expect(throws: ChatterboxError.self) { try integers.replaceContiguousFloat32(with: [1, 2]) }
}
