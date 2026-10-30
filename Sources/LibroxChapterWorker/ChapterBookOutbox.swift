import Foundation
import CryptoKit

/// Reader-only durable whole-book intent/source/options index. Give it a NEW
/// Reader/Outbox/Books namespace, never a chapter or Worker journal directory. This
/// journal is not a cloud acknowledgement, Worker authority or playback grant.
public actor ChapterBookOutbox {
    public static let maximumBooks = 64, maximumChapters = 8192, maximumJournalBytes = 32 * 1024 * 1024
    private struct Entry: Codable, Equatable {
        let scope: Data
        var intent: ChapterBookDemandIntent
        var chapters: [String: ChapterBookStoredChapter]
        var pending: Bool
        var serverRevision: String?
    }
    private struct Binding: Codable, Equatable {
        let domain: String
        let version: Int
        let partition: String
        let deviceID, publisherID: UUID
        let directoryDevice, directoryInode: UInt64
    }
    private struct State: Codable {
        let domain: String
        let version: Int
        let binding: Binding
        let entries: [String: Entry]
    }
    private struct Checked<Value: Codable>: Codable { let value: Value; let checksum: String }
    public let accountPartition: String
    public let deviceID: UUID
    private let owner = UUID()
    private let binding: Binding
    private var root: ChapterBookJournalFiles?
    private var entries: [String: Entry]
    private var commands: [String: UUID] = [:]
    private var uncertain = false
    private var afterRenameForTesting: (@Sendable () throws -> Void)?

    /// Initialize on an owned off-main task. One Reader process owns this role
    /// lock for its lifetime. Established missing/corrupt state never resets.
    public init(directory: URL, accountPartition: String, deviceID: UUID) throws {
        let files = try ChapterBookJournalFiles(directory: directory, partition: accountPartition, deviceID: deviceID)
        let binding: Binding, entries: [String: Entry]
        if let bytes = try files.read("book-established.json", maximum: 16384) {
            binding = try Self.decode(Binding.self, bytes)
            try Self.validate(binding, files: files, partition: accountPartition, deviceID: deviceID)
            guard let bytes = try files.read("journal.json", maximum: Self.maximumJournalBytes) else { throw ChapterBookJournalError.corrupt }
            let state = try Self.decode(State.self, bytes)
            guard state.domain == "librox-reader-book-outbox-1", state.version == 1, state.binding == binding else { throw ChapterBookJournalError.corrupt }
            try Self.validate(state.entries, partition: accountPartition, deviceID: deviceID)
            entries = state.entries
        } else {
            // Do not reinterpret existing chapter/Worker/unknown state as an
            // empty book store. A failed first activation remains fail-closed.
            guard try files.isFresh() else { throw ChapterBookJournalError.corrupt }
            binding = Binding(domain: "librox-reader-book-binding-1", version: 1, partition: accountPartition,
                deviceID: deviceID, publisherID: UUID(), directoryDevice: files.device, directoryInode: files.inode)
            try files.write(Self.encode(binding), leaf: "book-established.json", immutable: true)
            entries = [:]
            let state = State(domain: "librox-reader-book-outbox-1", version: 1, binding: binding, entries: entries)
            try files.write(Self.encode(state), leaf: "journal.json")
        }
        self.accountPartition = accountPartition; self.deviceID = deviceID; self.binding = binding
        self.root = files; self.entries = entries
    }
    public func stored(scopeID: String) throws -> ChapterBookStoredPreparation? {
        try writable()
        guard isDigest(scopeID) else { throw ChapterWorkerError.invalidIdentity }
        guard let entry = entries[scopeID] else { return nil }
        return try snapshot(entry)
    }
    public func pending(maximum: Int = 16) throws -> [ChapterBookStoredPreparation] {
        try writable()
        guard (1...Self.maximumBooks).contains(maximum) else { throw ChapterBookJournalError.budget }
        return try entries.sorted(by: { $0.key < $1.key }).filter { $0.value.pending }.prefix(maximum).map { try snapshot($0.value) }
    }
    /// A wanted transition is preparation, never listening. No Play/Pause API.
    /// Even idempotent cancellation invalidates live source-admission tokens.
    @discardableResult public func setWanted(_ wanted: Bool, scope: ChapterBookPreparationScope,
                                            priority: ChapterBookPriority) throws -> ChapterBookDemandIntent {
        try writable(); try validateScope(scope); try validatePriority(priority, scope: scope)
        let old = entries[scope.identifier]
        guard old != nil || entries.count < Self.maximumBooks else { throw ChapterBookJournalError.budget }
        let command = UUID()
        if old != nil { commands[scope.identifier] = command }
        if let old, old.intent.wanted == wanted, old.intent.priority == priority { return old.intent }
        let revision = try increment(old?.intent.revision ?? 0)
        let wantedRevision = old?.intent.wanted == wanted ? old!.intent.wantedRevision : try increment(old?.intent.wantedRevision ?? 0)
        let intent = ChapterBookDemandIntent(scopeID: scope.identifier, accountPartition: accountPartition, deviceID: deviceID,
            revision: revision, wantedRevision: wantedRevision, wanted: wanted, priority: priority)
        var next = entries
        next[scope.identifier] = Entry(scope: try scope.encoded(), intent: intent, chapters: old?.chapters ?? [:], pending: true, serverRevision: nil)
        try persist(next); commands[scope.identifier] = command; return intent
    }
    /// Only scheduling priority changes; existing exact source/options and
    /// wantedRevision survive. Pausing the listener must not call setWanted.
    @discardableResult public func prioritize(_ priority: ChapterBookPriority, scopeID: String) throws -> ChapterBookDemandIntent {
        try writable()
        guard var entry = entries[scopeID] else { throw ChapterBookJournalError.notFound }
        let scope = try ChapterBookPreparationScope.decode(entry.scope)
        try validatePriority(priority, scope: scope)
        commands[scopeID] = UUID()
        if entry.intent.priority == priority { return entry.intent }
        entry.intent = .init(scopeID: scopeID, accountPartition: accountPartition, deviceID: deviceID,
            revision: try increment(entry.intent.revision), wantedRevision: entry.intent.wantedRevision,
            wanted: entry.intent.wanted, priority: priority)
        entry.pending = true; entry.serverRevision = nil
        var next = entries; next[scopeID] = entry; try persist(next); return entry.intent
    }
    package func observeAdmission(scopeID: String, chapterIndex: Int) throws -> ChapterBookAdmission {
        try writable()
        guard let entry = entries[scopeID], entry.intent.wanted else { throw ChapterBookJournalError.staleAdmission }
        let scope = try ChapterBookPreparationScope.decode(entry.scope)
        guard scope.book.chapterKeys.indices.contains(chapterIndex) else { throw ChapterWorkerError.invalidIdentity }
        let command = commands[scopeID] ?? UUID(); commands[scopeID] = command
        return .init(owner: owner, command: command, scopeID: scopeID, wantedRevision: entry.intent.wantedRevision,
                     chapterIndex: chapterIndex, prior: entry.chapters[String(chapterIndex)])
    }
    /// Call only after exact SDK source/portable-plan publishers JOINED and
    /// settled their artifact allowance. Plain references cannot call this API.
    package func attach(_ admission: ChapterBookAdmission, request: ChapterRenderRequest,
                        source: ChapterLocalSourcePublication, plan: ChapterLocalRenderPlanPublication) throws -> ChapterBookDemandIntent {
        let (entry, scope) = try current(admission)
        try scope.validate(request, chapterIndex: admission.chapterIndex)
        guard source.accountPartition == accountPartition,
              try ChapterTextAssetManifest.sourceKey(for: source.source) == ChapterTextAssetManifest.sourceKey(for: request.source),
              plan.accountPartition == accountPartition, plan.sourceReference == source.reference,
              plan.renderKey == (try request.renderKey()) else { throw ChapterWorkerError.invalidIdentity }
        let value = ChapterBookStoredChapter(chapterIndex: admission.chapterIndex, request: request,
            sourceReference: source.reference, renderPlanReference: plan.reference, silentTextSHA256: nil, silentUTF16Length: nil)
        return try attach(value, admission: admission, entry: entry, scope: scope)
    }
    package func attachSilent(_ proof: ChapterBookSilentSource, originalText: String, admission: ChapterBookAdmission) throws -> ChapterBookDemandIntent {
        let (entry, scope) = try current(admission)
        try proof.validate(text: originalText)
        guard proof.chapterIndex == admission.chapterIndex, try proof.book.sha256() == scope.book.sha256() else { throw ChapterWorkerError.invalidIdentity }
        let value = ChapterBookStoredChapter(chapterIndex: proof.chapterIndex, request: nil, sourceReference: nil,
            renderPlanReference: nil, silentTextSHA256: proof.textSHA256, silentUTF16Length: proof.utf16Length)
        return try attach(value, admission: admission, entry: entry, scope: scope)
    }
    private func attach(_ value: ChapterBookStoredChapter, admission: ChapterBookAdmission,
                        entry old: Entry, scope: ChapterBookPreparationScope) throws -> ChapterBookDemandIntent {
        try value.validate(scope: scope)
        if let prior = old.chapters[String(value.chapterIndex)] {
            if let before = prior.request, let after = value.request {
                guard try ChapterTextAssetManifest.sourceKey(for: before.source) == ChapterTextAssetManifest.sourceKey(for: after.source)
                else { throw ChapterWorkerError.invalidIdentity }
            } else {
                guard prior.request == nil, value.request == nil, prior.silentTextSHA256 == value.silentTextSHA256,
                      prior.silentUTF16Length == value.silentUTF16Length else { throw ChapterWorkerError.invalidIdentity }
            }
        }
        if old.intent.priority.chapterIndex == value.chapterIndex {
            guard old.intent.priority.sourceUTF16Offset <= (value.request?.source.utf16Length ?? value.silentUTF16Length ?? 0)
            else { throw ChapterWorkerError.invalidIdentity }
        }
        if old.chapters[String(value.chapterIndex)] == value { return old.intent }
        if old.chapters[String(value.chapterIndex)] == nil,
           entries.values.reduce(0, { $0 + $1.chapters.count }) >= Self.maximumChapters { throw ChapterBookJournalError.budget }
        var entry = old
        entry.chapters[String(value.chapterIndex)] = value
        entry.intent = .init(scopeID: admission.scopeID, accountPartition: accountPartition, deviceID: deviceID,
            revision: try increment(old.intent.revision), wantedRevision: old.intent.wantedRevision,
            wanted: true, priority: old.intent.priority)
        entry.pending = true; entry.serverRevision = nil
        var next = entries; next[admission.scopeID] = entry; try persist(next); return entry.intent
    }
    private func current(_ admission: ChapterBookAdmission) throws -> (Entry, ChapterBookPreparationScope) {
        try writable()
        guard admission.owner == owner, commands[admission.scopeID] == admission.command,
              let entry = entries[admission.scopeID], entry.intent.wanted,
              entry.intent.wantedRevision == admission.wantedRevision,
              entry.chapters[String(admission.chapterIndex)] == admission.prior else { throw ChapterBookJournalError.staleAdmission }
        return (entry, try ChapterBookPreparationScope.decode(entry.scope))
    }
    /// Exact server confirmation is atomic with clearing pending. A global
    /// rendering/ready phase, file or book seal is never this device's receipt.
    @discardableResult public func confirm(_ intent: ChapterBookDemandIntent, serverRevision: ChapterServerRevision) throws -> Bool {
        try writable()
        guard intent.accountPartition == accountPartition, intent.deviceID == deviceID else { throw ChapterWorkerError.accountMismatch }
        guard var entry = entries[intent.scopeID], entry.intent == intent else { return false }
        entry.pending = false; entry.serverRevision = serverRevision.opaqueValue
        var next = entries; next[intent.scopeID] = entry; try persist(next); return true
    }
    public func close() { root = nil; commands.removeAll() }
    func failAfterNextRenameForTesting() { afterRenameForTesting = { throw ChapterBookJournalError.storage } }
    func cancelAfterNextRenameForTesting() { afterRenameForTesting = { withUnsafeCurrentTask { $0?.cancel() } } }
    private func snapshot(_ entry: Entry) throws -> ChapterBookStoredPreparation {
        .init(scope: try .decode(entry.scope), intent: entry.intent,
            chapters: entry.chapters.values.sorted(by: { $0.chapterIndex < $1.chapterIndex }), pending: entry.pending,
            confirmedServerRevision: try entry.serverRevision.map { try .init(opaqueValue: $0) })
    }
    private func writable() throws {
        guard let root else { throw ChapterBookJournalError.closed }
        guard !uncertain else { throw ChapterBookJournalError.ambiguousWrite }
        try Task.checkCancellation(); try root.validate()
    }
    private func validateScope(_ scope: ChapterBookPreparationScope) throws {
        guard scope.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard try ChapterBookPreparationScope.decode(scope.encoded()) == scope else { throw ChapterWorkerError.invalidIdentity }
    }
    private func validatePriority(_ priority: ChapterBookPriority, scope: ChapterBookPreparationScope) throws {
        guard scope.book.chapterKeys.indices.contains(priority.chapterIndex), (0...131072).contains(priority.sourceUTF16Offset) else {
            throw ChapterWorkerError.invalidIdentity
        }
        if let known = entries[scope.identifier]?.chapters[String(priority.chapterIndex)] {
            guard priority.sourceUTF16Offset <= (known.request?.source.utf16Length ?? known.silentUTF16Length ?? 0)
            else { throw ChapterWorkerError.invalidIdentity }
        }
    }
    private func increment(_ value: UInt64) throws -> UInt64 {
        guard value < .max else { throw ChapterBookJournalError.budget }; return value + 1
    }
    private func persist(_ next: [String: Entry]) throws {
        guard let root else { throw ChapterBookJournalError.closed }
        let data = try Self.encode(State(domain: "librox-reader-book-outbox-1", version: 1, binding: binding, entries: next))
        guard data.count <= Self.maximumJournalBytes else { throw ChapterBookJournalError.budget }
        do {
            let fault = afterRenameForTesting; afterRenameForTesting = nil
            try root.write(data, leaf: "journal.json", afterRename: fault)
            entries = next
        } catch { uncertain = true; throw ChapterBookJournalError.ambiguousWrite }
    }
    private static func validate(_ value: Binding, files: ChapterBookJournalFiles, partition: String, deviceID: UUID) throws {
        guard value.domain == "librox-reader-book-binding-1", value.version == 1, value.partition == partition,
              value.deviceID == deviceID, value.directoryDevice == files.device, value.directoryInode == files.inode else {
            throw ChapterBookJournalError.corrupt
        }
    }
    private static func validate(_ entries: [String: Entry], partition: String, deviceID: UUID) throws {
        guard entries.count <= maximumBooks, entries.values.reduce(0, { $0 + $1.chapters.count }) <= maximumChapters else { throw ChapterBookJournalError.budget }
        for (key, entry) in entries {
            let scope = try ChapterBookPreparationScope.decode(entry.scope), intent = entry.intent
            guard scope.identifier == key, scope.accountPartition == partition, intent.scopeID == key,
                  intent.accountPartition == partition, intent.deviceID == deviceID, intent.revision > 0,
                  intent.wantedRevision > 0, intent.wantedRevision <= intent.revision,
                  scope.book.chapterKeys.indices.contains(intent.priority.chapterIndex),
                  (0...131072).contains(intent.priority.sourceUTF16Offset),
                  entry.pending == (entry.serverRevision == nil) else { throw ChapterBookJournalError.corrupt }
            if let revision = entry.serverRevision { _ = try ChapterServerRevision(opaqueValue: revision) }
            for (index, chapter) in entry.chapters {
                guard String(chapter.chapterIndex) == index else { throw ChapterBookJournalError.corrupt }
                try chapter.validate(scope: scope)
                if intent.priority.chapterIndex == chapter.chapterIndex {
                    guard intent.priority.sourceUTF16Offset <= (chapter.request?.source.utf16Length ?? chapter.silentUTF16Length ?? 0)
                    else { throw ChapterBookJournalError.corrupt }
                }
            }
        }
    }
    private static func raw<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    private static func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private static func encode<T: Codable>(_ value: T) throws -> Data { try raw(Checked(value: value, checksum: hash(raw(value)))) }
    private static func decode<T: Codable>(_ type: T.Type, _ bytes: Data) throws -> T {
        do {
            let value = try JSONDecoder().decode(Checked<T>.self, from: bytes)
            guard value.checksum == (try hash(raw(value.value))), try raw(value) == bytes else { throw ChapterBookJournalError.corrupt }
            return value.value
        } catch { throw ChapterBookJournalError.corrupt }
    }
}
