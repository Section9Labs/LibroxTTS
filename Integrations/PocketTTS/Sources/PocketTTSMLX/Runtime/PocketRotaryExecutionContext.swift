import Foundation
import MLX

/// One private-engine rotary position at a time. Sharing these deterministic
/// terms across layers removes duplicate graph construction without changing
/// operations, precision, or order inside the rotary application itself.
final class PocketRotaryExecutionContext {
    private struct Key: Equatable {
        let time: Int, dimension: Int, offset: Int
        let period: Double
        let device: Device
    }
    private var key: Key?
    private var terms: (MLXArray, MLXArray)?
    func rotation(time: Int, dimension: Int, offset: Int, period: Double) -> (MLXArray, MLXArray) {
        let next = Key(time: time, dimension: dimension, offset: offset, period: period, device: Device.defaultDevice())
        if key == next, let terms { return terms }
        let half = dimension / 2
        let indices = MLXArray(stride(from: 0, to: half, by: 1)).asType(.float32)
        let scale = -Float(log(period)) * 2.0 / Float(dimension)
        let frequencies = MLX.exp(indices * MLXArray(scale)).reshaped([1,1,1,half])
        let positions = (MLXArray(stride(from: 0, to: time, by: 1)).asType(.float32) + MLXArray(Float(offset))).reshaped([1,time,1,1])
        let result = (MLX.cos(frequencies * positions), MLX.sin(frequencies * positions))
        key = next; terms = result
        return result
    }
}
