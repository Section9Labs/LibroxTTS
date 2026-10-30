#if os(macOS)
import Foundation
import CryptoKit
import MLX
import MLXNN

struct NativeAcousticLoadReport: Codable, Sendable {
    let checkpointSHA256: String
    let learnedTensors: Int
    let derivedSHA256: [String: String]
    let learnedBytes: Int
    let seconds: Double
    let precision: String
}

/// Full F32, regular multilingual S3Gen. No alternate decoder, random missing
/// parameter, quantization, transpose, shortened solver or value substitution.
final class NativeAcousticModel {
    let model: CausalMaskedDiffWithXvec
    let report: NativeAcousticLoadReport
    private let source: AcousticCheckpointAsset
    private let runtime: AcousticRuntimeAsset
    private let derived: [String: MLXArray]

    init(checkpoint: URL, metallib: URL, check: () throws -> Void) throws {
        let began = Date()
        guard ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0" else { throw AcousticInventoryError.input }
        let runtime = try AcousticRuntimeAsset(url: metallib)
        GPU.metallib = runtime.url
        let source = try AcousticCheckpointAsset(modelFile: checkpoint, check: check)
        self.runtime = runtime; self.source = source
        try check(); try runtime.verify()
        // Freeze the SAME CPU constructor-state recipes used by the qualified
        // inventory. Neither GPU normal/trig rounding nor later global RNG
        // constructor draw counts may choose these state values.
        let frozen: [String: (values: [Float], shape: [Int], sha: String)] = try Device.withDefaultDevice(.cpu) {
            let prototype = CausalMaskedDiffWithXvec(meanflow: false)
            let parameters = Dictionary(uniqueKeysWithValues: prototype.parameters().flattened())
            var result: [String: (values: [Float], shape: [Int], sha: String)] = [:]
            for spec in AcousticInventory.derived where spec.key != "external.trimFade" {
                try check()
                guard let value = parameters[spec.key], value.dtype == .float32, value.shape == spec.shape else { throw AcousticInventoryError.identity }
                eval(value)
                let values = value.asArray(Float.self)
                guard values.allSatisfy(\.isFinite) else { throw AcousticInventoryError.input }
                let bytes = values.withUnsafeBufferPointer { Data(buffer: $0) }
                result[spec.key] = (values, spec.shape, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            }
            guard result.count == 4 else { throw AcousticInventoryError.identity }
            return result
        }
        let built: (CausalMaskedDiffWithXvec, [String: MLXArray], Int) = try Device.withDefaultDevice(.gpu) {
            let candidate = CausalMaskedDiffWithXvec(meanflow: false)
            candidate.train(false)
            let expected = Dictionary(uniqueKeysWithValues: candidate.parameters().flattened())
            let raw = try loadArrays(url: checkpoint, stream: .cpu) // lazy, only admitted S3 tensors are evaluated
            guard raw.count == source.header.count else { throw AcousticInventoryError.identity }
            var supplied: [String: MLXArray] = [:], learnedCount = 0, learnedBytes = 0
            for (name, spec) in source.header.sorted(by: { $0.key < $1.key }) {
                try check()
                guard let original = raw[name], original.dtype == .float32, original.shape == spec.shape else { throw AcousticInventoryError.identity }
                guard let target = try AcousticInventory.route(name).target else { continue }
                guard supplied[target] == nil, let destination = expected[target], destination.dtype == .float32,
                      destination.shape == original.shape else { throw AcousticInventoryError.identity }
                supplied[target] = original; learnedCount += 1; learnedBytes += original.nbytes
            }
            var state: [String: MLXArray] = [:]
            for (name, value) in frozen {
                guard supplied[name] == nil, expected[name]?.shape == value.shape else { throw AcousticInventoryError.identity }
                let array = MLXArray(value.values, value.shape)
                supplied[name] = array; state[name] = array
            }
            guard learnedCount == 1367, Set(supplied.keys) == Set(expected.keys), supplied.count == 1371 else { throw AcousticInventoryError.identity }
            try candidate.update(parameters: ModuleParameters.unflattened(supplied), verify: .all)
            // Validate every learned value, with one scalar synchronization.
            let finite = all(stacked(supplied.values.map { all(isFinite($0)) }))
            eval(finite)
            guard finite.item(Bool.self) else { throw AcousticInventoryError.input }
            let installed = Dictionary(uniqueKeysWithValues: candidate.parameters().flattened())
            let exact = all(stacked(supplied.keys.sorted().map { key in
                all(installed[key]!.view(dtype: .uint32) .== supplied[key]!.view(dtype: .uint32))
            }))
            eval(exact)
            guard exact.item(Bool.self) else { throw AcousticInventoryError.identity }
            return (candidate, state, learnedBytes)
        }
        model = built.0; derived = built.1
        try source.verify(); try runtime.verify(); try check()
        report = .init(checkpointSHA256: source.digest, learnedTensors: 1367,
            derivedSHA256: frozen.mapValues(\.sha), learnedBytes: built.2,
            seconds: Date().timeIntervalSince(began), precision: "F32-all-acoustic-weights-and-state")
    }

    func verify() throws { try source.verify(); try runtime.verify() }
}
#endif
