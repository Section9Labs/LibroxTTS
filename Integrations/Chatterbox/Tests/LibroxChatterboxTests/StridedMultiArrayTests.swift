import Foundation
import CoreML
import Testing
@testable import ChatterboxCoreML

private func paddedArray(_ type: MLMultiArrayDataType, transposed: Bool = false) throws -> MLMultiArray {
    let width = type == .float16 ? 2 : type == .float32 ? 4 : 8
    let values: [Float] = transposed ? [11, 21, -0.0, 22, 13, 23] : [11, -0.0, 13, -99, -99, 21, 22, 23, -99, -99, -99, -99]
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: values.count * width, alignment: 16)
    for i in values.indices {
        switch type {
        case .float16: pointer.storeBytes(of: Float16(values[i]), toByteOffset: i * width, as: Float16.self)
        case .double: pointer.storeBytes(of: Double(values[i]), toByteOffset: i * width, as: Double.self)
        default: pointer.storeBytes(of: values[i], toByteOffset: i * width, as: Float.self)
        }
    }
    do {
        return try MLMultiArray(dataPointer: pointer, shape: [1, 2, 3], dataType: type,
            strides: transposed ? [6, 1, 2] : [12, 5, 1], deallocator: { $0.deallocate() })
    } catch { pointer.deallocate(); throw error }
}

@Test func stridedFloatReadMatchesMultidimensionalFrameworkControl() throws {
    for type in [MLMultiArrayDataType.float16, .float32, .double] {
        for transposed in [false, true] {
            let array = try paddedArray(type, transposed: transposed)
            let expected = (0..<2).flatMap { row in (0..<3).map { column in
                array[[0, NSNumber(value: row), NSNumber(value: column)]].floatValue
            } }
            #expect(try array.toFloatArrayAnyPrecision().map(\.bitPattern) == expected.map(\.bitPattern))
            if type == .float32 { #expect(try array.toFloatArray().map(\.bitPattern) == expected.map(\.bitPattern)) }
        }
    }
}

@Test func contiguousFloatCopyPreservesAllBitsWithoutChangingPrecision() throws {
    let values: [Float] = [0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
        0.125, -3.5, Float(bitPattern: 0x7fc12345), Float(bitPattern: 0xffc54321)]
    let array = try MLMultiArray.float32(values, shape: [1, 2, 4])
    #expect(try array.toFloatArray().map(\.bitPattern) == values.map(\.bitPattern))
    #expect(try array.toFloatArrayAnyPrecision().map(\.bitPattern) == values.map(\.bitPattern))
}

@Test func stridedReusableWriteEitherUsesCurrentPackedStorageOrRejectsWithoutCorruption() throws {
    let array = try paddedArray(.float32)
    let before = try array.toFloatArray()
    let replacement: [Float] = [1, 2, 3, 4, 5, 6]
    do {
        try array.replaceContiguousFloat32(with: replacement)
        #expect(try array.toFloatArray().map(\.bitPattern) == replacement.map(\.bitPattern))
    } catch ChatterboxError.invalidModelOutput(let reason) {
        #expect(reason == "Noncontiguous reusable input")
        #expect(try array.toFloatArray().map(\.bitPattern) == before.map(\.bitPattern))
    }
}

@Test func wrongInputCountsAndNonfloatingReadsFailBeforeUnsafeAccess() throws {
    #expect(throws: ChatterboxError.self) { try MLMultiArray.float32([1], shape: [2]) }
    #expect(throws: ChatterboxError.self) { try MLMultiArray.float16([1], shape: [2]) }
    #expect(throws: ChatterboxError.self) { try MLMultiArray.int32([1], shape: [2]) }
    let integers = try MLMultiArray.int32([1, 2], shape: [2])
    #expect(throws: ChatterboxError.self) { try integers.toFloatArrayAnyPrecision() }
}

@Test func malformedAndHugeShapesRejectBeforeFrameworkAllocationOrFloat16Conversion() throws {
    for shape in [[0, 2], [-1, 2], [Int.max], [Int.max, 2], [2, Int.max], []] {
        let values: [Float] = shape.isEmpty ? [] : [1]
        #expect(throws: ChatterboxError.self) { try MLMultiArray.float32(values, shape: shape) }
        #expect(throws: ChatterboxError.self) { try MLMultiArray.float16(values, shape: shape) }
        #expect(throws: ChatterboxError.self) { try MLMultiArray.int32(values.map { Int32($0) }, shape: shape) }
    }
}
