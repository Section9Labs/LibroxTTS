import Foundation
import CoreML

/// Coordinates are logical C-order; storage may contain padding or broadcasts.
/// Construct this only while the Core ML buffer is locked, using current strides
/// (or the mutable-access closure's supplied strides), never cached metadata.
private struct CheckedMultiArrayLayout {
    let shape: [Int], strides: [Int], count: Int, contiguous: Bool
    init(shape: [Int], strides: [Int], count: Int, width: Int, bytes: Int) throws {
        guard count > 0, width > 0, shape.count == strides.count,
            shape.allSatisfy({ $0 > 0 }), strides.allSatisfy({ $0 >= 0 }) else {
            throw ChatterboxError.invalidModelOutput("Invalid multiarray layout")
        }
        var product = 1, last = 0
        for (dimension, stride) in zip(shape, strides) {
            let (n, overflow) = product.multipliedReportingOverflow(by: dimension)
            let (tail, tailOverflow) = (dimension - 1).multipliedReportingOverflow(by: stride)
            let (end, endOverflow) = last.addingReportingOverflow(tail)
            guard !overflow, !tailOverflow, !endOverflow else {
                throw ChatterboxError.invalidModelOutput("Multiarray layout overflow")
            }
            product = n; last = end
        }
        let (extent, extentOverflow) = last.addingReportingOverflow(1)
        let (required, byteOverflow) = extent.multipliedReportingOverflow(by: width)
        guard product == count, !extentOverflow, !byteOverflow, required <= bytes else {
            throw ChatterboxError.invalidModelOutput("Multiarray storage does not cover its logical shape")
        }
        var expected = 1, packed = true
        for axis in shape.indices.reversed() {
            if shape[axis] > 1 && strides[axis] != expected { packed = false }
            expected *= shape[axis] // The complete product was checked above.
        }
        self.shape = shape; self.strides = strides; self.count = count; contiguous = packed
    }
    func forEach(_ body: (Int, Int) -> Void) {
        if contiguous { for index in 0..<count { body(index, index) }; return }
        var coordinates = [Int](repeating: 0, count: shape.count), offset = 0
        for index in 0..<count {
            body(index, offset)
            for axis in shape.indices.reversed() {
                if coordinates[axis] + 1 < shape[axis] {
                    coordinates[axis] += 1; offset += strides[axis]; break
                }
                offset -= coordinates[axis] * strides[axis]
                coordinates[axis] = 0
            }
        }
    }
}

extension MLMultiArray {
    /// Reuses an owned synchronous-prediction input. Check the storage presented
    /// by this access, since Core ML may change backing storage on mutable access.
    func replaceContiguousFloat32(with values: [Float]) throws {
        guard dataType == .float32, count == values.count else {
            throw ChatterboxError.invalidModelOutput("Reusable input type/count mismatch")
        }
        try withUnsafeMutableBytes { raw, currentStrides in
            let layout = try CheckedMultiArrayLayout(shape: shape.map(\.intValue), strides: currentStrides,
                count: count, width: 4, bytes: raw.count)
            guard layout.contiguous else {
                throw ChatterboxError.invalidModelOutput("Noncontiguous reusable input")
            }
            values.withUnsafeBytes { source in raw.copyBytes(from: source) }
        }
    }

    private static func validateShape(_ shape: [Int], count: Int) throws {
        var expected = 1
        for dimension in shape {
            guard dimension > 0 else {
                throw ChatterboxError.invalidModelOutput("Nonpositive multiarray input dimension")
            }
            let (product, overflow) = expected.multipliedReportingOverflow(by: dimension)
            guard !overflow else { throw ChatterboxError.invalidModelOutput("Multiarray input shape overflow") }
            expected = product
        }
        guard count > 0, expected == count else {
            throw ChatterboxError.invalidModelOutput("Multiarray input count/shape mismatch")
        }
    }

    private static func storing<T>(_ values: [T], shape: [Int], type: MLMultiArrayDataType) throws -> MLMultiArray {
        try validateShape(shape, count: values.count)
        let array = try MLMultiArray(shape: shape.map(NSNumber.init(value:)), dataType: type)
        guard array.count == values.count else {
            throw ChatterboxError.invalidModelOutput("Multiarray input count/shape mismatch")
        }
        let width = MemoryLayout<T>.stride
        try array.withUnsafeMutableBytes { raw, currentStrides in
            let layout = try CheckedMultiArrayLayout(shape: array.shape.map(\.intValue), strides: currentStrides,
                count: array.count, width: width, bytes: raw.count)
            if layout.contiguous {
                values.withUnsafeBytes { source in raw.copyBytes(from: source) }
            } else {
                layout.forEach { index, offset in
                    raw.storeBytes(of: values[index], toByteOffset: offset * width, as: T.self)
                }
            }
        }
        return array
    }
    static func int32(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        try storing(values, shape: shape, type: .int32)
    }
    static func float32(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        try storing(values, shape: shape, type: .float32)
    }
    static func float16(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        try validateShape(shape, count: values.count)
#if arch(arm64)
        return try storing(values.map(Float16.init), shape: shape, type: .float16)
#else
        throw ChatterboxError.invalidModelOutput("Float16 requires Apple Silicon")
#endif
    }

    /// Copies logical values while locked; does not assume model outputs use
    /// packed storage. Float32 values retain their bits, including signed zero.
    func toFloatArray() throws -> [Float] {
        guard dataType == .float32 else {
            throw ChatterboxError.invalidModelOutput("Expected Float32 multiarray")
        }
        return try toFloatArrayAnyPrecision()
    }
    func toFloatArrayAnyPrecision() throws -> [Float] {
#if !arch(arm64)
        guard dataType != .float16 else {
            throw ChatterboxError.invalidModelOutput("Float16 requires Apple Silicon")
        }
#endif
        let width: Int
        switch dataType {
        case .float16: width = 2
        case .float32: width = 4
        case .double: width = 8
        default: throw ChatterboxError.invalidModelOutput("Unsupported floating multiarray type")
        }
        return try withUnsafeBytes { raw in
            let layout = try CheckedMultiArrayLayout(shape: shape.map(\.intValue), strides: strides.map(\.intValue),
                count: count, width: width, bytes: raw.count)
            var result = [Float](repeating: 0, count: count)
            if dataType == .float32 && layout.contiguous {
                result.withUnsafeMutableBytes { target in
                    target.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw.prefix(count * width)))
                }
            } else {
                layout.forEach { index, offset in
                    switch dataType {
                    case .float16:
#if arch(arm64)
                        result[index] = Float(raw.loadUnaligned(fromByteOffset: offset * width, as: Float16.self))
#endif
                    case .double:
                        result[index] = Float(raw.loadUnaligned(fromByteOffset: offset * width, as: Double.self))
                    default:
                        result[index] = raw.loadUnaligned(fromByteOffset: offset * width, as: Float.self)
                    }
                }
            }
            return result
        }
    }
}
