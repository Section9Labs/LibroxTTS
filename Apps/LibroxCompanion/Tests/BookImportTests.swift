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
    @Test func malformedExportAndUnsupportedInputFailWithoutCreatingLibraryState() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".libroxbook")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"version\":999}".utf8).write(to: file)
        #expect(throws: (any Error).self) { try BookImport.load(file) }
    }
}
