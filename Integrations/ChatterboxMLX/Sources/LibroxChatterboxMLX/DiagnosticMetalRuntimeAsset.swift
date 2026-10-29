#if os(macOS)
import Foundation
import CryptoKit
import Darwin

/// Exact SwiftPM shader asset for this frozen diagnostic runtime. Holds the
/// descriptor through initialization and checks pathname/descriptor identity
/// and bytes on both sides of Metal's immediate reopen/load.
final class DiagnosticMetalRuntimeAsset {
    static let sha256 = "282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f"
    static let size = 2_401_016
    enum Failure: Error { case identity }
    let url: URL
    private let file: FileHandle, initial: stat
    init(url: URL, expectedSHA256: String) throws {
        guard expectedSHA256 == Self.sha256 else { throw Failure.identity }
        let handle = try FileHandle(forReadingFrom: url)
        do {
            var state = stat()
            guard fstat(handle.fileDescriptor, &state) == 0, state.st_size == Self.size else { throw Failure.identity }
            self.url = url; file = handle; initial = state
            try verify()
        } catch { try? handle.close(); throw error }
    }
    deinit { try? file.close() }
    func verify() throws {
        var descriptor = stat(), path = stat()
        guard fstat(file.fileDescriptor, &descriptor) == 0,
            url.withUnsafeFileSystemRepresentation({ p in p.map { fstatat(AT_FDCWD, $0, &path, 0) } ?? -1 }) == 0,
            same(descriptor), same(path) else { throw Failure.identity }
        try file.seek(toOffset: 0)
        guard let data = try file.read(upToCount: Self.size + 1), data.count == Self.size,
            try file.read(upToCount: 1)?.isEmpty != false,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.sha256,
            fstat(file.fileDescriptor, &descriptor) == 0, same(descriptor)
        else { throw Failure.identity }
    }
    private func same(_ value: stat) -> Bool {
        value.st_dev == initial.st_dev && value.st_ino == initial.st_ino && value.st_size == initial.st_size &&
            value.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec
    }
}
#endif
