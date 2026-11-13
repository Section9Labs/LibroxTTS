import Foundation

struct NarrationTransport: Sendable {
    var fetch: @Sendable (URL, Data?) async throws -> (URL, URLResponse) = { url, resume in
        if let resume { return try await URLSession.shared.download(resumeFrom: resume) }
        return try await URLSession.shared.download(from: url)
    }
    func run(_ plan: NarrationDownloadPlan, to root: URL, cache: URL, concurrency: Int,
             progress: (@Sendable (Double) -> Void)?) async throws {
        let limit = min(4, max(1, concurrency))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let store = ArtifactCache(root: cache)
        let tracker = Progress(total: plan.downloadSize, callback: progress)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func submit(_ index: Int) {
                let file = plan.files[index]
                group.addTask {
                    try Task.checkCancellation()
                    let target = try DownloadFileInstallation.target(file.installed.path, in: root)
                    if try NarrationAssets.matches(target, size: file.installed.size, sha256: file.installed.sha256) {
                        await tracker.add(file.downloadSize)
                        return
                    }
                    var urls: [URL] = []
                    for artifact in file.artifacts {
                        try Task.checkCancellation()
                        urls.append(try await obtain(artifact, store: store))
                        await tracker.add(artifact.size)
                    }
                    try NarrationDownloads.install(file, from: urls, in: root)
                }
            }
            while next < min(limit, plan.files.count) { submit(next); next += 1 }
            while let _ = try await group.next() {
                if next < plan.files.count { submit(next); next += 1 }
            }
        }
        if plan.files.isEmpty { progress?(1) }
    }
    private actor Progress {
        let total: Int64
        let callback: (@Sendable (Double) -> Void)?
        var completed: Int64 = 0
        init(total: Int64, callback: (@Sendable (Double) -> Void)?) { self.total = total; self.callback = callback }
        func add(_ bytes: Int64) {
            completed += bytes
            callback?(Double(completed) / Double(max(1, total)))
        }
    }
    private func obtain(_ artifact: NarrationDownloadPlan.Artifact, store: ArtifactCache) async throws -> URL {
        let receipt = store.root.appendingPathComponent(artifact.sha256 + ".resume")
        if let target = try await store.lookup(artifact) { return target }
        let resume = try? Data(contentsOf: receipt)
        let result: (URL, URLResponse)
        do {
            do { result = try await fetch(artifact.url, resume) }
            catch {
                if let data = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                    try? data.write(to: receipt, options: .atomic)
                }
                // Invalid/stale resume metadata may be discarded; cancellation
                // never starts another transfer. Fresh transfers remain hash-pinned.
                try Task.checkCancellation()
                guard resume != nil else { throw error }
                try? FileManager.default.removeItem(at: receipt)
                result = try await fetch(artifact.url, nil)
            }
        } catch {
            if let data = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                try? data.write(to: receipt, options: .atomic)
            }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: result.0) }
        guard let response = result.1 as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
            // A resumed request can return an expired redirect or rejected range
            // as an HTTP response rather than throw. The next retry must start
            // from the pinned URL, not reuse that unusable resume metadata.
            try? FileManager.default.removeItem(at: receipt)
            throw URLError(.badServerResponse)
        }
        guard try NarrationAssets.matches(result.0, size: artifact.size, sha256: artifact.sha256) else {
            try? FileManager.default.removeItem(at: receipt)
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        let target = try await store.save(result.0, artifact: artifact)
        try? FileManager.default.removeItem(at: receipt)
        return target
    }
    private actor ArtifactCache {
        let root: URL
        init(root: URL) { self.root = root }
        func lookup(_ artifact: NarrationDownloadPlan.Artifact) throws -> URL? {
            let target = root.appendingPathComponent(artifact.sha256 + ".part")
            if try NarrationAssets.matches(target, size: artifact.size, sha256: artifact.sha256) { return target }
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        func save(_ source: URL, artifact: NarrationDownloadPlan.Artifact) throws -> URL {
            if let existing = try lookup(artifact) { return existing }
            let target = root.appendingPathComponent(artifact.sha256 + ".part")
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
    }

}
