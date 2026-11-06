import CoreML
import Foundation

/// Exact length specializations share a single on-disk weight blob. Keep only
/// the active function resident; a length-group change releases it before load.
final class CTGenerator {
    private let package: URL
    private var backend: CTEngine.Backend
    private var function: String?
    private var graph: CTCoreMLGraph?

    init(package: URL, backend: CTEngine.Backend) {
        self.package = package; self.backend = backend
    }

    static func functionName(for length: Int) throws -> String {
        switch length {
        case 1...15: "latent_\(length)"
        case 16...128: "latent_16_128"
        case 129...256: "latent_129_256"
        case 257...384: "latent_257_384"
        case 385...431: "latent_385_431"
        default: throw CTError.passageTooLong
        }
    }

    func setBackend(_ value: CTEngine.Backend) {
        guard value != backend else { return }
        graph = nil; function = nil; backend = value
    }

    func predict(_ inputs: [String: MLFeatureValue]) throws -> MLFeatureValue {
        guard let length = inputs["noisy_latent"]?.multiArrayValue?.shape.last?.intValue else {
            throw CTError.invalidTensor("latent length")
        }
        let selected = try Self.functionName(for: length)
        if function != selected {
            graph = nil; function = nil
            try Task.checkCancellation()
            graph = try CTCoreMLGraph(package: package, backend: backend, functionName: selected)
            function = selected
        }
        guard let graph else { throw CTError.notLoaded }
        return try graph.predict(inputs)
    }
}
