import Foundation
import CryptoKit
import LibroxChatterbox
import LibroxChapterWorker

public enum ChatterboxChapterRequestError: Error, Sendable, Equatable { case invalidSource }

/// Reader-safe stock-render values; no native Mac runtime or MLX dependency.
/// The application supplies authorized exact text/settings, never conditioning.
public struct ChatterboxChapterRenderOptions: Sendable {
    public let text, language: String
    public let delivery: ChapterAudioDelivery
    public let direction: ChatterboxBookDirector.Direction
    public let grouping: ChatterboxBookDirector.Grouping
    public let performanceDirections: ChatterboxPerformanceDirections?
    public let seed: UInt64
    public let expressionSHA256: String
    public init(text: String, language: String, delivery: ChapterAudioDelivery = .smaller,
                direction: ChatterboxBookDirector.Direction = .storyteller,
                grouping: ChatterboxBookDirector.Grouping = .sentences,
                performanceDirections: ChatterboxPerformanceDirections? = nil, seed: UInt64 = 42) throws {
        guard ["en", "es"].contains(language), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 131072, text.utf8.count <= 393216 else { throw ChatterboxChapterRequestError.invalidSource }
        if let performanceDirections {
            guard performanceDirections.scope == .chapterV1,
                  performanceDirections.sourceSHA256 == sourceDigest(Data(text.utf8)) else { throw ChatterboxChapterRequestError.invalidSource }
        }
        if case .compatibleNarration(let maximum) = grouping, !(50...300).contains(maximum) { throw ChatterboxChapterRequestError.invalidSource }
        self.text = text; self.language = language; self.delivery = delivery; self.direction = direction
        self.grouping = grouping; self.performanceDirections = performanceDirections; self.seed = seed
        expressionSHA256 = try (performanceDirections ?? ChatterboxPerformanceDirections(source: text, annotations: [], scope: .chapterV1)).expressionSHA256
    }
}
private func sourceDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
