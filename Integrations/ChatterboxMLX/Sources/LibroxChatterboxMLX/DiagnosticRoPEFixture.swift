#if os(macOS)
import MLX

enum DiagnosticRoPEFixture {
    static let sha256 = "e3155186f9f00f2c1c8409c35f2532bd6ea29c81798256bac68b61f383adc125"
    enum Failure: Error { case invalid }

    static func validate(_ arrays: [String: MLXArray]) throws {
        var required = Set(["rope.cosines", "rope.sines"])
        for index in 0..<60 {
            for suffix in ["input", "output", "frequencies"] { required.insert("rope.\(index).\(suffix)") }
        }
        for index in 0..<30 {
            for suffix in ["keys", "values"] { required.insert("layer.\(index).\(suffix)") }
        }
        guard Set(arrays.keys) == required else { throw Failure.invalid }
        for (key, array) in arrays {
            try ChatterboxMLXRenderer.healthy()
            let frequency = key.hasSuffix("frequencies")
            let shape = frequency ? [32] : key.hasPrefix("layer.") ? [2, 16, 95, 64]
                : (key == "rope.cosines" || key == "rope.sines") ? [1536, 32] : [2, 16, 1, 64]
            guard array.shape == shape, array.dtype == (frequency ? .float32 : .float16),
                all(isFinite(array)).item(Bool.self) else { throw Failure.invalid }
            if frequency, !all(array .> 0).item(Bool.self) { throw Failure.invalid }
        }
    }
}
#endif
