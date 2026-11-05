import AppKit
import SwiftUI
import CloudKit
import ServiceManagement
import Security
import LibroxChapterWorker
import LibroxChatterboxPlanning
import LibroxChatterboxMac

struct CompanionBook: Codable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let file: String
    var scopeID: String?
    var detail: String
    var cloudLibraryID: String? = nil
    var cloudContentHash: String? = nil
    var cloudAccountPartition: String? = nil
}

@MainActor final class CompanionModel: ObservableObject {
    @Published private(set) var books: [CompanionBook] = []
    @Published private(set) var remoteBooks: [ChatterboxCloudBookSummary] = []
    @Published private(set) var libraryBooks: [ChatterboxCloudLibraryBook] = []
    @Published private(set) var libraryStatus = "Loading your iCloud library…"
    @Published private(set) var selectingBook: String?
    @Published private(set) var queueSchemaReady = false
    @Published var librarySearch = ""
    private var cloudLibrary: ChatterboxCloudLibrary?
    private var libraryTask: Task<Void, Never>?
    private var libraryEpoch = UUID()
    private var libraryAccountPartition: String?
    private var queuedSelections: Set<UUID> = []
    private var preparing: Set<UUID> = []
    @Published private(set) var status = "Ready when you are"
    @Published private(set) var detail = "Prepare books here or request them from Librox on your iPhone."
    @Published private(set) var failure: String?
    @Published private(set) var enabled = false
    @Published private(set) var changing = false
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var loginApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var language: String = UserDefaults.standard.string(forKey: "language") ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    @Published var lossless = UserDefaults.standard.bool(forKey: "lossless") {
        didSet { UserDefaults.standard.set(lossless, forKey: "lossless") }
    }
    private let gate = ChapterAccountSessionGate()
    private var session: ChapterAccountSession?
    private var reader: ChatterboxCloudPreparedBookService?
    private var worker: ChatterboxMacCloudBookWorker?
    private var lifecycle: Task<Void, Never>?
    private var lifecycleGeneration = UUID()
    private var reconnectAfterJoin = false
    private var poll: Task<Void, Never>?
    private var actions: [UUID: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var activity: NSObjectProtocol?
    private var epoch = UUID()
    private var terminating = false
    private var resumedSourceScopes: Set<String> = []
    private var securityScopes: [URL] = []
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibroxCompanion", isDirectory: true)
    }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    var canPrepare: Bool { enabled && connected && !changing }

    func start(restoreEnabled: Bool = true, browseLibrary: Bool = true) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: libraryURL.path) {
                books = try JSONDecoder().decode([CompanionBook].self, from: Data(contentsOf: libraryURL))
                queuedSelections = Set(books.filter { $0.detail == "Waiting for this Mac" }.map(\.id))
            }
        } catch { show(error) }
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.accountChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, UserDefaults.standard.bool(forKey: "enabled") else { return }
                if self.changing { self.reconnectAfterJoin = true; return }
                self.setEnabled(true)
            }
        })
        if restoreEnabled, !browseLibrary, UserDefaults.standard.bool(forKey: "enabled") { setEnabled(true) }
        if browseLibrary { startLibrary() }
    }
    var visibleLibraryBooks: [ChatterboxCloudLibraryBook] {
        let query = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return libraryBooks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.author?.localizedCaseInsensitiveContains(query) ?? false) }
    }
    var visiblePreparations: [CompanionBook] {
        books.filter { $0.cloudLibraryID == nil || $0.cloudAccountPartition == libraryAccountPartition }
    }
    private func startLibrary() {
        let previous = libraryTask, stamp = UUID()
        libraryEpoch = stamp; libraryTask?.cancel(); cloudLibrary?.stopRequests()
        libraryBooks = []; remoteBooks = []; libraryAccountPartition = nil; queueSchemaReady = false
        libraryStatus = "Loading your iCloud library…"
        libraryTask = Task { [self] in
            await previous?.value
            let libraryGate = ChapterAccountSessionGate()
            var client: ChatterboxCloudLibrary?
            do {
                try Task.checkCancellation()
                let container = CKContainer(identifier: "iCloud.com.section9labs.Libros")
                guard try await container.accountStatus() == .available else { throw CompanionFailure.iCloud }
                let user = try await container.userRecordID()
                let account = try ChapterCloudAccountIdentity(containerIdentifier: "iCloud.com.section9labs.Libros",
                    environment: signedEnvironment(), userRecordName: user.recordName)
                let session = try await libraryGate.open(accountPartition: account.accountPartition)
                let library = try ChatterboxCloudLibrary(container: container, account: account, session: session, gate: libraryGate)
                client = library
                if libraryEpoch == stamp { cloudLibrary = library; libraryAccountPartition = account.accountPartition }
                while !Task.isCancelled {
                    do {
                        let result = try await library.refresh()
                        try Task.checkCancellation()
                        guard libraryEpoch == stamp else { break }
                        libraryBooks = result
                        libraryStatus = result.isEmpty ? "Books you add in Librox will appear here after iCloud syncs." : "\(result.count) books · Recently opened first"
                        let ready = try await library.queueSchemaAvailable()
                        guard libraryEpoch == stamp, !Task.isCancelled else { break }
                        queueSchemaReady = ready
                        if !ready {
                            status = "Your library is connected"
                            detail = "Audiobook preparation is waiting for iCloud setup. You can still choose books."
                        } else if UserDefaults.standard.bool(forKey: "enabled"), !enabled, !changing,
                                  !CommandLine.arguments.contains("--library-only") { setEnabled(true) }
                        if let requests = try? await library.preparationRequests(), libraryEpoch == stamp, !Task.isCancelled {
                            remoteBooks = requests
                        }
                    } catch {
                        if Task.isCancelled { break }
                        if libraryEpoch == stamp { libraryStatus = error.localizedDescription }
                    }
                    try await Task.sleep(for: .seconds(45))
                }
            } catch { if !Task.isCancelled, libraryEpoch == stamp { libraryStatus = error.localizedDescription } }
            client?.stopRequests(); await client?.close(); await libraryGate.close()
            if libraryEpoch == stamp { cloudLibrary = nil }
        }
    }
    func refreshLibrary() {
        guard let cloudLibrary else { startLibrary(); return }
        let stamp = libraryEpoch
        runAction { [self] in
            let result = try await cloudLibrary.refresh()
            guard stamp == libraryEpoch else { return }
            libraryBooks = result
            libraryStatus = "\(result.count) books · Recently opened first"
        }
    }
    func selectLibraryBook(_ book: ChatterboxCloudLibraryBook) {
        guard selectingBook == nil, let cloudLibrary else { return }
        selectingBook = book.id
        let stamp = libraryEpoch
        runAction { [self] in
            defer { selectingBook = nil }
            let id: UUID
            if book.contentSHA256 != nil, let existing = books.first(where: { $0.cloudLibraryID == book.id && $0.cloudContentHash == book.contentSHA256 && $0.cloudAccountPartition == libraryAccountPartition }) {
                id = existing.id
            } else {
                let file = try await cloudLibrary.download(book, to: root.appendingPathComponent("LibraryDownloads"))
                defer { try? FileManager.default.removeItem(at: file) }
                let task = Task.detached(priority: .userInitiated) { try BookImport.load(file) }
                let parsed = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                guard stamp == libraryEpoch else { throw CancellationError() }
                let document = try ChatterboxBookDocument(title: book.title, book: parsed.book, chapters: parsed.chapters)
                id = UUID(); let filename = id.uuidString + ".libroxbook"
                try document.encoded().write(to: root.appendingPathComponent(filename), options: .withoutOverwriting)
                books.insert(.init(id: id, title: book.title, file: filename, scopeID: nil, detail: "Waiting for this Mac",
                                   cloudLibraryID: book.id, cloudContentHash: book.contentSHA256,
                                   cloudAccountPartition: libraryAccountPartition), at: 0)
                try saveLibrary()
            }
            guard stamp == libraryEpoch else { throw CancellationError() }
            if let index = books.firstIndex(where: { $0.id == id }) {
                books[index].detail = "Waiting for this Mac"; try saveLibrary()
            }
            if canPrepare { prepare(id) }
            else { queuedSelections.insert(id); if !enabled, queueSchemaReady { setEnabled(true) } }
        }
    }
    private func saveLibrary() throws {
        try JSONEncoder().encode(books).write(to: libraryURL, options: .atomic)
    }
    func importBook() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "epub") ?? .data, .plainText, .json,
                                     .init(filenameExtension: "libroxbook") ?? .json]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a book to prepare with Chatterbox Multilingual."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.importBook(at: url) }
        }
    }
    func importBook(at url: URL) {
        runAction { [self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let task = Task.detached(priority: .userInitiated) { try BookImport.load(url) }
            let document = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard books.count < 64 else { throw BookImport.Failure.tooLarge }
            let id = UUID(), filename = id.uuidString + ".libroxbook"
            try document.encoded().write(to: root.appendingPathComponent(filename), options: .withoutOverwriting)
            books.insert(.init(id: id, title: document.title, file: filename, scopeID: nil, detail: "Not prepared"), at: 0)
            try saveLibrary()
        }
    }
    func prepare(_ id: UUID) {
        guard canPrepare, !preparing.contains(id), let reader, let session, let book = books.first(where: { $0.id == id }) else { return }
        guard book.cloudAccountPartition == nil || book.cloudAccountPartition == session.accountPartition else { return }
        preparing.insert(id)
        runAction { [self] in
            defer { preparing.remove(id) }
            let doc = try ChatterboxBookDocument.decode(Data(contentsOf: root.appendingPathComponent(book.file)))
            let catalog = try await reader.catalog(session: session)
            guard let voice = catalog.voices.first else { throw ChatterboxCloudServiceError.notReady }
            let settings = try ChatterboxBookRenderSettings(language: language, delivery: lossless ? .lossless : .smaller,
                direction: .storyteller, grouping: .sentences, seed: 42)
            let prepared = try voice.descriptor.prepareBook(source: doc.book, settings: settings, session: session)
            try await reader.setTitle(doc.title, scopeID: prepared.scope.identifier, session: session)
            _ = try await reader.begin(prepared, source: doc, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0), session: session)
            try await gate.validate(session); try Task.checkCancellation()
            if let index = books.firstIndex(where: { $0.id == id }) {
                books[index].scopeID = prepared.scope.identifier; books[index].detail = "Preparing"; try saveLibrary()
                queuedSelections.remove(id)
            }
        }
    }
    func cancel(_ id: UUID) {
        if let index = books.firstIndex(where: { $0.id == id }), books[index].scopeID == nil {
            queuedSelections.remove(id); books[index].detail = "Stopped"
            do { try saveLibrary() } catch { show(error) }
            return
        }
        guard let reader, let session, let book = books.first(where: { $0.id == id }), let scope = book.scopeID else { return }
        runAction { [self] in
            _ = try await reader.cancelPreparation(scopeID: scope, session: session)
            try await gate.validate(session)
            if let index = books.firstIndex(where: { $0.id == id }) { books[index].detail = "Stopped"; try saveLibrary() }
        }
    }
    private func runAction(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !terminating else { return }
        let id = UUID(), stamp = epoch
        actions[id] = Task { [weak self] in
            defer { self?.actions[id] = nil }
            do { try await operation() }
            catch { if self?.epoch == stamp, !Task.isCancelled { self?.show(error) } }
        }
    }
    func setEnabled(_ value: Bool) {
        guard !changing, !terminating else { return }
        changing = true; failure = nil
        let generation = UUID(); lifecycleGeneration = generation
        UserDefaults.standard.set(value, forKey: "enabled")
        lifecycle = Task { [self] in
            defer { finishLifecycle(generation) }
            if value {
                do { try await connect() }
                catch {
                    await stop()
                    if lifecycleGeneration == generation, !Task.isCancelled {
                        status = "Needs attention"; show(error)
                        UserDefaults.standard.set(false, forKey: "enabled")
                    }
                }
            } else { await stop() }
        }
    }
    private func connect() async throws {
        let stamp = UUID(); epoch = stamp
        status = "Connecting to iCloud"; detail = "Using your private Librox library."
        let environment = try signedEnvironment()
        let container = CKContainer(identifier: "iCloud.com.section9labs.Libros")
        guard try await container.accountStatus() == .available else { throw CompanionFailure.iCloud }
        let accountID = try await container.userRecordID()
        try Task.checkCancellation()
        guard epoch == stamp else { throw CancellationError() }
        let account = try ChapterCloudAccountIdentity(containerIdentifier: "iCloud.com.section9labs.Libros",
            environment: environment, userRecordName: accountID.recordName)
        let session = try await gate.open(accountPartition: account.accountPartition)
        self.session = session
        let partition = root.appendingPathComponent(account.accountPartition)
        let policy = try ChapterStorageBudgetPolicy(maximumManagedBytes: 20 * 1024 * 1024 * 1024, minimumAvailableBytes: 2 * 1024 * 1024 * 1024)
        let deviceID: UUID
        if let stored = UserDefaults.standard.string(forKey: "readerID"), let id = UUID(uuidString: stored) { deviceID = id }
        else { deviceID = UUID(); UserDefaults.standard.set(deviceID.uuidString, forKey: "readerID") }
        let gate = self.gate
        let authorize: @Sendable () async throws -> Void = {
            try Task.checkCancellation(); try await gate.validate(session)
        }
        let reader = try await ChatterboxCloudPreparedBookService.open(container: container, account: account,
            session: session, gate: gate, deviceID: deviceID, readerDirectory: partition.appendingPathComponent("Reader"),
            storagePolicy: policy, authorizeTransfer: authorize)
        self.reader = reader
        try await reader.connect(session: session)
        let assets = try modelAssets()
        let worker = try await ChatterboxMacCloudBookWorker.open(container: container, account: account, session: session,
            gate: gate, workerDirectory: partition.appendingPathComponent("Worker"), assets: assets,
            storagePolicy: policy, authorizeTransfer: authorize) { [weak self] update in
                await self?.update(update, epoch: stamp)
            }
        self.worker = worker
        enabled = true
        try await worker.start()
        poll = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    remoteBooks = try await reader.books(session: session)
                    _ = try await reader.catalog(session: session)
                    try await gate.validate(session)
                    connected = true
                    if !changing {
                        let selected = queuedSelections
                        for id in selected { prepare(id) }
                    }
                    try await reader.retryPending(session: session)
                    for book in books where book.scopeID != nil && book.detail == "Preparing" {
                        if let scope = book.scopeID {
                            let update = try await reader.status(scopeID: scope, session: session)
                            if update.admittedSpineEntries < update.totalSpineEntries, !resumedSourceScopes.contains(scope) {
                                resumedSourceScopes.insert(scope)
                                let document = try ChatterboxBookDocument.decode(Data(contentsOf: root.appendingPathComponent(book.file)))
                                try await reader.resumeSourceAdmission(scopeID: scope, source: document, session: session)
                            }
                            if case .complete = update.phase, let index = books.firstIndex(where: { $0.id == book.id }) {
                                books[index].detail = "Ready in iCloud"; try saveLibrary()
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    // Model cold start has no catalog yet. Surface other errors.
                    if !(error is ChatterboxCloudServiceError) { failure = error.localizedDescription }
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
            }
        }
    }
    private func update(_ update: ChatterboxCloudWorkerUpdate, epoch stamp: UUID) {
        guard epoch == stamp, !terminating else { return }
        busy = update.phase == .rendering || update.phase == .publishing || update.phase == .loading
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Preparing a Librox audiobook")
        } else if !busy, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        switch update.phase {
        case .loading: status = "Loading narration"; detail = "Chatterbox Multilingual · English and Spanish"
        case .waiting: status = "Ready for books"; detail = "Requests from your iPhone will appear here."
        case .rendering, .publishing:
            status = update.phase == .rendering ? "Preparing audiobook" : "Sending audio to iCloud"
            detail = [update.bookTitle, update.chapterIndex.map { "Chapter \($0 + 1) of \(update.totalChapters)" },
                      "\(update.publishedSegments) audio parts sent"].compactMap { $0 }.joined(separator: " · ")
        case .failed: status = "Needs attention"; failure = update.message
        case .stopped: status = "Preparation paused"; detail = "Your requests and completed audio are saved."
        }
    }
    private func accountChanged() {
        queuedSelections.removeAll(); startLibrary()
        reconnectAfterJoin = false
        UserDefaults.standard.set(false, forKey: "enabled")
        epoch = UUID(); worker?.stopClaims(); reader?.stopRequests(); lifecycle?.cancel()
        setStoppedAfterEvent(message: "iCloud account changed. Enable preparation to reconnect.")
    }
    private func suspend() {
        epoch = UUID(); worker?.stopClaims(); reader?.stopRequests(); lifecycle?.cancel()
        setStoppedAfterEvent(message: "Waiting for this Mac to wake.")
    }
    private func setStoppedAfterEvent(message: String) {
        let previous = lifecycle, generation = UUID()
        lifecycleGeneration = generation; changing = true
        lifecycle = Task { [self] in
            await previous?.value; await stop()
            if lifecycleGeneration == generation { detail = message }
            finishLifecycle(generation)
        }
    }
    private func finishLifecycle(_ generation: UUID) {
        guard lifecycleGeneration == generation else { return }
        changing = false; lifecycle = nil
        if reconnectAfterJoin, !terminating, UserDefaults.standard.bool(forKey: "enabled") {
            reconnectAfterJoin = false; setEnabled(true)
        }
    }
    func prepareForExit() {
        libraryTask?.cancel(); cloudLibrary?.stopRequests()
        terminating = true; epoch = UUID(); worker?.stopClaims(); reader?.stopRequests()
        lifecycle?.cancel(); poll?.cancel(); actions.values.forEach { $0.cancel() }
    }
    func stopForExit() async {
        prepareForExit(); await lifecycle?.value; await stop(); await libraryTask?.value
    }
    private func stop() async {
        epoch = UUID(); worker?.stopClaims(); reader?.stopRequests()
        poll?.cancel(); await poll?.value; poll = nil
        let pending = Array(actions.values); pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        do { try await worker?.close() } catch { show(error) }
        if let reader, let session {
            do { try await reader.close(session: session) } catch { show(error) }
        }
        await gate.close()
        worker = nil; reader = nil; session = nil
        securityScopes.forEach { $0.stopAccessingSecurityScopedResource() }; securityScopes.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        enabled = false; connected = false; busy = false; remoteBooks = []
        status = "Preparation paused"; detail = "Your requests and completed audio are saved."
    }
    func setLogin(_ value: Bool) {
        runAction { [self] in
            if value { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginApproval = SMAppService.mainApp.status == .requiresApproval
        }
    }
    func retry() {
        failure = nil
        resumedSourceScopes.removeAll()
        if let worker { runAction { try await worker.retryFailed() } }
        else { setEnabled(true) }
    }
    func revealFiles() { NSWorkspace.shared.open(root) }
    private func show(_ error: Error) { failure = error.localizedDescription }

    /// Signed-host diagnostic: account/zone setup only, with no model or book.
    func checkCloud(to output: URL) async {
        var result: [String: String] = ["check": "signed-private-cloud", "modelLoaded": "false"]
        do {
            let environment = try signedEnvironment()
            result["environment"] = environment.rawValue
            let container = CKContainer(identifier: "iCloud.com.section9labs.Libros")
            let status = try await container.accountStatus()
            result["accountAvailable"] = String(status == .available)
            guard status == .available else { throw CompanionFailure.iCloud }
            let user = try await container.userRecordID()
            let account = try ChapterCloudAccountIdentity(containerIdentifier: "iCloud.com.section9labs.Libros",
                environment: environment, userRecordName: user.recordName)
            let session = try await gate.open(accountPartition: account.accountPartition)
            self.session = session
            let reader = try await ChatterboxCloudPreparedBookService.open(container: container, account: account,
                session: session, gate: gate, deviceID: UUID(),
                readerDirectory: output.deletingLastPathComponent().appendingPathComponent("cloud-check-" + UUID().uuidString),
                storagePolicy: .init(maximumManagedBytes: 128 * 1024 * 1024, minimumAvailableBytes: 0),
                authorizeTransfer: { try await self.gate.validate(session) })
            self.reader = reader
            try await reader.connect(session: session)
            result["zoneReady"] = "true"
            let books = try await reader.books(session: session)
            result["listedBooks"] = String(books.count)
            result["passed"] = "true"
        } catch { result["passed"] = "false"; result["error"] = String(describing: error) }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        } catch { show(error) }
    }

    func signedEnvironment() throws -> ChapterCloudAccountIdentity.Environment {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let environment = entitlements["com.apple.developer.icloud-container-environment"] as? String,
              let parsed = ChapterCloudAccountIdentity.Environment(rawValue: environment.lowercased()),
              (entitlements["com.apple.developer.icloud-container-identifiers"] as? [String])?.contains("iCloud.com.section9labs.Libros") == true else {
            throw CompanionFailure.signing
        }
        return parsed
    }
    func checkLibrary(to output: URL) async {
        var report: [String: String] = ["check": "read-only-existing-librox-library", "modelLoaded": "false"]
        let libraryGate = ChapterAccountSessionGate()
        var library: ChatterboxCloudLibrary?
        do {
            let container = CKContainer(identifier: "iCloud.com.section9labs.Libros")
            let environment = try signedEnvironment()
            report["environment"] = environment.rawValue
            guard try await container.accountStatus() == .available else { throw CompanionFailure.iCloud }
            let user = try await container.userRecordID()
            let account = try ChapterCloudAccountIdentity(containerIdentifier: "iCloud.com.section9labs.Libros", environment: environment, userRecordName: user.recordName)
            let session = try await libraryGate.open(accountPartition: account.accountPartition)
            let client = try ChatterboxCloudLibrary(container: container, account: account, session: session, gate: libraryGate)
            library = client
            let result = try await client.refresh()
            report["books"] = String(result.count)
            report["recentlyOpenedBooks"] = String(result.filter { $0.lastOpened != nil }.count)
            report["queueReady"] = String(try await client.queueSchemaAvailable())
            let schemaProbe = CKQueryOperation(query: CKQuery(recordType: "LibroxStockCatalogV1", predicate: NSPredicate(value: true)))
            schemaProbe.resultsLimit = 1; schemaProbe.desiredKeys = []
            do {
                let _: Void = try await ChapterCloudOperation.run(schemaProbe, database: container.privateCloudDatabase) { @Sendable done in
                    schemaProbe.queryResultBlock = { done($0.map { _ in () }) }
                }
                report["queueSchemaProbe"] = "available"
            } catch { report["queueSchemaProbe"] = String(describing: error) }
            let titleFlag = CommandLine.arguments.firstIndex(of: "--check-library-title")
            let requestedTitle = titleFlag.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
            let chosen = result.first(where: { $0.canPrepare && $0.title.localizedCaseInsensitiveContains(requestedTitle ?? "Alice") })
                ?? (requestedTitle == nil ? result.first(where: { $0.canPrepare }) : nil)
            if requestedTitle != nil, chosen == nil { throw ChatterboxCloudLibraryError.invalidRecord }
            if let book = chosen {
                report["stage"] = "download"
                let file = try await client.download(book, to: output.deletingPathExtension())
                defer { try? FileManager.default.removeItem(at: file) }
                report["downloadVerified"] = "true"
                report["fileBytes"] = String(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                report["stage"] = "import"
                let task = Task.detached { try BookImport.load(file) }
                let document = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                report["narrationSections"] = String(document.chapters.count)
                report["maximumSectionUTF16"] = String(document.chapters.map { $0.utf16.count }.max() ?? 0)
                report["splitSpineEntries"] = String(Set(document.book.chapterKeys.filter { $0.contains(":utf16:") }.map { $0.components(separatedBy: ":utf16:")[0] }).count)
                report["originalSpineEntries"] = String(Set(document.book.chapterKeys.map { $0.components(separatedBy: ":utf16:")[0] }).count)
                report["extractionRevision"] = document.book.extractionRevision
            }
            report["stage"] = "complete"
            report["passed"] = "true"
        } catch { report["passed"] = "false"; report["error"] = String(describing: error) }
        library?.stopRequests(); await library?.close(); await libraryGate.close()
        report["joined"] = "true"
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        } catch { show(error) }
    }
    private struct Asset: Decodable { let parameter: String; let path: String }
    private struct AssetManifest: Decodable { let assets: [Asset] }
    func modelAssets() throws -> ChatterboxMacModelAssets {
        let installed = root.appendingPathComponent("model-pack.json")
        guard FileManager.default.fileExists(atPath: installed.path) else { throw CompanionFailure.models }
        let manifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: installed))
        func asset(_ key: String) throws -> URL {
            guard let item = manifest.assets.first(where: { $0.parameter == key }), FileManager.default.fileExists(atPath: item.path) else {
                throw CompanionFailure.models
            }
            return URL(fileURLWithPath: item.path)
        }
        return try .init(metallib: asset("metallib"), acousticCheckpoint: asset("acousticCheckpoint"),
            decoderWeights: asset("decoderWeights"), decoderOracle: asset("decoderOracle"),
            frontendDirectory: asset("frontendDirectory"), stockConditioning: asset("stockConditioning"))
    }
    func installModels() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.message = "Choose the model-pack.json supplied with the Librox narration files."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    let data = try Data(contentsOf: url)
                    let manifest = try JSONDecoder().decode(AssetManifest.self, from: data)
                    guard manifest.assets.count == 6 else { throw CompanionFailure.models }
                    try data.write(to: self.root.appendingPathComponent("model-pack.json"), options: .atomic)
                    self.failure = nil
                } catch { self.show(error) }
            }
        }
    }
}

enum CompanionFailure: LocalizedError {
    case iCloud, signing, models
    var errorDescription: String? {
        switch self {
        case .iCloud: "Sign in to iCloud in System Settings, then enable preparation again."
        case .signing: "This copy of Librox Companion is missing its iCloud signature. Rebuild with the supplied signing script."
        case .models: "The narration files are unavailable. Connect the drive containing them or choose Narration Files in Settings."
        }
    }
}
