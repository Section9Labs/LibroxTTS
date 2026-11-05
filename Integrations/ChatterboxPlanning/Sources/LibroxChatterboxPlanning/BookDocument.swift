import Foundation
import LibroxChapterWorker

/// Portable exact extraction for a local import or reader handoff. Original
/// document identity is mandatory; the SDK does not invent it from the title.
public struct ChatterboxBookDocument: Codable, Sendable, ChatterboxBookSourceProvider {
    public let version: Int
    public let title: String
    public let book: ChapterBookSource
    public let chapters: [String]
    public init(title: String, book: ChapterBookSource, chapters: [String]) throws {
        version = 1; self.title = title; self.book = book; self.chapters = chapters
        try validate()
    }
    public func validate() throws {
        try book.validate()
        guard version == 1, !title.isEmpty, title.utf8.count <= 1024,
              chapters.count == book.chapterKeys.count,
              chapters.reduce(0, { $0 + $1.utf8.count }) <= 32 * 1024 * 1024 else { throw ChapterWorkerError.invalidIdentity }
        for index in chapters.indices { _ = try book.classify(text: chapters[index], chapterIndex: index) }
    }
    public func chapter(at originalSpineIndex: Int) async throws -> ChatterboxBookTextInput {
        try Task.checkCancellation()
        guard chapters.indices.contains(originalSpineIndex) else { throw ChapterWorkerError.invalidIdentity }
        return try .init(text: chapters[originalSpineIndex])
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 40 * 1024 * 1024 else { throw ChapterWorkerError.invalidIdentity }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024 else { throw ChapterWorkerError.invalidIdentity }
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate(); return document
    }
}
