import Foundation

/// Content identity only. A reader plan is not a claim or inference permission.
public struct ChapterLocalRenderPlanReference: Codable, Sendable, Equatable {
    public let identifier: String
    public init(identifier: String) throws {
        guard isDigest(identifier) else { throw ChapterLocalSourceError.invalidReference }
        self.identifier = identifier
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identifier: c.decode(String.self, forKey: .identifier))
    }
    private enum CodingKeys: String, CodingKey { case identifier }
}

/// Created only by the SDK's validated portable-plan publisher. No live session,
/// paths or source text are journaled; the receiver uses its own admission gate.
public struct ChapterLocalRenderPlanPublication: Sendable {
    public let reference: ChapterLocalRenderPlanReference
    public let sourceReference: ChapterLocalSourceReference
    public let accountPartition: String
    public let renderKey: String
    package init(reference: ChapterLocalRenderPlanReference, sourceReference: ChapterLocalSourceReference,
                 accountPartition: String, renderKey: String) {
        self.reference = reference; self.sourceReference = sourceReference
        self.accountPartition = accountPartition; self.renderKey = renderKey
    }
}
