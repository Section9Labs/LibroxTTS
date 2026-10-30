#if os(macOS)
import Foundation
import CryptoKit
import Darwin

/// Shared MLX Swift 0.32.3 runtime asset, not a model or compressed checkpoint.
/// A relocated executable cannot rely on SwiftPM's adjacent resource lookup.
/// Retain the descriptor and verify exact path/descriptor identity around MLX's
/// immediate reopening. No array operation or Metal computation happens here.
final class AcousticRuntimeAsset {
    static let sha256 = "282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f"
    static let bytes = 2_401_016
    let url: URL
    private let file: FileHandle
    private let identity: stat

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            var value = stat()
            guard fstat(handle.fileDescriptor, &value) == 0, value.st_size == Self.bytes,
                  value.st_mode & S_IFMT == S_IFREG else { throw AcousticInventoryError.identity }
            self.url = url; self.file = handle; self.identity = value
            try verify()
        } catch { try? handle.close(); throw error }
    }
    deinit { try? file.close() }
    func verify() throws {
        try Task.checkCancellation()
        var descriptor = stat(), path = stat()
        guard fstat(file.fileDescriptor, &descriptor) == 0, stat(url.path, &path) == 0,
              same(descriptor), same(path) else { throw AcousticInventoryError.identity }
        try file.seek(toOffset: 0)
        guard let data = try file.read(upToCount: Self.bytes + 1), data.count == Self.bytes,
              try file.read(upToCount: 1)?.isEmpty != false,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.sha256,
              fstat(file.fileDescriptor, &descriptor) == 0, stat(url.path, &path) == 0,
              same(descriptor), same(path) else { throw AcousticInventoryError.identity }
    }
    private func same(_ value: stat) -> Bool {
        value.st_dev == identity.st_dev && value.st_ino == identity.st_ino && value.st_size == identity.st_size &&
        value.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec
    }
}
#endif
