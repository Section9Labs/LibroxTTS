import Foundation

/// Recoverable publication inside the host's serialized, private installation.
/// Existing compiled/receipt formats stay unchanged. Only transaction-owned
/// UUID directories are considered or cleaned; validation always checks bytes.
struct PreparedModelTransaction {
    struct Operations {
        var exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        var children: (URL) throws -> [URL] = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
        var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }
    let root: URL
    var operations = Operations()
    var current: URL { root.appendingPathComponent("compiled") }

    private func owned(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.pathComponents
            == root.resolvingSymlinksInPath().standardizedFileURL.pathComponents else { return false }
        let name = url.lastPathComponent
        for prefix in ["previous-", "compile-"] where name.hasPrefix(prefix) {
            if UUID(uuidString: String(name.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }

    func recover(validate: (URL) throws -> Void) throws -> Bool {
        func valid(_ url: URL) throws -> Bool {
            guard operations.exists(url) else { return false }
            do { try validate(url); return true }
            catch is CancellationError { throw CancellationError() }
            catch { return false }
        }
        if try valid(current) { cleanup(); return true }
        let candidates = try operations.children(root).filter(owned).sorted {
            let left = $0.lastPathComponent, right = $1.lastPathComponent
            if left.hasPrefix("previous-") != right.hasPrefix("previous-") { return left.hasPrefix("previous-") }
            return left < right
        }
        for candidate in candidates {
            try Task.checkCancellation()
            if try valid(candidate) {
                try publishValidated(candidate)
                return true
            }
        }
        // Preserve incomplete/old generations until a replacement is ready.
        return false
    }

    /// The caller has already verified or freshly hashed every staged file.
    /// No cancellation point separates the two renames. A crash between them
    /// leaves a recognizable previous generation for the next prepare call.
    func publishValidated(_ staging: URL) throws {
        guard owned(staging) else { throw CocoaError(.fileWriteInvalidFileName) }
        let backup = root.appendingPathComponent("previous-" + UUID().uuidString)
        let previous = operations.exists(current)
        if previous { try operations.move(current, backup) }
        do { try operations.move(staging, current) }
        catch {
            if previous, !operations.exists(current), operations.exists(backup) {
                try? operations.move(backup, current)
            }
            throw error
        }
        cleanup()
    }

    private func cleanup() {
        // Cleanup cannot invalidate a committed installation. Failure leaves
        // recoverable artifacts for the next preparation, never a false failure.
        guard let entries = try? operations.children(root) else { return }
        for entry in entries where owned(entry) { try? operations.remove(entry) }
    }
}
