import CoreML
import Foundation

/// All five components use native ML Programs. One immutable weight copy per
/// component; variable-length attention uses the verified v2 conversion.
final class CTCoreMLGraph {
    private let model: MLModel
    init(package: URL, backend: CTEngine.Backend, functionName: String? = nil) throws {
        let configuration = MLModelConfiguration()
        configuration.functionName = functionName
        switch backend {
        case .coreMLCPU: configuration.computeUnits = .cpuOnly
        case .coreMLGPU, .coreMLGPUHeavy: configuration.computeUnits = .cpuAndGPU
        case .coreMLNeuralEngine: configuration.computeUnits = .cpuAndNeuralEngine
        case .coreMLAll: configuration.computeUnits = .all
        }
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let compiledURL = try CTCompiledModelCache.modelURL(for: package)
        model = try autoreleasepool { try MLModel(contentsOf: compiledURL, configuration: configuration) }
    }

    /// Pad the masked text axis once per passage. Latent audio is never padded.
    /// Copy row-wise to support both contiguous and backend-strided outputs.
    static func paddedText(_ feature: MLFeatureValue, capacity: Int = 512) throws -> MLFeatureValue {
        guard let source = feature.multiArrayValue else { throw CTError.invalidTensor("text features") }
        let shape = source.shape.map(\.intValue)
        guard let length = shape.last, length > 0, length <= capacity,
              source.dataType == .float32 || source.dataType == .int32 else {
            throw CTError.invalidTensor("text capacity")
        }
        if length == capacity { return feature }
        let outputShape = Array(shape.dropLast()) + [capacity]
        let target = try MLMultiArray(shape: outputShape.map(NSNumber.init), dataType: source.dataType)
        target.dataPointer.initializeMemory(as: UInt8.self, repeating: 0, count: target.count * 4)
        let strides = source.strides.map(\.intValue)
        for row in 0..<(source.count / length) {
            var remaining = row, sourceOffset = 0
            for axis in shape.indices.dropLast().reversed() {
                sourceOffset += (remaining % shape[axis]) * strides[axis]
                remaining /= shape[axis]
            }
            if strides.last == 1 {
                target.dataPointer.advanced(by: row * capacity * 4).copyMemory(
                    from: source.dataPointer.advanced(by: sourceOffset * 4), byteCount: length * 4)
            } else {
                for column in 0..<length {
                    target.dataPointer.advanced(by: (row * capacity + column) * 4).copyMemory(
                        from: source.dataPointer.advanced(by: (sourceOffset + column * strides.last!) * 4), byteCount: 4)
                }
            }
        }
        return MLFeatureValue(multiArray: target)
    }
    /// Materialize external tensors once, then retain Core ML feature values
    /// between graphs. In particular, flow steps never round-trip through Data.
    static func feature(_ tensor: CTTensor) throws -> MLFeatureValue {
        let array = try MLMultiArray(shape: tensor.shape.map { NSNumber(value: $0) },
                                    dataType: tensor.kind == .int64 ? .int32 : .float32)
        if tensor.kind == .float32 {
            tensor.data.withUnsafeBytes { source in
                array.dataPointer.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        } else {
            try tensor.data.withUnsafeBytes { bytes in
                let destination = array.dataPointer.assumingMemoryBound(to: Int32.self)
                for i in 0..<array.count {
                    let value = bytes.loadUnaligned(fromByteOffset: i * 8, as: Int64.self)
                    guard let converted = Int32(exactly: value) else { throw CTError.invalidTensor("Core ML token range") }
                    destination[i] = converted
                }
            }
        }
        return MLFeatureValue(multiArray: array)
    }
    func predict(_ inputs: [String: MLFeatureValue]) throws -> MLFeatureValue {
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard result.featureNames.count == 1, let name = result.featureNames.first,
              let value = result.featureValue(for: name), value.multiArrayValue != nil else {
            throw CTError.invalidTensor("Core ML output")
        }
        return value
    }
    /// A snapshot is only needed for diagnostic traces and final PCM delivery.
    static func tensor(_ value: MLFeatureValue) throws -> CTTensor {
        guard let array = value.multiArrayValue else { throw CTError.invalidTensor("Core ML output") }
        let shape = array.shape.map(\.intValue)
        var expectedStride = 1
        var contiguous = true
        for axis in shape.indices.reversed() {
            if shape[axis] > 1, array.strides[axis].intValue != expectedStride { contiguous = false }
            expectedStride *= shape[axis]
        }
        if array.dataType == .float32, contiguous {
            return try CTTensor(shape: shape, kind: .float32,
                data: Data(bytes: array.dataPointer, count: array.count * MemoryLayout<Float>.size))
        }
        // Preserve the safe path for a backend returning strided/other-precision output.
        let values = (0..<array.count).map { array[$0].floatValue }
        return try CTTensor(values, shape: shape)
    }
}
