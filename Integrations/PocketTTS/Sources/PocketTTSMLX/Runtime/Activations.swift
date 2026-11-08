import MLX
import MLXNN

// Keep CPU activation graphs independent of process-wide compiled closures and
// their device-specific traces. Use identical activation equations while
// retaining the existing fused GPU path.
func pocketGELU(_ x: MLXArray, approximate: Bool = false) -> MLXArray {
    guard Device.defaultDevice().deviceType == .cpu else {
        return approximate ? MLXNN.geluApproximate(x) : MLXNN.gelu(x)
    }
    if approximate {
        return 0.5 * x * (1 + tanh(Float(0.7978845608028654) * (x + 0.044715 * (x ** 3))))
    }
    return x * (1 + erf(x / Float(2).squareRoot())) / 2
}

func pocketELU(_ x: MLXArray, alpha: Float = 1) -> MLXArray {
    guard Device.defaultDevice().deviceType == .cpu else { return MLXNN.elu(x, alpha: alpha) }
    return MLX.where(x .> 0, x, alpha * (exp(x) - 1))
}

func pocketSiLU(_ x: MLXArray) -> MLXArray {
    Device.defaultDevice().deviceType == .cpu ? x * sigmoid(x) : MLXNN.silu(x)
}

public final class PocketSiLU: Module, UnaryLayer {
    public func callAsFunction(_ x: MLXArray) -> MLXArray { pocketSiLU(x) }
}
