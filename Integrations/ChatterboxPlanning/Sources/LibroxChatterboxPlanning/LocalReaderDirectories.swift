import Foundation
import Darwin
import LibroxChapterWorker

/// Existing private role roots. Reader writes only sources/plans/outbox/authority/
/// artifacts; Worker publications are read-only. Never pass a library/model root.
public struct ChatterboxLocalReaderDirectories: Sendable {
    public let sources, plans, outbox, authority, artifacts, publications: URL
    private struct Pin: Sendable {
        let supplied, resolved: URL
        let device: Int32
        let inode: UInt64
        init(_ url: URL) throws {
            guard url.isFileURL, url.standardizedFileURL.path != "/", !url.path.utf8.contains(0) else { throw ChapterStorageBudgetError.invalidConfiguration }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            var a = stat(), b = stat()
            guard lstat(url.path, &a) == 0, lstat(resolved.path, &b) == 0,
                  a.st_mode & S_IFMT == S_IFDIR, a.st_dev == b.st_dev, a.st_ino == b.st_ino
            else { throw ChapterStorageBudgetError.invalidConfiguration }
            supplied = url; self.resolved = resolved; device = a.st_dev; inode = a.st_ino
        }
        func validate() throws {
            var a = stat(), b = stat()
            guard lstat(supplied.path, &a) == 0, lstat(resolved.path, &b) == 0,
                  a.st_mode & S_IFMT == S_IFDIR, b.st_mode & S_IFMT == S_IFDIR,
                  a.st_dev == device, b.st_dev == device, a.st_ino == inode, b.st_ino == inode
            else { throw ChapterStorageBudgetError.invalidConfiguration }
        }
    }
    private let pins: [Pin]
    public init(sources: URL, plans: URL, outbox: URL, authority: URL, artifacts: URL, publications: URL) throws {
        let pins = try [sources, plans, outbox, authority, artifacts, publications].map(Pin.init)
        for a in pins.indices {
            for b in pins.indices where b > a {
                let x = pins[a], y = pins[b]
                guard !(x.device == y.device && x.inode == y.inode), x.resolved.path != y.resolved.path,
                      !x.resolved.path.hasPrefix(y.resolved.path + "/"), !y.resolved.path.hasPrefix(x.resolved.path + "/")
                else { throw ChapterStorageBudgetError.invalidConfiguration }
            }
        }
        self.sources = sources; self.plans = plans; self.outbox = outbox; self.authority = authority
        self.artifacts = artifacts; self.publications = publications; self.pins = pins
    }
    package func validate() throws { for pin in pins { try pin.validate() } }
}
