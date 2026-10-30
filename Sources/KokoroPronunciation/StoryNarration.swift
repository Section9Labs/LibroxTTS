// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation

/// Optional, bounded story metadata. Offsets refer to the unchanged original
/// text in UTF-16, so a host can store annotations beside its existing book ranges.
public struct DialogueAnnotation: Sendable, Codable, Equatable {
    public let offset: Int
    public let length: Int
    public let speakerID: String?
    public init(offset: Int, length: Int, speakerID: String? = nil) {
        self.offset = offset; self.length = length; self.speakerID = speakerID
    }
}

public struct StoryReadingSpan: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable { case narration, dialogue }
    public let text: String
    public let offset: Int
    public let length: Int
    public let role: Role
    public let speakerID: String?
    public let voiceID: String
}

/// Pure metadata planner: no model, audio buffers, downloads or speaker guessing.
/// A host validates voice IDs/languages against its catalog, stores the cast per
/// book, and passes each span to NarrationPlanner for bounded synthesis.
public struct StoryNarrator: Sendable {
    public enum Mode: Sendable { case singleNarrator, characterVoices }
    public enum PlanningError: Error { case tooManyAnnotations, invalidAnnotation, invalidCast }
    public init() {}

    public func plan(_ text: String, narratorVoiceID: String, characterVoices: [String: String] = [:],
                     dialogue: [DialogueAnnotation] = [], mode: Mode = .singleNarrator) throws -> [StoryReadingSpan] {
        try boundedPlan(text, narratorVoiceID: narratorVoiceID, characterVoices: characterVoices,
            dialogue: dialogue, mode: mode, maximumScalars: PronunciationEngine.maximumInputScalars, maximumAnnotations: 256)
    }
    public static let chapterMaximumUTF16 = 131_072
    public static let chapterMaximumUTF8Bytes = 393_216
    /// Metadata-only chapter admission. Does not enlarge phonemizer input guards.
    public func planChapter(_ text: String, narratorVoiceID: String, characterVoices: [String: String] = [:],
                            dialogue: [DialogueAnnotation] = [], mode: Mode = .singleNarrator) throws -> [StoryReadingSpan] {
        try Self.validateChapter(text)
        return try boundedPlan(text, narratorVoiceID: narratorVoiceID, characterVoices: characterVoices,
            dialogue: dialogue, mode: mode, maximumScalars: Self.chapterMaximumUTF16, maximumAnnotations: 4096)
    }
    private static func validateChapter(_ text: String) throws {
        guard text.utf16.count <= chapterMaximumUTF16, text.utf8.count <= chapterMaximumUTF8Bytes else {
            throw PronunciationError.inputTooLong(limit: chapterMaximumUTF16)
        }
    }
    private func boundedPlan(_ text: String, narratorVoiceID: String, characterVoices: [String: String],
        dialogue: [DialogueAnnotation], mode: Mode, maximumScalars: Int, maximumAnnotations: Int) throws -> [StoryReadingSpan] {
        guard text.unicodeScalars.count <= maximumScalars else {
            throw PronunciationError.inputTooLong(limit: maximumScalars)
        }
        guard dialogue.count <= maximumAnnotations else { throw PlanningError.tooManyAnnotations }
        guard !narratorVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              characterVoices.count <= 64,
              characterVoices.allSatisfy({ !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PlanningError.invalidCast
        }
        let sourceLength = text.utf16.count
        let boundaries = Set(text.indices).union([text.endIndex])
        var cursor = 0
        var spans: [StoryReadingSpan] = []
        func append(offset: Int, length: Int, speaker: String?, role: StoryReadingSpan.Role) throws {
            guard length > 0 else { return }
            guard let range = Range(NSRange(location: offset, length: length), in: text),
                  boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound) else {
                throw PlanningError.invalidAnnotation
            }
            let selected = mode == .characterVoices ? speaker.flatMap { characterVoices[$0] } : nil
            spans.append(.init(text: String(text[range]), offset: offset, length: length,
                               role: role, speakerID: speaker, voiceID: selected ?? narratorVoiceID))
        }
        for annotation in dialogue.sorted(by: { $0.offset < $1.offset }) {
            guard annotation.offset >= cursor, annotation.offset <= sourceLength,
                  annotation.length > 0, annotation.length <= sourceLength - annotation.offset else {
                throw PlanningError.invalidAnnotation
            }
            try append(offset: cursor, length: annotation.offset - cursor, speaker: nil, role: .narration)
            try append(offset: annotation.offset, length: annotation.length, speaker: annotation.speakerID, role: .dialogue)
            cursor = annotation.offset + annotation.length
        }
        try append(offset: cursor, length: sourceLength - cursor, speaker: nil, role: .narration)
        return spans
    }

    /// Review candidates only. Quoted thoughts, titles and embedded speech tags
    /// are not reliably distinguishable here. No identity or alternation inference.
    /// Unsupported or unmatched quotation styles remain ordinary narration.
    public func quotedCandidates(in text: String) throws -> [DialogueAnnotation] {
        try boundedQuotedCandidates(in: text, maximumScalars: PronunciationEngine.maximumInputScalars, maximumAnnotations: 256)
    }
    public func quotedChapterCandidates(in text: String) throws -> [DialogueAnnotation] {
        try Self.validateChapter(text)
        return try boundedQuotedCandidates(in: text, maximumScalars: Self.chapterMaximumUTF16, maximumAnnotations: 4096)
    }
    private func boundedQuotedCandidates(in text: String, maximumScalars: Int, maximumAnnotations: Int) throws -> [DialogueAnnotation] {
        guard text.unicodeScalars.count <= maximumScalars else {
            throw PronunciationError.inputTooLong(limit: maximumScalars)
        }
        let pairs: [Character: Character] = ["«": "»", "“": "”", "\"": "\""]
        var opener: String.Index?
        var closing: Character?
        var nested = false
        var result: [DialogueAnnotation] = []
        for index in text.indices {
            let char = text[index]
            if let start = opener, char == closing {
                if !nested {
                    let range = NSRange(start..<text.index(after: index), in: text)
                    result.append(.init(offset: range.location, length: range.length))
                    guard result.count <= maximumAnnotations else { throw PlanningError.tooManyAnnotations }
                }
                opener = nil; closing = nil; nested = false
            } else if opener == nil, let end = pairs[char] {
                opener = index; closing = end
            } else if opener != nil, pairs[char] != nil {
                nested = true
            }
        }
        return result
    }
}
