import CoreML

extension PocketTTSCoreMLEngine {
    /// Reinterpret the retained flow latent for the next transformer invocation.
    static func latentInput(_ array: MLMultiArray) throws -> MLMultiArray {
        guard array.dataType == .float32, array.count == 32 else { throw Failure.invalidShape }
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        var expected = 1
        for d in shape.indices.reversed() {
            if shape[d] > 1 && strides[d] != expected { return try floats(values(array), shape: [1,1,32]) }
            expected *= shape[d]
        }
        return try MLMultiArray(dataPointer: array.dataPointer, shape: [1,1,32], dataType: .float32,
            strides: [32,32,1], deallocator: { [array] _ in withExtendedLifetime(array) {} })
    }

    /// Read-only, invocation-local bridge from the transformer's [1,1,1024]
    /// output to flow's [1,1024] input. Prediction completes before the next
    /// transformer call; neither graph's output is reused as mutable input.
    static func flowCondition(_ array: MLMultiArray) throws -> MLMultiArray {
        guard array.dataType == .float32, array.count == 1024 else { throw Failure.invalidShape }
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        var expected = 1
        for dimension in shape.indices.reversed() {
            if shape[dimension] > 1 && strides[dimension] != expected {
                // Preserve the existing logical flattening for padded/strided
                // outputs. Such views cannot be reinterpreted as packed storage.
                return try floats(values(array), shape: [1, 1024])
            }
            expected *= shape[dimension]
        }
        if shape == [1, 1024] { return array }
        // The wrapper owns a strong reference to the original allocation, not
        // its pointer. It must never free the Core ML output's backing storage.
        return try MLMultiArray(dataPointer: array.dataPointer, shape: [1, 1024],
            dataType: .float32, strides: [1024, 1], deallocator: { [array] _ in
                withExtendedLifetime(array) {}
            })
    }
}
