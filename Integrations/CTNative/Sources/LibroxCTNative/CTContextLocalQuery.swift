import Foundation

/// Round-02 diagnostic: gather contextual pre-style content. The
/// caller validates the exact token binding before entering this helper.
enum CTContextLocalQuery {
    static let revision = "centered-context-difference-query-1"

    static func gather(_ source: CTTensor, indices: [Int]) throws -> CTTensor {
        guard source.kind == .float32, source.shape.count == 3,
              source.shape[0] == 1, (8...512).contains(source.shape[1]), source.shape[2] == 256,
              (8...512).contains(indices.count), indices.allSatisfy({ (0..<source.shape[1]).contains($0) }) else {
            throw CTError.invalidTensor("context local query shape or indices")
        }
        let values = try source.floats()
        guard values.allSatisfy(\.isFinite) else { throw CTError.invalidTensor("nonfinite context local query") }
        var selected: [Float] = []
        selected.reserveCapacity(indices.count * 256)
        for index in indices { selected.append(contentsOf: values[(index * 256)..<((index + 1) * 256)]) }
        return try CTTensor(selected, shape: [1, indices.count, 256])
    }
}
