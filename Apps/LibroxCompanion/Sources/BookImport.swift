import Foundation
import CryptoKit
import ZIPFoundation
import SwiftSoup
import LibroxChapterWorker
import LibroxChatterboxPlanning

enum BookImport {
    enum Failure: LocalizedError {
        case invalid, tooLarge, encrypted, unsupported
        var errorDescription: String? {
            switch self {
            case .invalid: "This book could not be read. Try exporting it again from Librox."
            case .tooLarge: "This book exceeds the current narration chapter limit. Open it in Librox to prepare its chapters."
            case .encrypted: "This EPUB is protected. Import an unprotected copy that you can read."
            case .unsupported: "Choose an EPUB, a UTF-8 text file, or a Librox book export."
            }
        }
    }
    static func load(_ url: URL) throws -> ChatterboxBookDocument {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 100 * 1024 * 1024 else { throw Failure.tooLarge }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let title = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "libroxbook", "json": return try ChatterboxBookDocument.decode(bytes)
        case "txt":
            guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty else { throw Failure.invalid }
            var chapters: [String] = [], current = "", count = 0
            for character in text {
                let next = String(character), length = next.utf16.count
                if count + length > 100_000 { chapters.append(current); current = ""; count = 0 }
                current += next; count += length
            }
            if !current.isEmpty { chapters.append(current) }
            return try .init(title: title, book: .init(bookSHA256: hash, extractionRevision: "companion-txt-utf16-1",
                chapterKeys: chapters.indices.map { "text:\($0)" }), chapters: chapters)
        case "epub": return try epub(bytes, hash: hash, fallbackTitle: title)
        default: throw Failure.unsupported
        }
    }
    private static func epub(_ data: Data, hash: String, fallbackTitle: String) throws -> ChatterboxBookDocument {
        let archive = try Archive(data: data, accessMode: .read)
        func read(_ path: String) throws -> Data {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  let entry = archive[path], entry.type == .file else { throw Failure.invalid }
            guard entry.uncompressedSize <= 4 * 1024 * 1024 else { throw Failure.tooLarge }
            var bytes = Data()
            _ = try archive.extract(entry) { chunk in
                guard bytes.count + chunk.count <= 4 * 1024 * 1024 else { throw Failure.tooLarge }
                bytes.append(chunk)
            }
            return bytes
        }
        let container = XMLIndex()
        try container.parse(read("META-INF/container.xml"))
        guard let opf = container.rootfile else { throw Failure.invalid }
        let index = XMLIndex(); try index.parse(read(opf))
        guard !index.spine.isEmpty, index.spine.count <= 4096 else { throw Failure.invalid }
        let base = URL(fileURLWithPath: "/" + opf).deletingLastPathComponent()
        var chapters: [String] = [], keys: [String] = [], total = 0
        for (number, id) in index.spine.enumerated() {
            guard let href = index.items[id], let decoded = href.removingPercentEncoding,
                  !decoded.contains(":") else { throw Failure.invalid }
            let path = base.appendingPathComponent(decoded).standardizedFileURL.path.dropFirst()
            let html = try read(String(path))
            guard let string = String(data: html, encoding: .utf8) else { throw Failure.invalid }
            let document = try SwiftSoup.parse(string)
            try document.select("script, style, head").remove()
            let text = try document.body()?.text() ?? document.text()
            guard text.utf16.count <= 131072, text.utf8.count <= 393216 else { throw Failure.tooLarge }
            total += text.utf8.count
            guard total <= 32 * 1024 * 1024 else { throw Failure.tooLarge }
            chapters.append(text); keys.append("spine:\(number)")
        }
        return try .init(title: index.title.isEmpty ? fallbackTitle : index.title,
            book: .init(bookSHA256: hash, extractionRevision: "companion-epub-swiftsoup-text-1", chapterKeys: keys), chapters: chapters)
    }
}

private final class XMLIndex: NSObject, XMLParserDelegate {
    var rootfile: String?
    var items: [String: String] = [:]
    var spine: [String] = []
    var title = ""
    private var inTitle = false
    func parse(_ data: Data) throws {
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = self
        guard parser.parse() else { throw BookImport.Failure.invalid }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        if local == "rootfile", rootfile == nil { rootfile = attributes["full-path"] }
        if local == "item", let id = attributes["id"], let href = attributes["href"] { items[id] = href }
        if local == "itemref", let id = attributes["idref"] { spine.append(id) }
        if local == "title" { inTitle = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle { title += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name.split(separator: ":").last == "title" { inTitle = false }
    }
}
