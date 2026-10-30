import Foundation
import CryptoKit
import KokoroNarration

/// Actual model controls using the existing request's unchanged bounds.
/// These are explicit audition/authoring choices, not emotion guarantees.
public struct ChatterboxExpressiveControls: Sendable {
    public let exaggeration: Float
    public let guidance: Float
    public let temperature: Float
    public init(exaggeration: Float, guidance: Float, temperature: Float = 0.8) throws {
        guard exaggeration.isFinite, (0...2).contains(exaggeration),
              guidance.isFinite, (0...2).contains(guidance),
              temperature.isFinite, (0.1...2).contains(temperature)
        else { throw ChatterboxNarrationError.invalidOptions }
        self.exaggeration = exaggeration; self.guidance = guidance; self.temperature = temperature
    }
}

/// Reviewed intent, not a named acoustic capability. For example, a whisper
/// annotation adjusts existing intensity/CFG suggestions; it does not establish
/// that Multilingual can synthesize a genuine whisper. No tags are inserted.
public struct ChatterboxPerformanceAnnotation: Sendable {
    public let range: NSRange
    public let originalText: String
    public let performance: NarrationPerformanceOverride
    public let controls: ChatterboxExpressiveControls?
    public init(range: NSRange, originalText: String,
                performance: NarrationPerformanceOverride = .init(delivery: .neutral),
                controls: ChatterboxExpressiveControls? = nil) throws {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              originalText.utf16.count == range.length, originalText.utf8.count <= 32_768,
              !originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ChatterboxPerformanceDirections.Failure.invalidRange }
        self.range = range; self.originalText = originalText; self.performance = performance; self.controls = controls
    }
}

/// Immutable review sidecar for the exact source, never a rewritten book.
/// Annotated ranges must contain whole planned units. Partial-unit intersections
/// fail instead of silently affecting neighboring words or losing an annotation.
public struct ChatterboxPerformanceDirections: Sendable {
    public static let revision = "chatterbox-reviewed-directions-1"
    public enum Failure: Error, Equatable { case invalidRange, overlappingRanges, sourceMismatch, partialUnit, unusedAnnotation }
    public let sourceSHA256: String
    public let annotations: [ChatterboxPerformanceAnnotation]
    /// Bind this into a chapter recipe's expressionSHA256. Distinct delivery
    /// strengths and source ranges have distinct identities, independent of codec.
    public let expressionSHA256: String

    public init(source: String, annotations: [ChatterboxPerformanceAnnotation]) throws {
        guard !source.isEmpty, source.utf8.count <= 32_768, annotations.count <= 128 else { throw Failure.invalidRange }
        let original = source as NSString
        let boundaries = Set(source.indices).union([source.endIndex])
        let sorted = annotations.sorted { $0.range.location < $1.range.location }
        var end = 0
        for annotation in sorted {
            let range = annotation.range
            guard range.location <= original.length, range.length <= original.length - range.location,
                  let span = Range(range, in: source), boundaries.contains(span.lowerBound),
                  boundaries.contains(span.upperBound) else { throw Failure.invalidRange }
            guard range.location >= end else { throw Failure.overlappingRanges }
            guard Data(original.substring(with: range).utf8) == Data(annotation.originalText.utf8)
            else { throw Failure.sourceMismatch }
            end = range.location + range.length
        }
        let digest = Self.hash(Data(source.utf8))
        struct Controls: Encodable { let exaggeration, guidance, temperature: Float }
        struct Item: Encodable {
            let location: Int; let length: Int; let textSHA256, delivery, strength: String
            let controls: Controls?
        }
        struct Identity: Encodable { let revision, sourceSHA256: String; let annotations: [Item] }
        let identity = Identity(revision: Self.revision, sourceSHA256: digest, annotations: sorted.map {
            .init(location: $0.range.location, length: $0.range.length, textSHA256: Self.hash(Data($0.originalText.utf8)),
                  delivery: $0.performance.delivery.rawValue, strength: $0.performance.strength.rawValue,
                  controls: $0.controls.map { .init(exaggeration: $0.exaggeration, guidance: $0.guidance, temperature: $0.temperature) })
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        sourceSHA256 = digest; self.annotations = sorted
        expressionSHA256 = Self.hash(try encoder.encode(identity))
    }

    func validate(source: String) throws {
        guard Self.hash(Data(source.utf8)) == sourceSHA256 else { throw Failure.sourceMismatch }
    }
    func annotationIndex(for range: NSRange) throws -> Int? {
        for (index, annotation) in annotations.enumerated() {
            let a = annotation.range
            if NSIntersectionRange(a, range).length > 0 {
                guard range.location >= a.location, NSMaxRange(range) <= NSMaxRange(a) else { throw Failure.partialUnit }
                return index
            }
        }
        return nil
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
