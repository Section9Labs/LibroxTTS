import Foundation

/// Book-level defaults may be overridden on an individual narration unit.
/// Targets are soft: an unpunctuated clause or connected pair may exceed them.
/// Long sentences may span internal chunks at their original clause punctuation.
/// The maximum is a hard limit, including punctuation added for synthesis.
public struct PocketTTSChunkingOptions: Codable, Hashable, Sendable {
    public enum Grouping: String, Codable, Sendable {
        case adaptive
        /// Keep each supplied speaker passage/paragraph in one chunk, or throw
        /// if it exceeds the hard cap. Never silently break a protected passage.
        case keepTogether
    }
    public var grouping: Grouping
    public var narrationTargetTokens: Int
    public var dialogueTargetTokens: Int
    public var maximumTokens: Int
    public var shortSentenceTokens: Int
    public var maximumUnitScalars: Int

    /// An explicit smaller-phrase audition preset. Keeps complete sentences when
    /// possible while reducing grouping of trailing short sentences. Does not
    /// replace saved phrasing or claim universal perceptual superiority.
    public static var carefulReading: Self {
        .init(narrationTargetTokens: 24, dialogueTargetTokens: 16, shortSentenceTokens: 0)
    }

    public init(narrationTargetTokens: Int = 48, dialogueTargetTokens: Int = 32,
                maximumTokens: Int = 96, shortSentenceTokens: Int = 12,
                maximumUnitScalars: Int = 2400, grouping: Grouping = .adaptive) {
        self.grouping = grouping
        self.narrationTargetTokens = narrationTargetTokens
        self.dialogueTargetTokens = dialogueTargetTokens
        self.maximumTokens = maximumTokens
        self.shortSentenceTokens = shortSentenceTokens
        self.maximumUnitScalars = maximumUnitScalars
    }

    public enum ValidationError: Error { case invalidLimits }
    public func validate() throws {
        guard (8...100).contains(maximumTokens),
              (1...maximumTokens).contains(narrationTargetTokens),
              (1...maximumTokens).contains(dialogueTargetTokens),
              (0...maximumTokens).contains(shortSentenceTokens),
              (128...8192).contains(maximumUnitScalars) else { throw ValidationError.invalidLimits }
    }

    public static let revision = "pocket-continuous-clauses-2"
    public var cacheIdentity: String {
        "\(Self.revision):\(grouping.rawValue):n\(narrationTargetTokens):d\(dialogueTargetTokens):max\(maximumTokens):short\(shortSentenceTokens):unit\(maximumUnitScalars)"
    }
}

public enum PocketTTSPassageRole: String, Codable, Sendable {
    case narration, dialogue
}
