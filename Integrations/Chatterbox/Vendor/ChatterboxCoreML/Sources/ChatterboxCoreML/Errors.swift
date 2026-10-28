import Foundation

public enum ChatterboxError: Error, CustomStringConvertible {
    case missingFile(String)
    case invalidModelOutput(String)
    case shapeMismatch(String)
    case tokenizer(String)
    case npy(String)
    case audio(String)
    /// A CoreML prediction faulted: model label + the underlying reason. Raised by
    /// ``predictTrapping(_:from:label:body:)``, including for an Objective-C
    /// `NSException` (e.g. an ANE `E5RT` fault) that would otherwise kill the process.
    case prediction(String, String)

    public var description: String {
        switch self {
        case .missingFile(let s): return "Missing model file: \(s)"
        case .invalidModelOutput(let s): return "Invalid model output: \(s)"
        case .shapeMismatch(let s): return "Shape mismatch: \(s)"
        case .tokenizer(let s): return "Tokenizer error: \(s)"
        case .npy(let s): return "NPY parse error: \(s)"
        case .audio(let s): return "Audio error: \(s)"
        case .prediction(let label, let reason): return "\(label) prediction failed: \(reason)"
        }
    }
}
