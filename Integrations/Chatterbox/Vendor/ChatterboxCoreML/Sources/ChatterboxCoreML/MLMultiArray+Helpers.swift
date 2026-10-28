import Foundation
import CoreML

extension MLMultiArray {
    /// Builds a contiguous Int32 MLMultiArray with the given shape.
    static func int32(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .int32)
        array.withUnsafeMutableBytes { raw, _ in
            let ptr = raw.baseAddress!.bindMemory(to: Int32.self, capacity: values.count)
            values.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: values.count) }
        }
        return array
    }

    /// Builds a contiguous Float32 MLMultiArray with the given shape.
    static func float32(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        array.withUnsafeMutableBytes { raw, _ in
            let ptr = raw.baseAddress!.bindMemory(to: Float.self, capacity: values.count)
            values.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: values.count) }
        }
        return array
    }

    /// Builds a contiguous Float16 MLMultiArray with the given shape, converting
    /// each `Float` element. Required by the padded T3 prefill contract, whose
    /// `inputs_embeds` input is Float16.
    ///
    /// This project is Apple-Silicon-only; the `Float16` Swift type is unavailable
    /// in the x86_64 macOS ABI. A Release/Profile build still compiles an x86_64
    /// slice of this package (local package targets don't honor the app's arch
    /// exclusions), so the type is guarded behind `#if arch(arm64)`. The arm64
    /// slice is the only one ever linked/run on Apple Silicon.
    static func float16(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        #if arch(arm64)
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
        array.withUnsafeMutableBytes { raw, _ in
            let ptr = raw.baseAddress!.bindMemory(to: Float16.self, capacity: values.count)
            for i in 0..<values.count { ptr[i] = Float16(values[i]) }
        }
        return array
        #else
        preconditionFailure("ChatterboxCoreML Float16 path requires arm64 (Apple Silicon)")
        #endif
    }

    /// Copies a Float32 MLMultiArray into a Swift `[Float]` (assumes contiguous,
    /// which CoreML outputs are).
    func toFloatArray() -> [Float] {
        let n = count
        var out = [Float](repeating: 0, count: n)
        withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: ptr, count: n) }
        }
        return out
    }

    /// Copies a Float16 **or** Float32 MLMultiArray into a Swift `[Float]`
    /// (assumes contiguous). The padded prefill returns Float16 outputs; the
    /// older model returned Float32 — handle both so either artifact loads.
    func toFloatArrayAnyPrecision() -> [Float] {
        let n = count
        switch dataType {
        case .float16:
            #if arch(arm64)
            var out = [Float](repeating: 0, count: n)
            withUnsafeBytes { raw in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                for i in 0..<n { out[i] = Float(ptr[i]) }
            }
            return out
            #else
            preconditionFailure("ChatterboxCoreML Float16 path requires arm64 (Apple Silicon)")
            #endif
        case .float64:
            var out = [Float](repeating: 0, count: n)
            withUnsafeBytes { raw in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: Double.self)
                for i in 0..<n { out[i] = Float(ptr[i]) }
            }
            return out
        default: // .float32
            return toFloatArray()
        }
    }
}
