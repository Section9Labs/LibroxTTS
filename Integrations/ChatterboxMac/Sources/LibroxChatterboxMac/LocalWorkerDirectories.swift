#if os(macOS)
import Foundation
import Darwin

public enum ChatterboxMacWorkerError: Error, Sendable, Equatable { case disabled, busy, closed, invalidDirectories }
public struct ChatterboxMacWorkerDirectories: Sendable {
    public let sourcePublications, planPublications, state, exports, custody, publications: URL
    private struct Pin: Sendable {
        let supplied, resolved: URL
        let device: Int32
        let inode: UInt64
        init(_ url: URL) throws {
            guard url.isFileURL, url.standardizedFileURL.path != "/", !url.path.utf8.contains(0) else { throw ChatterboxMacWorkerError.invalidDirectories }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            var a = stat(), b = stat()
            guard lstat(url.path, &a) == 0, lstat(resolved.path, &b) == 0,
                  a.st_mode & S_IFMT == S_IFDIR, a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw ChatterboxMacWorkerError.invalidDirectories }
            supplied = url; self.resolved = resolved; device = a.st_dev; inode = a.st_ino
        }
        func validate() throws {
            var a = stat(), b = stat()
            guard lstat(supplied.path, &a) == 0, lstat(resolved.path, &b) == 0,
                  a.st_mode & S_IFMT == S_IFDIR, b.st_mode & S_IFMT == S_IFDIR,
                  a.st_dev == device, b.st_dev == device, a.st_ino == inode, b.st_ino == inode else { throw ChatterboxMacWorkerError.invalidDirectories }
        }
    }
    private let pins: [Pin]
    public init(sourcePublications: URL, planPublications: URL, state: URL,
                exports: URL, custody: URL, publications: URL) throws {
        let urls = [sourcePublications, planPublications, state, exports, custody, publications]
        let pins = try urls.map(Pin.init)
        for a in pins.indices {
            for b in pins.indices where b > a {
                let x = pins[a].resolved.path, y = pins[b].resolved.path
                let sameID = pins[a].device == pins[b].device && pins[a].inode == pins[b].inode
                if a == 0, b == 1, sameID { continue } // Same immutable Reader metadata root is permitted.
                guard !sameID, x != y, !x.hasPrefix(y + "/"), !y.hasPrefix(x + "/") else { throw ChatterboxMacWorkerError.invalidDirectories }
            }
        }
        self.sourcePublications = sourcePublications; self.planPublications = planPublications
        self.state = state; self.exports = exports; self.custody = custody; self.publications = publications; self.pins = pins
    }
    func validate() throws { for pin in pins { try pin.validate() } }
}
#endif
