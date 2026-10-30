import Foundation
import Testing
import CryptoKit
@testable import LibroxChapterWorker

private final class BookJournalFixture: Sendable {
    let root: URL
    let device = UUID()
    let partition = String(repeating: "a", count: 64)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    var store: URL { root.appendingPathComponent(partition).appendingPathComponent(device.uuidString.lowercased()) }
    func open() throws -> ChapterBookOutbox { try .init(directory: root, accountPartition: partition, deviceID: device) }
    func scope() throws -> ChapterBookPreparationScope {
        try .init(book: .init(bookSHA256: String(repeating: "b", count: 64), extractionRevision: "reader-1",
            chapterKeys: ["spine:0", "spine:1", "spine:2"]), accountPartition: partition,
            configuration: Data("explicit-synthetic-policy-not-a-backend-grant".utf8))
    }
}
@Suite(.serialized) struct ChapterBookOutboxTests {
    @Test func durablePreparationPriorityAndExactAcknowledgementsSurviveReopen() async throws {
        let f = try BookJournalFixture(), outbox = try f.open(), scope = try f.scope()
        let first = try await outbox.setWanted(true, scope: scope, priority: .init(chapterIndex: 2, sourceUTF16Offset: 7))
        #expect(first.wanted); #expect(first.revision == 1); #expect(first.wantedRevision == 1)
        #expect(try await outbox.confirm(first, serverRevision: .init(opaqueValue: "ack-1")))
        let priority = try await outbox.prioritize(.init(chapterIndex: 1, sourceUTF16Offset: 0), scopeID: scope.identifier)
        #expect(priority.wanted); #expect(priority.wantedRevision == first.wantedRevision); #expect(priority.revision == 2)
        #expect(try await !outbox.confirm(first, serverRevision: .init(opaqueValue: "late")))
        await outbox.close()
        let reopened = try f.open(), stored = try #require(await reopened.stored(scopeID: scope.identifier))
        #expect(stored.intent == priority); #expect(stored.pending); #expect(stored.confirmedServerRevision == nil)
        #expect(stored.scope == scope); #expect(stored.scope.configuration == scope.configuration)
        #expect(try await reopened.confirm(priority, serverRevision: .init(opaqueValue: "ack-2")))
        await reopened.close()
        let final = try f.open(), replay = try #require(await final.stored(scopeID: scope.identifier))
        #expect(!replay.pending); #expect(replay.confirmedServerRevision?.opaqueValue == "ack-2")
        await final.close()
    }
    @Test func cancellationAndIdempotentCancellationFenceLazyCallbacksAndPreserveSilentEntries() async throws {
        let f = try BookJournalFixture(), outbox = try f.open(), scope = try f.scope(), priority = try ChapterBookPriority(chapterIndex: 0, sourceUTF16Offset: 0)
        _ = try await outbox.setWanted(true, scope: scope, priority: priority)
        guard case .silent(let proof) = try scope.book.classify(text: "\u{FFFC}\n", chapterIndex: 0) else { Issue.record("Wrong classification"); return }
        let initial = try await outbox.observeAdmission(scopeID: scope.identifier, chapterIndex: 0)
        _ = try await outbox.attachSilent(proof, originalText: "\u{FFFC}\n", admission: initial)
        let late = try await outbox.observeAdmission(scopeID: scope.identifier, chapterIndex: 1)
        let cancelled = try await outbox.setWanted(false, scope: scope, priority: priority)
        let repeated = try await outbox.setWanted(false, scope: scope, priority: priority)
        #expect(cancelled == repeated)
        _ = try await outbox.setWanted(true, scope: scope, priority: priority)
        guard case .silent(let second) = try scope.book.classify(text: "", chapterIndex: 1) else { Issue.record("Wrong classification"); return }
        await #expect(throws: ChapterBookJournalError.staleAdmission) {
            try await outbox.attachSilent(second, originalText: "", admission: late)
        }
        let stored = try #require(await outbox.stored(scopeID: scope.identifier))
        #expect(stored.intent.wanted); #expect(stored.intent.wantedRevision == 3)
        #expect(stored.chapters.count == 1); #expect(stored.chapters.first?.chapterIndex == 0)
        #expect(stored.chapters.first?.request == nil)
        await outbox.close()
    }
    @Test func staleAdmissionsCannotCrossCloseNewOwnerOrOtherChapterChanges() async throws {
        let f = try BookJournalFixture(), scope = try f.scope(), old = try f.open()
        _ = try await old.setWanted(true, scope: scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        let token = try await old.observeAdmission(scopeID: scope.identifier, chapterIndex: 0)
        await old.close()
        let current = try f.open()
        guard case .silent(let proof) = try scope.book.classify(text: "", chapterIndex: 0) else { Issue.record("Wrong classification"); return }
        await #expect(throws: ChapterBookJournalError.staleAdmission) {
            try await current.attachSilent(proof, originalText: "", admission: token)
        }
        let a = try await current.observeAdmission(scopeID: scope.identifier, chapterIndex: 0)
        let b = try await current.observeAdmission(scopeID: scope.identifier, chapterIndex: 1)
        _ = try await current.attachSilent(proof, originalText: "", admission: a)
        guard case .silent(let other) = try scope.book.classify(text: "\n", chapterIndex: 1) else { Issue.record("Wrong classification"); return }
        _ = try await current.attachSilent(other, originalText: "\n", admission: b)
        #expect(try await current.stored(scopeID: scope.identifier)?.chapters.count == 2)
        await current.close()
    }
    @Test func lostWriteAckFailsClosedAndReopenReconcilesActualCommittedIntent() async throws {
        let f = try BookJournalFixture(), outbox = try f.open(), scope = try f.scope()
        _ = try await outbox.setWanted(true, scope: scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        await outbox.failAfterNextRenameForTesting()
        await #expect(throws: ChapterBookJournalError.ambiguousWrite) {
            try await outbox.setWanted(false, scope: scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        }
        await #expect(throws: ChapterBookJournalError.ambiguousWrite) { try await outbox.stored(scopeID: scope.identifier) }
        await outbox.close()
        let reopened = try f.open(), stored = try #require(await reopened.stored(scopeID: scope.identifier))
        #expect(!stored.intent.wanted); #expect(stored.intent.wantedRevision == 2); #expect(stored.pending)
        await reopened.close()
    }
    @Test func establishedMissingCorruptOrForeignRoleNeverBecomesEmptyBookQueue() async throws {
        let f = try BookJournalFixture(), outbox = try f.open()
        #expect(throws: ChapterBookJournalError.alreadyOpen) { try f.open() }
        await outbox.close()
        #expect(throws: (any Error).self) { try ChapterDemandOutbox(directory: f.root, accountPartition: f.partition, deviceID: f.device) }
        let journal = f.store.appendingPathComponent("journal.json")
        let original = try Data(contentsOf: journal)
        try FileManager.default.removeItem(at: journal)
        #expect(throws: ChapterBookJournalError.corrupt) { try f.open() }
        try original.write(to: journal)
        let reopened = try f.open(); await reopened.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        try Data("{}".utf8).write(to: journal)
        #expect(throws: ChapterBookJournalError.corrupt) { try f.open() }
    }
    @Test func rootReplacementUnknownFilesAndAccountMismatchAreFenced() async throws {
        let f = try BookJournalFixture(), outbox = try f.open(), scope = try f.scope()
        let unknown = f.store.appendingPathComponent("unknown-book-data")
        try Data("keep".utf8).write(to: unknown)
        let other = try ChapterBookPreparationScope(book: scope.book, accountPartition: String(repeating: "c", count: 64), configuration: scope.configuration)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await outbox.setWanted(true, scope: other, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        }
        let moved = f.root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: f.root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false)
        await #expect(throws: ChapterBookJournalError.storage) {
            try await outbox.setWanted(true, scope: scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        }
        await outbox.close()
        let retained = moved.appendingPathComponent(f.partition).appendingPathComponent(f.device.uuidString.lowercased()).appendingPathComponent("unknown-book-data")
        #expect(try String(contentsOf: retained, encoding: .utf8) == "keep")
    }
    @Test func checksumValidUnconfirmedNonpendingStateAndInvalidPriorityReject() async throws {
        let f = try BookJournalFixture(), outbox = try f.open(), scope = try f.scope()
        _ = try await outbox.setWanted(true, scope: scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        await outbox.close()
        let file = f.store.appendingPathComponent("journal.json"), original = try Data(contentsOf: file)
        for malformed in ["pending", "priority"] {
            var envelope = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var value = try #require(envelope["value"] as? [String: Any]), entries = try #require(value["entries"] as? [String: Any])
            var entry = try #require(entries[scope.identifier] as? [String: Any])
            if malformed == "pending" { entry["pending"] = false }
            else {
                var intent = try #require(entry["intent"] as? [String: Any]), priority = try #require(intent["priority"] as? [String: Any])
                priority["sourceUTF16Offset"] = -1; intent["priority"] = priority; entry["intent"] = intent
            }
            entries[scope.identifier] = entry; value["entries"] = entries; envelope["value"] = value
            let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            envelope["checksum"] = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: file)
            #expect(throws: ChapterBookJournalError.corrupt) { try f.open() }
        }
    }
    @Test func equivalentButByteDifferentSourcePublicationNeverAttaches() async throws {
        let f = try BookJournalFixture(), outbox = try f.open()
        let book = try ChapterBookSource(bookSHA256: String(repeating: "b", count: 64), extractionRevision: "reader-1", chapterKeys: ["e\u{301}"])
        let scope = try ChapterBookPreparationScope(book: book, accountPartition: f.partition, configuration: Data("policy".utf8))
        _ = try await outbox.setWanted(true, scope: scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        let text = "Words.", hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let source = try ChapterSourceIdentity(bookSHA256: book.bookSHA256, chapterKey: "e\u{301}", textSHA256: hash, extractionRevision: "reader-1", utf16Length: text.utf16.count)
        let wrong = try ChapterSourceIdentity(bookSHA256: book.bookSHA256, chapterKey: "é", textSHA256: hash, extractionRevision: "reader-1", utf16Length: text.utf16.count)
        let recipe = try ChapterRenderRecipe(language: "en", stockVoiceID: "stock", conditioningSHA256: String(repeating: "c", count: 64),
            modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-inference", plannerRevision: "test",
            expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64), seedPolicy: "fixed-42", watermarkRevision: "disabled-1")
        let request = try ChapterRenderRequest(accountPartition: f.partition, source: source, recipe: recipe)
        let reference = try ChapterLocalSourceReference(identifier: String(repeating: "1", count: 64))
        // Package-only fixture publications exercise the final journal guard;
        // these values never represent actual source/plan files or work grants.
        let publication = ChapterLocalSourcePublication(reference: reference, source: wrong, accountPartition: f.partition)
        let plan = try ChapterLocalRenderPlanPublication(reference: .init(identifier: String(repeating: "2", count: 64)),
            sourceReference: reference, accountPartition: f.partition, renderKey: request.renderKey())
        let admission = try await outbox.observeAdmission(scopeID: scope.identifier, chapterIndex: 0)
        await #expect(throws: ChapterWorkerError.invalidIdentity) {
            try await outbox.attach(admission, request: request, source: publication, plan: plan)
        }
        #expect(try await outbox.stored(scopeID: scope.identifier)?.chapters.isEmpty == true)
        await outbox.close()
    }
    @Test func admittedLiteralSourceCannotChangeInsideTheSameBookScope() async throws {
        let f = try BookJournalFixture(), outbox = try f.open(), scope = try f.scope()
        _ = try await outbox.setWanted(true, scope: scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        guard case .silent(let empty) = try scope.book.classify(text: "", chapterIndex: 0),
              case .silent(let changed) = try scope.book.classify(text: "\n", chapterIndex: 0) else {
            Issue.record("Wrong classification"); return
        }
        let first = try await outbox.observeAdmission(scopeID: scope.identifier, chapterIndex: 0)
        _ = try await outbox.attachSilent(empty, originalText: "", admission: first)
        let next = try await outbox.observeAdmission(scopeID: scope.identifier, chapterIndex: 0)
        await #expect(throws: ChapterWorkerError.invalidIdentity) {
            try await outbox.attachSilent(changed, originalText: "\n", admission: next)
        }
        #expect(try await outbox.stored(scopeID: scope.identifier)?.chapters.first?.silentUTF16Length == 0)
        await outbox.close()
    }
}
