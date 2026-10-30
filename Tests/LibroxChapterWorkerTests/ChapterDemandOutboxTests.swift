import Foundation
import Testing
@testable import LibroxChapterWorker

private let outboxPartition = String(repeating: "a", count: 64)
private func outboxRequest(partition: String = outboxPartition) throws -> ChapterRenderRequest {
    try .init(accountPartition: partition,
        source: .init(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:7",
            textSHA256: String(repeating: "c", count: 64), extractionRevision: "epub-1", utf16Length: 40),
        recipe: .init(language: "es", stockVoiceID: "stock", conditioningSHA256: String(repeating: "d", count: 64),
            modelSHA256: String(repeating: "e", count: 64), rendererProfile: "native-standard",
            plannerRevision: "chapter-1", expressionSHA256: String(repeating: "f", count: 64),
            synthesisOptionsSHA256: String(repeating: "9", count: 64), seedPolicy: "fixed42", watermarkRevision: "disabled-1"))
}
private func outboxDirectory() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    return path
}

@Test func outboxSurvivesReopenAndLateAcknowledgementCannotLoseCancellation() async throws {
    let root = try outboxDirectory(), device = UUID(), request = try outboxRequest()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    let submit = try await first.setDemand(true, for: request)
    #expect(try await first.setDemand(true, for: request) == submit)
    #expect(submit.revision == 1)
    await first.close()
    let reopened = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    #expect(try await reopened.pending() == [submit])
    let cancel = try await reopened.setDemand(false, for: request)
    #expect(cancel.revision == 2)
    #expect(try await !reopened.acknowledge(submit))
    #expect(try await reopened.pending() == [cancel])
    #expect(try await reopened.acknowledge(cancel))
    await reopened.close()
    let third = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    #expect(try await third.pending().isEmpty)
    let next = try await third.setDemand(true, for: request)
    #expect(next.revision == 3)
    await third.close()
}

@Test func outboxExclusiveOwnershipAndAccountPartitions() async throws {
    let root = try outboxDirectory(), device = UUID()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    #expect(throws: ChapterOutboxError.alreadyOpen) {
        try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    }
    let other = String(repeating: "1", count: 64)
    let second = try ChapterDemandOutbox(directory: root, accountPartition: other, deviceID: device)
    do { _ = try await first.setDemand(true, for: outboxRequest(partition: other)); Issue.record("Accepted wrong account") }
    catch { #expect(error as? ChapterWorkerError == .accountMismatch) }
    #expect(try await second.pending().isEmpty)
    await first.close(); await second.close()
}

@Test func outboxReconcilesAmbiguousRenameWithoutOverwritingCommittedIntent() async throws {
    let root = try outboxDirectory(), device = UUID(), request = try outboxRequest()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    _ = try await first.setDemand(true, for: request)
    await first.failAfterNextRenameForTesting()
    do { _ = try await first.setDemand(false, for: request); Issue.record("Missing injected failure") }
    catch { #expect(error as? ChapterOutboxError == .ambiguousWrite) }
    do { _ = try await first.setDemand(true, for: request); Issue.record("Wrote from uncertain state") }
    catch { #expect(error as? ChapterOutboxError == .ambiguousWrite) }
    await first.close()
    let recovered = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    let pending = try await recovered.pending()
    #expect(pending.count == 1 && pending[0].revision == 2 && !pending[0].wanted)
    await recovered.close()
}

@Test func outboxCorruptionAndSymlinkNeverSilentlyResetJournal() async throws {
    let root = try outboxDirectory(), device = UUID()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    _ = try await first.setDemand(true, for: outboxRequest()); await first.close()
    let journal = root.appendingPathComponent(outboxPartition).appendingPathComponent(device.uuidString.lowercased()).appendingPathComponent("journal.json")
    try Data("corrupt".utf8).write(to: journal)
    #expect(throws: ChapterOutboxError.corrupt) {
        try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    }
    #expect(try Data(contentsOf: journal) == Data("corrupt".utf8))
    try FileManager.default.removeItem(at: journal)
    let sentinel = root.appendingPathComponent("sentinel")
    try Data("preserve".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: sentinel)
    #expect(throws: ChapterOutboxError.corrupt) {
        try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
}

@Test func outboxCancellationDoesNotCommitAndClosedOwnerCannotWrite() async throws {
    let root = try outboxDirectory(), device = UUID(), request = try outboxRequest()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    let wanted = try await store.setDemand(true, for: request)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.setDemand(false, for: request)
    }
    do { _ = try await task.value; Issue.record("Accepted cancelled mutation") }
    catch { #expect(error is CancellationError) }
    #expect(try await store.pending() == [wanted])
    await store.close()
    do { _ = try await store.setDemand(false, for: request); Issue.record("Closed owner wrote") }
    catch { #expect(error as? ChapterOutboxError == .closed) }
}

@Test func outboxChecksumRejectsValidJSONIntentTampering() async throws {
    let root = try outboxDirectory(), device = UUID()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    _ = try await store.setDemand(true, for: outboxRequest()); await store.close()
    let journal = root.appendingPathComponent(outboxPartition).appendingPathComponent(device.uuidString.lowercased()).appendingPathComponent("journal.json")
    var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
    var entries = try #require(value["entries"] as? [String: [String: Any]])
    let key = try #require(entries.keys.first)
    var entry = try #require(entries[key])
    var intent = try #require(entry["intent"] as? [String: Any])
    intent["wanted"] = false; entry["intent"] = intent; entries[key] = entry; value["entries"] = entries
    let tampered = try JSONSerialization.data(withJSONObject: value)
    try tampered.write(to: journal)
    #expect(throws: ChapterOutboxError.corrupt) {
        try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    }
    #expect(try Data(contentsOf: journal) == tampered)
}

@Test func outboxRetainedAncestorDescriptorPreventsJournalRedirection() async throws {
    let root = try outboxDirectory(), foreign = try outboxDirectory(), device = UUID()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: foreign) }
    let account = root.appendingPathComponent(outboxPartition)
    let held = root.appendingPathComponent("held-original-account")
    let sentinel = foreign.appendingPathComponent("sentinel")
    try Data("preserved".utf8).write(to: sentinel)
    let store = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device,
        afterAccountOpenForTesting: {
            try FileManager.default.moveItem(at: account, to: held)
            try FileManager.default.createSymbolicLink(at: account, withDestinationURL: foreign)
        })
    _ = try await store.setDemand(true, for: outboxRequest())
    #expect(FileManager.default.fileExists(atPath: held.appendingPathComponent(device.uuidString.lowercased()).appendingPathComponent("journal.json").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: foreign.path) == ["sentinel"])
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserved")
    await store.close()
    #expect(throws: ChapterOutboxError.storage) {
        try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    }
}

@Test func outboxNewIntentInvalidatesOlderStickyServerConfirmation() async throws {
    let root = try outboxDirectory(), device = UUID(), request = try outboxRequest()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ChapterDemandOutbox(directory: root, accountPartition: outboxPartition, deviceID: device)
    let first = try await store.setDemand(true, for: request)
    let version = try ChapterServerRevision(opaqueValue: "test-server-version")
    #expect(try await store.confirm(first, serverRevision: version))
    #expect(try await store.confirmation(for: request)?.intent == first)
    let cancelled = try await store.setDemand(false, for: request)
    #expect(try await store.confirmation(for: request) == nil)
    #expect(try await !store.confirm(first, serverRevision: version))
    #expect(try await store.pending() == [cancelled])
    await store.close()
}
