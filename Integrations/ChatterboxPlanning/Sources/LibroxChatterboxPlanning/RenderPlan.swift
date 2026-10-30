import Foundation
import CryptoKit
import LibroxChatterbox
import LibroxChapterWorker
import KokoroNarration

public enum ChatterboxChapterRenderPlanError: Error, Sendable, Equatable {
    case invalidPlan, sourceMismatch, recipeMismatch, budget
}

/// Portable exact stock-render options. This is not a demand, claim or account
/// credential. Worker admission still needs current intent plus its actual backend.
public struct ChatterboxChapterRenderPlan: Sendable {
    public static let maximumEncodedBytes = 2 * 1024 * 1024
    private struct Controls: Codable {
        let exaggerationBits, guidanceBits, temperatureBits: UInt32
    }
    private struct Annotation: Codable {
        let offset, length: Int
        let delivery, strength: String
        let controls: Controls?
    }
    private struct Payload: Codable {
        let version: Int
        let sourceSHA256: String
        let sourceUTF16Length: Int
        let language: String
        let delivery: ChapterAudioDelivery
        let direction, grouping: String
        let maximumCharacters: Int?
        let seed: UInt64
        let hasDirections: Bool
        let expressionSHA256: String
        let annotations: [Annotation]
    }
    private let payload: Payload
    private let bytes: Data
    public let sha256: String
    public var sourceSHA256: String { payload.sourceSHA256 }

    public init(request: ChatterboxChapterRenderOptions) throws {
        let mode: String, maximum: Int?
        switch request.grouping {
        case .sentences: mode = "sentences"; maximum = nil
        case .compatibleNarration(let count): mode = "compatible-narration"; maximum = count
        }
        let payload = Payload(version: 1, sourceSHA256: Self.digest(Data(request.text.utf8)),
            sourceUTF16Length: request.text.utf16.count, language: request.language, delivery: request.delivery,
            direction: request.direction == .neutral ? "neutral" : "storyteller", grouping: mode,
            maximumCharacters: maximum, seed: request.seed, hasDirections: request.performanceDirections != nil,
            expressionSHA256: request.expressionSHA256, annotations: (request.performanceDirections?.annotations ?? []).map {
                .init(offset: $0.range.location, length: $0.range.length, delivery: $0.performance.delivery.rawValue,
                    strength: $0.performance.strength.rawValue, controls: $0.controls.map {
                        .init(exaggerationBits: $0.exaggeration.bitPattern, guidanceBits: $0.guidance.bitPattern,
                            temperatureBits: $0.temperature.bitPattern)
                    })
            })
        let bytes = try Self.encode(payload)
        self.payload = payload; self.bytes = bytes; sha256 = Self.digest(bytes)
        _ = try restore(source: request.text)
    }
    private init(payload: Payload, bytes: Data) {
        self.payload = payload; self.bytes = bytes; sha256 = Self.digest(bytes)
    }
    public func encoded() -> Data { bytes }

    /// Bounded canonical decoding. No public Codable shortcut bypasses source,
    /// annotation, scalar or payload-byte admission.
    public static func decode(_ bytes: Data, source: String) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumEncodedBytes else { throw ChatterboxChapterRenderPlanError.budget }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: bytes) }
        catch { throw ChatterboxChapterRenderPlanError.invalidPlan }
        let plan = Self(payload: payload, bytes: bytes)
        _ = try plan.restore(source: source)
        guard try encode(payload) == bytes else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        return plan
    }
    public func restore(source: String) throws -> ChatterboxChapterRenderOptions {
        guard source.utf16.count <= 131072, source.utf8.count <= 393216,
              payload.annotations.count <= 4096 else { throw ChatterboxChapterRenderPlanError.budget }
        guard source.utf16.count == payload.sourceUTF16Length,
              Self.digest(Data(source.utf8)) == payload.sourceSHA256 else { throw ChatterboxChapterRenderPlanError.sourceMismatch }
        guard payload.version == 1, payload.hasDirections || payload.annotations.isEmpty else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        let direction: ChatterboxBookDirector.Direction
        switch payload.direction {
        case "neutral": direction = .neutral
        case "storyteller": direction = .storyteller
        default: throw ChatterboxChapterRenderPlanError.invalidPlan
        }
        let grouping: ChatterboxBookDirector.Grouping
        switch payload.grouping {
        case "sentences":
            guard payload.maximumCharacters == nil else { throw ChatterboxChapterRenderPlanError.invalidPlan }
            grouping = .sentences
        case "compatible-narration":
            guard let maximum = payload.maximumCharacters, (50...300).contains(maximum) else { throw ChatterboxChapterRenderPlanError.invalidPlan }
            grouping = .compatibleNarration(maxCharacters: maximum)
        default: throw ChatterboxChapterRenderPlanError.invalidPlan
        }
        do {
            let original = source as NSString, boundaries = Set(source.indices).union([source.endIndex])
            var end = 0
            let annotations = try payload.annotations.map { item -> ChatterboxPerformanceAnnotation in
                guard item.offset >= end, item.length > 0, item.offset <= original.length,
                      item.length <= original.length - item.offset,
                      let range = Range(NSRange(location: item.offset, length: item.length), in: source),
                      boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound),
                      let delivery = NarrationVocalDelivery(rawValue: item.delivery),
                      let strength = NarrationPerformanceStrength(rawValue: item.strength) else { throw ChatterboxChapterRenderPlanError.invalidPlan }
                end = item.offset + item.length
                let controls = try item.controls.map {
                    try ChatterboxExpressiveControls(exaggeration: Float(bitPattern: $0.exaggerationBits),
                        guidance: Float(bitPattern: $0.guidanceBits), temperature: Float(bitPattern: $0.temperatureBits))
                }
                return try ChatterboxPerformanceAnnotation(range: NSRange(location: item.offset, length: item.length),
                    originalText: original.substring(with: NSRange(location: item.offset, length: item.length)),
                    performance: .init(delivery: delivery, strength: strength), controls: controls)
            }
            let directions = payload.hasDirections ? try ChatterboxPerformanceDirections(source: source, annotations: annotations, scope: .chapterV1) : nil
            let request = try ChatterboxChapterRenderOptions(text: source, language: payload.language, delivery: payload.delivery,
                direction: direction, grouping: grouping, performanceDirections: directions, seed: payload.seed)
            guard request.expressionSHA256 == payload.expressionSHA256 else { throw ChatterboxChapterRenderPlanError.invalidPlan }
            return request
        } catch let error as ChatterboxChapterRenderPlanError { throw error }
        catch { throw ChatterboxChapterRenderPlanError.invalidPlan }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func encode(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(payload)
        guard bytes.count <= maximumEncodedBytes else { throw ChatterboxChapterRenderPlanError.budget }
        return bytes
    }
}
