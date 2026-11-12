import CoreML

/// Bounded storage owned by one execution plan. Only synchronous predictions see
/// these inputs; output state and callback audio are never recycled here.
final class PocketPredictionWorkspace {
    private var position: MLMultiArray?
    private var noise: MLMultiArray?
    private var schedules: [Int: [[String: MLMultiArray]]] = [:]

    func position(_ value: Int) throws -> MLMultiArray {
        if position == nil { position = try PocketTTSCoreMLEngine.floats([0], shape: [1]) }
        position!.dataPointer.assumingMemoryBound(to: Float.self).pointee = Float(value)
        return position!
    }
    func noise(_ values: [Float]) throws -> MLMultiArray {
        guard values.count == 32 else { throw PocketTTSCoreMLEngine.Failure.invalidShape }
        if noise == nil { noise = try PocketTTSCoreMLEngine.floats(values, shape: [1,32]) }
        else { values.withUnsafeBufferPointer { noise!.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: 32) } }
        return noise!
    }
    func schedule(_ steps: Int) throws -> [[String: MLMultiArray]] {
        if let schedule = schedules[steps] { return schedule }
        let result = try (0..<steps).map { index in
            ["s": try PocketTTSCoreMLEngine.floats([Float(Double(index) / Double(steps))], shape: [1,1]),
             "t": try PocketTTSCoreMLEngine.floats([Float(Double(index + 1) / Double(steps))], shape: [1,1]),
             "steps": try PocketTTSCoreMLEngine.floats([Float(steps)], shape: [1])]
        }
        schedules[steps] = result
        return result
    }
}
