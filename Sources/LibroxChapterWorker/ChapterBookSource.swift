import Foundation
import CryptoKit

/// Exact Reader spine, including front matter and empty/attachment-only entries.
/// Keys never move when a silent entry is found. This is source metadata, not
/// durable wanted intent, renderer settings, a claim or a cloud acknowledgement.
public struct ChapterBookSource: Codable, Sendable, Equatable {
    public let version: Int
    public let bookSHA256: String
    public let extractionRevision: String
    public let chapterKeys: [String]
    public init(bookSHA256: String, extractionRevision: String, chapterKeys: [String]) throws {
        version = 1; self.bookSHA256 = bookSHA256; self.extractionRevision = extractionRevision; self.chapterKeys = chapterKeys
        try validate()
    }
    public func validate() throws {
        guard version == 1, isDigest(bookSHA256), !extractionRevision.isEmpty, extractionRevision.utf8.count <= 256,
              (1...4096).contains(chapterKeys.count), Set(chapterKeys).count == chapterKeys.count,
              chapterKeys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.utf8.contains(0) }),
              chapterKeys.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw ChapterWorkerError.invalidIdentity }
    }
    /// Classify only literal unspoken content. Titles/copyright/front matter
    /// containing any other character remain narratable, never silently dropped.
    /// Hashes preserve exact UTF8, NFD, CRLF and attachment positions.
    public func classify(text: String, chapterIndex: Int) throws -> ChapterBookEntrySource {
        try validate()
        guard chapterKeys.indices.contains(chapterIndex), text.utf16.count <= 131072, text.utf8.count <= 393216 else {
            throw ChapterWorkerError.invalidIdentity
        }
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let silent = text.allSatisfy { $0.isWhitespace || $0 == "\u{FFFC}" }
        if silent {
            return .silent(.init(book: self, chapterIndex: chapterIndex, textSHA256: hash, utf16Length: text.utf16.count))
        }
        return .narratable(try .init(bookSHA256: bookSHA256, chapterKey: chapterKeys[chapterIndex],
            textSHA256: hash, extractionRevision: extractionRevision, utf16Length: text.utf16.count))
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 4 * 1024 * 1024 else { throw ChapterWorkerError.invalidIdentity }
        return data
    }
    public func sha256() throws -> String {
        SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ChapterBookEntrySource: Sendable, Equatable {
    case narratable(ChapterSourceIdentity)
    case silent(ChapterBookSilentSource)
}

/// SDK-authored literal silent-entry proof. It contains no generated audio and
/// never becomes a ChapterLocalArtifact or a zero-frame audio segment. A future
/// book service must still durably accept it under the current book intent.
public struct ChapterBookSilentSource: Sendable, Equatable {
    public let book: ChapterBookSource
    public let chapterIndex: Int
    public let textSHA256: String
    public let utf16Length: Int
    fileprivate init(book: ChapterBookSource, chapterIndex: Int, textSHA256: String, utf16Length: Int) {
        self.book = book; self.chapterIndex = chapterIndex; self.textSHA256 = textSHA256; self.utf16Length = utf16Length
    }
    public func validate(text: String) throws {
        guard case .silent(let other) = try book.classify(text: text, chapterIndex: chapterIndex), other == self else {
            throw ChapterWorkerError.invalidIdentity
        }
    }
}
