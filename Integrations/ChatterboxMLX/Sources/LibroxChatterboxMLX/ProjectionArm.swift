#if os(macOS)
import Foundation
import MLX
import MLXNN

/// Synchronously confined to one offline CPU arm. Inert tensors on error are
/// discarded graph construction only: evaluate() must throw before eval/write.
final class ProjectionArm {
    enum Mode: String { case eagerNative, certified }
    struct Failure: Error, Codable {
        let module: String
        let stage: String
        let cause: String
    }
    struct BoundaryEvent: Codable {
        let module: String
        let stage: String
        let cases: [CertifiedHalfProjection.Boundary]
    }
    let mode: Mode
    let budget: CertifiedHalfProjection.Budget
    var stage = "unassigned"
    private(set) var failure: Failure?
    private(set) var attempted = 0
    private(set) var completedHelpers = 0
    private(set) var shortCircuits = 0
    private(set) var acceptedEvaluations = 0
    private(set) var certifiedOutputs = 0
    private(set) var exactFallbackOutputs = 0
    private(set) var boundaries: [BoundaryEvent] = []
    // Internal test injection; no CLI parameter can set it.
    private let injectedFailure: ((Int) -> Error?)?
    private let afterEvaluation: (() -> Void)?
    init(mode: Mode, budget: CertifiedHalfProjection.Budget,
         injectedFailure: ((Int) -> Error?)? = nil, afterEvaluation: (() -> Void)? = nil) {
        self.mode = mode; self.budget = budget; self.injectedFailure = injectedFailure
        self.afterEvaluation = afterEvaluation
    }
    func project(module: String, input: MLXArray, weight: MLXArray,
                 prepared: CertifiedHalfProjection.PreparedWeights? = nil) -> MLXArray {
        var shape = input.shape; shape[shape.count - 1] = weight.dim(0)
        if failure != nil {
            shortCircuits += 1
            return MLXArray.zeros(shape, dtype: .float16, stream: .cpu)
        }
        let index = attempted; attempted += 1
        do {
            try budget.check()
            if let error = injectedFailure?(index) { throw error }
            let output: MLXArray
            switch mode {
            case .eagerNative:
                guard input.dtype == .float16, weight.dtype == .float16 else {
                    throw CertifiedHalfProjection.Failure.configuration
                }
                let native = matmul(input, weight.T, stream: .cpu); eval(native)
                let host = native.asArray(Float16.self)
                guard native.shape == shape, host.allSatisfy(\.isFinite) else {
                    throw CertifiedHalfProjection.Failure.nonfinite
                }
                output = MLXArray(host, shape)
            case .certified:
                guard let prepared else { throw CertifiedHalfProjection.Failure.configuration }
                let result = try CertifiedHalfProjection.evaluate(input: input, prepared: prepared, budget: budget)
                guard result.shape == shape else { throw CertifiedHalfProjection.Failure.configuration }
                certifiedOutputs += result.statistics.certified; exactFallbackOutputs += result.statistics.exactFallback
                if !result.boundaries.isEmpty {
                    boundaries.append(BoundaryEvent(module: module, stage: stage, cases: result.boundaries))
                }
                output = MLXArray(result.values, result.shape)
            }
            completedHelpers += 1
            return output
        } catch {
            failure = Failure(module: module, stage: stage, cause: String(describing: error))
            return MLXArray.zeros(shape, dtype: .float16, stream: .cpu)
        }
    }
    func evaluate(_ construct: () -> MLXArray) throws -> MLXArray {
        if let failure { throw failure }
        try checkEvaluationBoundary("before-logits")
        let logits = construct()
        if let failure { throw failure }
        try checkEvaluationBoundary("before-evaluation")
        eval(logits)
        afterEvaluation?()
        if let failure { throw failure }
        try checkEvaluationBoundary("after-evaluation")
        acceptedEvaluations += 1
        return logits
    }
    private func checkEvaluationBoundary(_ module: String) throws {
        do { try budget.check() }
        catch {
            let record = Failure(module: module, stage: stage, cause: String(describing: error))
            if failure == nil { failure = record }
            throw failure ?? record
        }
    }
}

final class OfflineProjectionLinear: Linear {
    private let arm: ProjectionArm
    private let name: String
    private let prepared: CertifiedHalfProjection.PreparedWeights?
    init(_ layer: Linear, name: String, arm: ProjectionArm) throws {
        guard layer.bias == nil, layer.weight.dtype == .float16 else {
            throw CertifiedHalfProjection.Failure.configuration
        }
        self.name = name; self.arm = arm
        do {
            prepared = arm.mode == .certified ? try CertifiedHalfProjection.prepare(weight: layer.weight, budget: arm.budget) : nil
        } catch {
            throw ProjectionArm.Failure(module: name, stage: "preparation", cause: String(describing: error))
        }
        super.init(weight: layer.weight, bias: nil)
    }
    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        arm.project(module: name, input: x, weight: weight, prepared: prepared)
    }
}
#endif
