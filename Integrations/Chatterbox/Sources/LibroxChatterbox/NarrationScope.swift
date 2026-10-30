import Foundation
import KokoroPronunciation

/// New explicit chapter admission; legacy excerpt limits and cache identities
/// remain unchanged. This is bounded planning, not cloud/service availability.
public enum ChatterboxNarrationScope: String, Sendable {
    case excerpt
    case chapterV1
    public var maximumSourceUTF8Bytes: Int { self == .excerpt ? 32_768 : StoryNarrator.chapterMaximumUTF8Bytes }
    public var maximumUnits: Int { self == .excerpt ? 128 : 4096 }
    var maximumAnnotations: Int { maximumUnits }
    var cacheSuffix: String { self == .excerpt ? "" : ":chapter-scope-1:source131072:units4096" }
    func validate(_ source: String) throws {
        guard source.utf8.count <= maximumSourceUTF8Bytes else { throw ChatterboxNarrationError.textTooLong }
        if self == .chapterV1 {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatterboxNarrationError.emptyText }
            guard source.utf16.count <= StoryNarrator.chapterMaximumUTF16 else { throw ChatterboxNarrationError.textTooLong }
        }
    }
}
