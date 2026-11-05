import Foundation

/// A source/options admission, not an inference grant. Each operation compares
/// the supplied full read-set identity with the ACTUAL current device record.
package struct ChapterBookWorkAdmission: Sendable {
    package let readSet: ChapterBookReadSet
    package let request: ChapterRenderRequest
    package let chapterIndex: Int
    let entry: ChapterBookReadSetEntry
    package init(readSet: ChapterBookReadSet, request: ChapterRenderRequest, chapterIndex: Int) throws {
        try readSet.scope.validate(request, chapterIndex: chapterIndex)
        guard readSet.intent.wanted, let entry = readSet.entries.first(where: { $0.chapterIndex == chapterIndex }),
              entry.kind == .chapter, entry.renderKey == (try request.renderKey()), entry.content != nil,
              entry.textSHA256 == request.source.textSHA256, entry.utf16Length == request.source.utf16Length else {
            throw ChapterDemandTransportError.invalidRecord
        }
        self.readSet = readSet; self.request = request; self.chapterIndex = chapterIndex; self.entry = entry
    }
}

/// Deliberately NON-EXPIRING single-appointed-Worker ownership. Logical
/// generation is not time. A different run/worker never steals an active claim.
struct ChapterBookCloudClaim: Codable, Sendable, Equatable {
    let version: Int
    let accountPartition, scopeID, renderKey: String
    let chapterIndex: Int
    let deviceID: UUID
    let wantedRevision: UInt64
    let entry: ChapterBookReadSetEntry
    let workerID, runID, claimID: UUID
    let generation: UInt64
    var active: Bool
    func validate(_ admission: ChapterBookWorkAdmission) throws {
        let set = admission.readSet
        guard version == 1, accountPartition == set.scope.accountPartition, scopeID == set.scope.identifier,
              renderKey == (try admission.request.renderKey()), chapterIndex == admission.chapterIndex,
              deviceID == set.intent.deviceID, wantedRevision == set.intent.wantedRevision,
              entry == admission.entry, generation > 0 else { throw ChapterWorkerError.staleClaim }
    }
}

struct ChapterBookCloudHead: Codable, Sendable, Equatable {
    let version: Int
    let accountPartition, scopeID, renderKey: String
    var segmentCount: Int
    var decodedFrameCount: Int64
    var sourceEnd, metadataBytes: Int
    var tailSHA256: String?
    var seal: ChapterSegmentCompletionSeal?
    init(_ admission: ChapterBookWorkAdmission) throws {
        version = 1; accountPartition = admission.request.accountPartition; scopeID = admission.readSet.scope.identifier
        renderKey = try admission.request.renderKey(); segmentCount = 0; decodedFrameCount = 0
        sourceEnd = 0; metadataBytes = 0; tailSHA256 = nil; seal = nil
    }
    func validate(_ admission: ChapterBookWorkAdmission) throws {
        guard version == 1, accountPartition == admission.request.accountPartition, scopeID == admission.readSet.scope.identifier,
              renderKey == (try admission.request.renderKey()), (0...4096).contains(segmentCount),
              (0...ChapterLocalArtifact.maximumDecodedFrames).contains(decodedFrameCount),
              (0...admission.request.source.utf16Length).contains(sourceEnd),
              (0...ChapterSegmentPrefix.maximumMetadataBytes).contains(metadataBytes),
              segmentCount == 0 ? (decodedFrameCount == 0 && sourceEnd == 0 && metadataBytes == 0 && tailSHA256 == nil && seal == nil)
                : (decodedFrameCount > 0 && sourceEnd > 0 && metadataBytes > 0 && tailSHA256.map(isDigest) == true) else {
            throw ChapterDemandTransportError.invalidRecord
        }
        if let seal {
            guard seal.version == 1, seal.accountPartition == accountPartition, seal.chapterRenderKey == renderKey,
                  seal.segmentCount == segmentCount, seal.decodedFrameCount == decodedFrameCount,
                  seal.tailSHA256 == tailSHA256 else { throw ChapterDemandTransportError.invalidRecord }
        }
    }
    mutating func append(_ manifest: ChapterSegmentManifest, admission: ChapterBookWorkAdmission, text: String) throws {
        try validate(admission); try manifest.validate(for: admission.request, originalText: text)
        let bytes = try manifest.encoded()
        guard seal == nil, manifest.segmentIndex == segmentCount, manifest.previousSegmentSHA256 == tailSHA256,
              manifest.chapterStartFrame == decodedFrameCount, manifest.sourceRange.offset == sourceEnd,
              bytes.count <= ChapterSegmentPrefix.maximumMetadataBytes - metadataBytes else { throw ChapterWorkerError.invalidManifest }
        segmentCount += 1; decodedFrameCount += manifest.audio.decodedFrameCount
        sourceEnd += manifest.sourceRange.length; metadataBytes += bytes.count; tailSHA256 = try manifest.sha256()
        try validate(admission)
    }
    mutating func finish(_ seal: ChapterSegmentCompletionSeal, admission: ChapterBookWorkAdmission, text: String) throws {
        try validate(admission); try admission.request.source.validate(text: text)
        guard self.seal == nil || self.seal == seal, segmentCount > 0,
              (text as NSString).substring(from: sourceEnd).allSatisfy({ $0.isWhitespace || $0 == "\u{FFFC}" }) else {
            throw ChapterWorkerError.invalidManifest
        }
        let bytes = try ChapterBookWorkWire.encode(seal)
        guard bytes.count <= ChapterSegmentPrefix.maximumMetadataBytes - metadataBytes else { throw ChapterWorkerError.invalidManifest }
        self.seal = seal; try validate(admission)
    }
}
enum ChapterBookWorkWire {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard !bytes.isEmpty, bytes.count <= 128 * 1024 else { throw ChapterDemandTransportError.invalidRecord }; return bytes
    }
    static func decode<T: Codable>(_ type: T.Type, _ bytes: Data) throws -> T {
        guard !bytes.isEmpty, bytes.count <= 128 * 1024 else { throw ChapterDemandTransportError.invalidRecord }
        let value = try JSONDecoder().decode(type, from: bytes)
        guard try encode(value) == bytes else { throw ChapterDemandTransportError.invalidRecord }; return value
    }
}
