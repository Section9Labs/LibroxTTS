import Foundation

/// Private round-04 conditioning schedule. No learned values are changed.
/// Only the accepted contextual difference is carried into late conditioning.
enum CTContextCarry {
    struct Prepared {
        let residual: CTTensor
        let step3: CTTensor
        let step4: CTTensor
        /// Exact requested Float-array payload, not process/allocator peak RAM.
        let floatArrayPayloadBytes: Int
        /// New Data payload allocated here; existing late-base data is excluded.
        let newTensorPayloadBytes: Int
    }

    static func prepare(contextual: CTTensor, reference: CTTensor, late: CTTensor,
                        mode: CTContextStyleDiagnostic.CarryMode) throws -> Prepared {
        guard mode != .disabled, contextual.kind == .float32, reference.kind == .float32, late.kind == .float32,
              contextual.shape == reference.shape, contextual.shape == late.shape,
              contextual.shape.count == 3, contextual.shape[0] == 1, contextual.shape[1] == 256,
              (8...512).contains(contextual.shape[2]) else { throw CTError.invalidTensor("context carry shape") }
        let contextValues = try contextual.floats()
        let referenceValues = try reference.floats()
        let lateValues = try late.floats()
        guard contextValues.allSatisfy(\.isFinite), referenceValues.allSatisfy(\.isFinite),
              lateValues.allSatisfy(\.isFinite) else { throw CTError.invalidTensor("context carry nonfinite") }
        let residualValues = zip(contextValues, referenceValues).map { $0 - $1 }
        guard residualValues.allSatisfy(\.isFinite) else { throw CTError.invalidTensor("context carry residual overflow") }
        let residual = try CTTensor(residualValues, shape: contextual.shape)
        let bytes = residual.data.count
        if mode == .zeroControl || residualValues.allSatisfy({ $0 == 0 }) {
            // Preserve signed-zero bits and the exact accepted late base.
            return Prepared(residual: residual, step3: late, step4: late,
                floatArrayPayloadBytes: 4 * bytes, newTensorPayloadBytes: bytes)
        }
        let third = Float(1) / Float(3)
        let step3 = zip(lateValues, residualValues).map { $0 + (2 * third) * $1 }
        let step4 = zip(lateValues, residualValues).map { $0 + third * $1 }
        guard step3.allSatisfy(\.isFinite), step4.allSatisfy(\.isFinite) else {
            throw CTError.invalidTensor("context carry overflow")
        }
        return try Prepared(residual: residual, step3: CTTensor(step3, shape: late.shape),
            step4: CTTensor(step4, shape: late.shape), floatArrayPayloadBytes: 6 * bytes,
            newTensorPayloadBytes: 3 * bytes)
    }
}
