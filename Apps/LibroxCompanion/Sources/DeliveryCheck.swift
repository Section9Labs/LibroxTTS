import Foundation
import CloudKit
import CryptoKit
import LibroxChapterWorker
import LibroxChatterboxPlanning
import LibroxChatterboxMac

private actor DeliveryEvidence {
    let output: URL
    private var values: [String: String] = ["check": "native-model-private-icloud-reader-custody", "physicalPhonePlayback": "false"]
    private var failure: String?
    init(output: URL) { self.output = output }
    func update(_ value: ChatterboxCloudWorkerUpdate) {
        values["workerPhase"] = value.phase.rawValue
        values["publishedSegments"] = String(value.publishedSegments)
        if value.phase == .failed { failure = value.message; values["workerError"] = value.message }
        save()
    }
    func error() -> String? { failure }
    func set(_ key: String, _ value: String) { values[key] = value; save() }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        } catch { /* The final report is retried after every boundary. */ }
    }
}

enum CompanionDeliveryCheck {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    @MainActor static func run(model: CompanionModel, output: URL) async {
        let evidence = DeliveryEvidence(output: output), began = Date()
        let readerGate = ChapterAccountSessionGate(), workerGate = ChapterAccountSessionGate()
        var reader: ChatterboxCloudPreparedBookService?, worker: ChatterboxMacCloudBookWorker?
        var readerSession: ChapterAccountSession?, scope: String?
        do {
            guard !_isDebugAssertConfiguration() else { throw Failure(message: "Real inference requires the Release build.") }
            let environment = try model.signedEnvironment()
            guard environment == .development else { throw Failure(message: "The bounded delivery check requires Development iCloud.") }
            let container = CKContainer(identifier: "iCloud.com.section9labs.Libros")
            guard try await container.accountStatus() == .available else { throw CompanionFailure.iCloud }
            let user = try await container.userRecordID()
            let account = try ChapterCloudAccountIdentity(containerIdentifier: "iCloud.com.section9labs.Libros",
                environment: environment, userRecordName: user.recordName)
            let rs = try await readerGate.open(accountPartition: account.accountPartition)
            let ws = try await workerGate.open(accountPartition: account.accountPartition)
            readerSession = rs
            let root = output.deletingPathExtension()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let deviceFile = root.appendingPathComponent("reader-id.txt")
            let device: UUID
            if FileManager.default.fileExists(atPath: deviceFile.path) {
                guard let saved = UUID(uuidString: try String(contentsOf: deviceFile, encoding: .utf8)) else { throw ChapterWorkerError.invalidIdentity }
                device = saved
            } else { device = UUID(); try Data(device.uuidString.utf8).write(to: deviceFile, options: .withoutOverwriting) }
            let policy = try ChapterStorageBudgetPolicy(maximumManagedBytes: 8 * 1024 * 1024 * 1024, minimumAvailableBytes: 1024 * 1024 * 1024)
            let r = try await ChatterboxCloudPreparedBookService.open(container: container, account: account,
                session: rs, gate: readerGate, deviceID: device, readerDirectory: root.appendingPathComponent("Reader"),
                storagePolicy: policy, authorizeTransfer: { try await readerGate.validate(rs) })
            reader = r; try await r.connect(session: rs)
            let w = try await ChatterboxMacCloudBookWorker.open(container: container, account: account,
                session: ws, gate: workerGate, workerDirectory: root.appendingPathComponent("Worker"), assets: model.modelAssets(),
                storagePolicy: policy, authorizeTransfer: { try await workerGate.validate(ws) }, receive: { await evidence.update($0) })
            worker = w; try await w.start()
            var descriptor: ChatterboxStockVoiceDescriptor?
            for _ in 0..<180 {
                if let error = await evidence.error() { throw Failure(message: error) }
                if let catalog = try? await r.catalog(session: rs) { descriptor = catalog.voices.first?.descriptor; break }
                try await Task.sleep(for: .seconds(2))
            }
            guard let descriptor else { throw Failure(message: "Timed out waiting for the prepared native catalog.") }
            let chapters = ["The morning was quiet. A small boat waited beside the old bridge.",
                            "At sunset, the friends returned home. Their adventure had only just begun."]
            let bytes = Data(chapters.joined(separator: "\n\n").utf8)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let source = try ChapterBookSource(bookSHA256: hash, extractionRevision: "companion-self-authored-check-1",
                chapterKeys: ["chapter:0", "chapter:1"])
            let document = try ChatterboxBookDocument(title: "Companion Delivery Check", book: source, chapters: chapters)
            let book = try descriptor.prepareBook(source: source,
                settings: .init(language: "en", delivery: .lossless, direction: .storyteller, grouping: .sentences, seed: 42), session: rs)
            scope = book.scope.identifier
            try await r.setTitle(document.title, scopeID: book.scope.identifier, session: rs)
            _ = try await r.begin(book, source: document, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0), session: rs)
            await evidence.set("scopeID", book.scope.identifier)
            await evidence.set("delivery", "ALAC24 (explicit test policy)")
            var lastSegment: ChatterboxResolvedBookSegment?, lastCompletion: ChatterboxResolvedBookChapterCompletion?
            var verified = 0, finished = false
            for _ in 0..<240 {
                if let error = await evidence.error() { throw Failure(message: error) }
                let resolution: ChatterboxBookResolution
                if let lastCompletion { resolution = try await r.successor(of: lastCompletion, session: rs) }
                else if let lastSegment { resolution = try await r.successor(of: lastSegment, session: rs) }
                else { resolution = try await r.resolve(scopeID: book.scope.identifier, position: .init(chapterIndex: 0, sourceUTF16Offset: 0), session: rs) }
                switch resolution {
                case .segment(let segment):
                    let delivered = try await r.download(segment, session: rs)
                    let path = root.appendingPathComponent("verified-\(segment.chapterIndex)-\(segment.manifest.segmentIndex).m4a")
                    try await delivered.artifact.withFileAccess(session: rs, gate: readerGate) { file in
                        try FileManager.default.copyItem(at: file, to: path)
                    }
                    verified += 1; lastSegment = segment; lastCompletion = nil
                    await evidence.set("verifiedReaderSegments", String(verified))
                case .chapterComplete(let completion): lastCompletion = completion; lastSegment = nil
                case .endOfBook: finished = true
                case .waiting:
                    let status = try await r.status(scopeID: book.scope.identifier, session: rs)
                    if let error = status.lastFailure { throw Failure(message: error) }
                    try await Task.sleep(for: .seconds(2))
                }
                if finished { break }
            }
            guard finished, verified >= 2 else { throw Failure(message: "Timed out before verified completion of both chapters.") }
            await evidence.set("passed", "true")
            await evidence.set("verifiedAudioDirectory", root.path)
        } catch {
            await evidence.set("passed", "false")
            await evidence.set("error", String(describing: error))
        }
        worker?.stopClaims()
        do { try await worker?.close() } catch { await evidence.set("shutdownError", String(describing: error)) }
        if let reader, let readerSession {
            if let scope { _ = try? await reader.cancelPreparation(scopeID: scope, session: readerSession) }
            reader.stopRequests()
            do { try await reader.close(session: readerSession) } catch { await evidence.set("closeError", String(describing: error)) }
        }
        await readerGate.close(); await workerGate.close()
        await evidence.set("joined", "true")
        await evidence.set("wallSeconds", String(Date().timeIntervalSince(began)))
    }
}
