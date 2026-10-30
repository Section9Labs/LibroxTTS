import Foundation
import Testing
@testable import LibroxChapterWorker

@Suite struct ChapterBookSourceTests {
    @Test func keepsOriginalSpineIndicesAndClassifiesOnlyLiteralSilentText() throws {
        let book = try ChapterBookSource(bookSHA256: String(repeating: "a", count: 64),
            extractionRevision: "reader-1", chapterKeys: ["spine:0", "spine:1", "spine:2"])
        guard case .silent(let cover) = try book.classify(text: "\u{FFFC}\r\n", chapterIndex: 0),
              case .silent(let empty) = try book.classify(text: "", chapterIndex: 1),
              case .narratable(let chapter) = try book.classify(text: "CHAPTER I\nDown the Rabbit-Hole.", chapterIndex: 2)
        else { Issue.record("Wrong exact source classification"); return }
        #expect(cover.chapterIndex == 0); #expect(empty.chapterIndex == 1)
        #expect(chapter.chapterKey == "spine:2")
        try cover.validate(text: "\u{FFFC}\r\n")
        #expect(throws: ChapterWorkerError.invalidIdentity) { try cover.validate(text: "\u{FFFC}\n") }
        #expect(throws: ChapterWorkerError.invalidIdentity) { try empty.validate(text: "Copyright") }
        guard case .narratable = try book.classify(text: "Copyright 1900.", chapterIndex: 1) else {
            Issue.record("Meaningful front matter was skipped"); return
        }
    }
    @Test func rejectsDuplicateEquivalentKeysInvalidSpinesAndOversizedExactSources() throws {
        #expect(throws: ChapterWorkerError.invalidIdentity) {
            try ChapterBookSource(bookSHA256: String(repeating: "a", count: 64), extractionRevision: "reader-1", chapterKeys: ["e\u{301}", "é"])
        }
        let book = try ChapterBookSource(bookSHA256: String(repeating: "a", count: 64), extractionRevision: "reader-1", chapterKeys: ["0"])
        #expect(throws: ChapterWorkerError.invalidIdentity) { try book.classify(text: "a", chapterIndex: 1) }
        #expect(throws: ChapterWorkerError.invalidIdentity) { try book.classify(text: String(repeating: "a", count: 131073), chapterIndex: 0) }
        let nfd = try book.classify(text: "e\u{301}", chapterIndex: 0), nfc = try book.classify(text: "é", chapterIndex: 0)
        #expect(nfd != nfc)
    }
}
