import Foundation

/// Past atomic Reader acceptance of exact wanted intent and verified custody.
/// Not a server acknowledgement or an indefinitely current playback grant.
public struct ChapterReaderArtifactAcceptance: Sendable {
    public let artifact: ChapterLocalArtifact
    public let readSet: ChapterIntentReadSet
    public let reference: ChapterLocalHandoffReference
}
