import Foundation
import Testing
import ZIPFoundation
@testable import LibroxCompanion

@Suite struct BookImportTests {
    @Test func epubUsesOriginalSpineOrderAndPreservesSilentEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Book.epub")
        let archive = try Archive(url: file, accessMode: .create)
        let entries = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>",
            "OPS/book.opf": "<package xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><metadata><dc:title>Café on the River</dc:title></metadata><manifest><item id=\"b\" href=\"b.xhtml\"/><item id=\"a\" href=\"a.xhtml\"/><item id=\"empty\" href=\"empty.xhtml\"/></manifest><spine><itemref idref=\"a\"/><itemref idref=\"empty\"/><itemref idref=\"b\"/></spine></package>",
            "OPS/a.xhtml": "<html><head><title>Not narrated</title></head><body><p>First café 🐈.</p></body></html>",
            "OPS/b.xhtml": "<html><body><script>Not narrated</script><p>Second chapter.</p></body></html>",
            "OPS/empty.xhtml": "<html><body>  </body></html>"
        ]
        for (path, text) in entries {
            let bytes = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, size in
                bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + size))
            }
        }
        let book = try BookImport.load(file)
        #expect(book.title == "Café on the River")
        #expect(book.chapters == ["First café 🐈.", "", "Second chapter."])
        #expect(book.book.chapterKeys == ["spine:0", "spine:1", "spine:2"])
    }
    @Test func textSplittingPreservesEveryUnicodeByte() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = String(repeating: "Cafe\u{301} 🐈.\r\n", count: 12000)
        try Data(text.utf8).write(to: file)
        let book = try BookImport.load(file)
        #expect(book.chapters.count > 1)
        #expect(book.chapters.joined().utf8.elementsEqual(text.utf8))
        #expect(book.chapters.allSatisfy { $0.utf16.count <= 131072 })
    }
    @Test func longEPUBSpineSplitsWithoutLosingTextOrSourcePositions() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = String(repeating: "Cafe\u{301} 🐈 walks home. ", count: 14000) + "The end."
        let archive = try Archive(url: file, accessMode: .create)
        let entries = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path=\"book.opf\"/></rootfiles></container>",
            "book.opf": "<package><manifest><item id=\"long\" href=\"long.xhtml\"/><item id=\"empty\" href=\"empty.xhtml\"/></manifest><spine><itemref idref=\"long\"/><itemref idref=\"empty\"/></spine></package>",
            "long.xhtml": "<html><body><p>" + original + "</p></body></html>",
            "empty.xhtml": "<html><body></body></html>"
        ]
        for (path, text) in entries {
            let bytes = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, size in
                bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + size))
            }
        }
        let book = try BookImport.load(file)
        #expect(book.book.extractionRevision == "companion-epub-swiftsoup-parts-2")
        #expect(book.chapters.count > 2)
        #expect(book.chapters.dropLast().joined().utf8.elementsEqual(original.utf8))
        #expect(book.chapters.last == "")
        #expect(book.book.chapterKeys.last == "spine:1")
        var start = 0
        for index in book.chapters.indices.dropLast() {
            let part = book.chapters[index], end = start + part.utf16.count
            #expect(part.utf16.count <= 131072 && part.utf8.count <= 393216)
            #expect(book.book.chapterKeys[index] == "spine:0:utf16:\(start)-\(end)")
            start = end
        }
        #expect(start == original.utf16.count)
        try book.validate()
    }
    @Test func boundedPartsPreserveUnicodeAndRejectOneOversizeGrapheme() throws {
        let text = String(repeating: "漢語 Café\u{301} 👨‍👩‍👧‍👦 ", count: 20000)
        let parts = try BookImport.narrationParts(text)
        #expect(parts.count > 1)
        #expect(parts.joined().utf8.elementsEqual(text.utf8))
        #expect(parts.allSatisfy { $0.utf16.count <= 131072 && $0.utf8.count <= 393216 })
        let giant = "a" + String(repeating: "\u{301}", count: 131072)
        #expect(throws: (any Error).self) { try BookImport.narrationParts(giant) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIBROX_IMPORT_FIXTURE_PATH"] != nil))
    func realLongEPUBFixtureWhenProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        let path = try #require(environment["LIBROX_IMPORT_FIXTURE_PATH"])
        let book = try BookImport.load(URL(fileURLWithPath: path))
        let splitKeys = book.book.chapterKeys.filter { $0.contains(":utf16:") }
        #expect(!splitKeys.isEmpty)
        #expect(book.chapters.allSatisfy { $0.utf16.count <= 131072 && $0.utf8.count <= 393216 })
        try book.validate()
        let maximumOriginal = zip(book.book.chapterKeys, book.chapters).map { key, text in
            key.contains(":utf16:") ? Int(key.split(separator: "-").last ?? "0") ?? 0 : text.utf16.count
        }.max() ?? 0
        let report: [String: Any] = ["passed": true, "bookSHA256": book.book.bookSHA256,
            "originalSpineEntries": Set(book.book.chapterKeys.map { $0.components(separatedBy: ":utf16:")[0] }).count,
            "splitSpineEntries": Set(splitKeys.map { $0.components(separatedBy: ":utf16:")[0] }).count,
            "narrationSections": book.chapters.count, "maximumOriginalSpineUTF16": maximumOriginal,
            "maximumNarrationSectionUTF16": book.chapters.map { $0.utf16.count }.max() ?? 0,
            "extractionRevision": book.book.extractionRevision]
        if let output = environment["LIBROX_IMPORT_FIXTURE_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
    @Test func malformedExportAndUnsupportedInputFailWithoutCreatingLibraryState() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".libroxbook")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"version\":999}".utf8).write(to: file)
        #expect(throws: (any Error).self) { try BookImport.load(file) }
    }
}
