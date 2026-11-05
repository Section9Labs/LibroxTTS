import Foundation
import Testing
import LibroxChapterWorker
@testable import LibroxChatterboxPlanning

private actor CloudJoinProbe {
    var entered = false
    var finished = false
    var joined = false
    var continuation: CheckedContinuation<Void, Never>?
    func run() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        finished = true
    }
    func release() { continuation?.resume(); continuation = nil }
    func markJoined() { joined = true }
}

@Suite struct CloudOperationsTests {
    @Test func stopJoinsAnUncooperativeOriginalBeforeClosing() async throws {
        let operations = ChatterboxCloudOperations(), probe = CloudJoinProbe()
        let original = Task { try await operations.run { await probe.run() } }
        while !(await probe.entered) { await Task.yield() }
        operations.stop()
        let close = Task { await operations.join(); await probe.markJoined() }
        for _ in 0..<100 { await Task.yield() }
        #expect(await probe.joined == false)
        await #expect(throws: (any Error).self) { try await operations.run { 42 } }
        await probe.release(); await close.value
        #expect(await probe.finished); #expect(await probe.joined)
        await #expect(throws: (any Error).self) { try await original.value }
    }
    @Test func callerCancellationJoinsProducerAndRejectsItsLateSuccess() async throws {
        let operations = ChatterboxCloudOperations(), probe = CloudJoinProbe()
        let original = Task { try await operations.run { await probe.run(); return 42 } }
        while !(await probe.entered) { await Task.yield() }
        original.cancel()
        #expect(await probe.finished == false)
        await probe.release()
        await #expect(throws: (any Error).self) { try await original.value }
        #expect(await probe.finished)
    }
    @Test func exactBookExportPreservesSpineUnicodeAndSilentEntries() async throws {
        let source = try ChapterBookSource(bookSHA256: String(repeating: "a", count: 64),
            extractionRevision: "test-source-1", chapterKeys: ["spine:0", "spine:1", "spine:2"])
        let chapters = ["", "Cafe\u{301} 🐈.\r\nOtro párrafo.", "\u{FFFC}\n"]
        let input = try ChatterboxBookDocument(title: "A book", book: source, chapters: chapters)
        let output = try ChatterboxBookDocument.decode(input.encoded())
        #expect(output.book == source); #expect(output.chapters == chapters)
        #expect(try await output.chapter(at: 1).text.utf8.elementsEqual(chapters[1].utf8))
        #expect(throws: (any Error).self) { try ChatterboxBookDocument(title: "A book", book: source, chapters: ["one"]) }
        var object = try #require(JSONSerialization.jsonObject(with: input.encoded()) as? [String: Any])
        object["version"] = 999
        #expect(throws: (any Error).self) { try ChatterboxBookDocument.decode(JSONSerialization.data(withJSONObject: object)) }
    }
}
