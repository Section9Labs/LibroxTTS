import Foundation
import Testing
import CryptoKit
@testable import LibroxChapterWorker

private func segmentRequest(_ text: String = "One. Two.\n") throws -> ChapterRenderRequest {
    try .init(accountPartition: String(repeating: "a", count: 64), source: .init(
        bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:2",
        textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
        extractionRevision: "test-1", utf16Length: text.utf16.count), recipe: .init(
            language: "en", stockVoiceID: "stock", conditioningSHA256: String(repeating: "c", count: 64),
            modelSHA256: String(repeating: "d", count: 64), rendererProfile: "test-no-inference",
            plannerRevision: "chapterV1", expressionSHA256: String(repeating: "e", count: 64),
            synthesisOptionsSHA256: String(repeating: "f", count: 64), seedPolicy: "fixed-42", watermarkRevision: "disabled-1"))
}
private func segment(_ request: ChapterRenderRequest, text: String = "One. Two.\n", index: Int = 0,
                     previous: String? = nil, range: ChapterTextRange = .init(offset: 0, length: 4),
                     unit: ChapterTextRange? = nil, frame: Int64 = 0) throws -> ChapterSegmentManifest {
    let span = unit ?? range
    let audio = ChapterArtifactManifest(renderKey: try request.renderKey(), audioSHA256: String(repeating: "1", count: 64),
        audioByteCount: 256, decodedFrameCount: 100, codecRevision: "wav-f32-1",
        units: [.init(source: span, fragments: [span], startFrame: 0, frameCount: 100)])
    return try .init(request: request, segmentIndex: index, previousSegmentSHA256: previous,
        sourceRange: range, chapterStartFrame: frame, audio: audio, originalText: text)
}
@Suite struct ChapterSegmentTests {
    @Test func orderedPrefixesSealOnlyAfterCompleteSourceCoverage() throws {
        let request = try segmentRequest(), first = try segment(request)
        let next = try segment(request, index: 1, previous: first.sha256(), range: .init(offset: 4, length: 5),
                               unit: .init(offset: 5, length: 4), frame: 100)
        var prefix = try ChapterSegmentPrefix(request: request, originalText: "One. Two.\n")
        try prefix.append(first)
        #expect(throws: ChapterWorkerError.invalidManifest) { try prefix.completionSeal() }
        #expect(throws: ChapterWorkerError.invalidManifest) { try prefix.append(first) }
        #expect(prefix.segmentCount == 1)
        try prefix.append(next)
        let seal = try prefix.completionSeal()
        #expect(seal.segmentCount == 2); #expect(seal.decodedFrameCount == 200)
        try prefix.validate(seal)
        #expect(try ChapterSegmentManifest.decode(next.encoded(), request: request, originalText: "One. Two.\n") == next)
    }
    @Test func omissionsGraphemeSplitsReorderingAndChangedChainReject() throws {
        let request = try segmentRequest(), first = try segment(request)
        #expect(throws: ChapterWorkerError.invalidManifest) {
            try segment(request, range: .init(offset: 0, length: 9), unit: .init(offset: 5, length: 4))
        }
        var prefix = try ChapterSegmentPrefix(request: request, originalText: "One. Two.\n")
        let wrong = try segment(request, index: 1, previous: String(repeating: "2", count: 64),
            range: .init(offset: 4, length: 5), unit: .init(offset: 5, length: 4), frame: 100)
        #expect(throws: ChapterWorkerError.invalidManifest) { try prefix.append(wrong) }
        try prefix.append(first)
        #expect(throws: ChapterWorkerError.invalidManifest) { try prefix.append(wrong) }
        let text = "e\u{301}. Two.", unicode = try segmentRequest(text)
        #expect(throws: ChapterWorkerError.invalidManifest) {
            try segment(unicode, text: text, range: .init(offset: 0, length: 1))
        }
        #expect(prefix.segmentCount == 1)
    }
    @Test func canonicalWireRejectsUnknownFieldsAndOtherAccounts() throws {
        let request = try segmentRequest(), first = try segment(request)
        var object = try #require(JSONSerialization.jsonObject(with: first.encoded()) as? [String: Any])
        object["unexpected"] = true
        #expect(throws: ChapterWorkerError.invalidManifest) {
            try ChapterSegmentManifest.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                request: request, originalText: "One. Two.\n")
        }
        let other = try ChapterRenderRequest(accountPartition: String(repeating: "9", count: 64),
            source: request.source, recipe: request.recipe)
        #expect(throws: ChapterWorkerError.invalidManifest) { try first.validate(for: other, originalText: "One. Two.\n") }
    }
    @Test func receivedChainHasAggregateCanonicalMetadataBudget() throws {
        let text = String(repeating: "a", count: 131072), request = try segmentRequest(text)
        var prefix = try ChapterSegmentPrefix(request: request, originalText: text), admittedBytes = 0, rejected = false
        for index in 0..<1024 {
            let start = index * 128
            let units: [ChapterAudioUnit] = (0..<128).map { i in
                let span = ChapterTextRange(offset: start + i, length: 1)
                return .init(source: span, fragments: [span], startFrame: Int64(i), frameCount: 1)
            }
            let audio = ChapterArtifactManifest(renderKey: try request.renderKey(), audioSHA256: String(repeating: "1", count: 64),
                audioByteCount: 1024, decodedFrameCount: 128, codecRevision: "wav-f32-1", units: units)
            let manifest = try ChapterSegmentManifest(request: request, segmentIndex: index, previousSegmentSHA256: prefix.tailSHA256,
                sourceRange: .init(offset: start, length: 128), chapterStartFrame: Int64(start), audio: audio, originalText: text)
            let count = try manifest.encoded().count
            do { try prefix.append(manifest); admittedBytes += count }
            catch {
                #expect(error as? ChapterWorkerError == .invalidManifest)
                #expect(admittedBytes + count > ChapterSegmentPrefix.maximumMetadataBytes)
                #expect(prefix.segmentCount == index); rejected = true; break
            }
        }
        #expect(rejected)
    }
}
