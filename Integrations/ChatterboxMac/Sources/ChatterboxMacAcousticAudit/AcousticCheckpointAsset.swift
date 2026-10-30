#if os(macOS)
import Foundation
import CryptoKit
import Darwin

/// Verified descriptor retained across lazy tensor loading; no model operations.
final class AcousticCheckpointAsset {
    let header: [String: AcousticTensor]
    let digest: String
    private let file: FileHandle
    private let initial: stat
    private let url: URL
    init(modelFile: URL, check: () throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: modelFile)
        var initial = stat()
        guard fstat(handle.fileDescriptor, &initial) == 0,
              initial.st_size == AcousticInventory.checkpointBytes, (initial.st_mode & S_IFMT) == S_IFREG,
              let lengthBytes = try handle.read(upToCount: 8), lengthBytes.count == 8
        else { throw AcousticInventoryError.identity }
        let headerLength = lengthBytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard (2...16_777_216).contains(headerLength),
              let headerBytes = try handle.read(upToCount: Int(headerLength)), headerBytes.count == Int(headerLength),
              var objects = try JSONSerialization.jsonObject(with: headerBytes) as? [String: Any]
        else { throw AcousticInventoryError.input }
        objects.removeValue(forKey: "__metadata__")
        let header = try JSONDecoder().decode([String: AcousticTensor].self,
            from: JSONSerialization.data(withJSONObject: objects))
        let payloadBytes = AcousticInventory.checkpointBytes - 8 - Int(headerLength)
        let ordered = header.sorted { $0.value.data_offsets.first ?? -1 < $1.value.data_offsets.first ?? -1 }
        var end = 0
        for (_, spec) in ordered {
            try spec.validate(payloadBytes: payloadBytes)
            guard spec.data_offsets[0] == end else { throw AcousticInventoryError.input }
            end = spec.data_offsets[1]
        }
        guard end == payloadBytes, header.count == 2487 else { throw AcousticInventoryError.identity }
        var hash = SHA256(); hash.update(data: lengthBytes); hash.update(data: headerBytes)
        while true {
            // Foundation can retain autoreleased read buffers until the outer
            // pool drains. Keep the 2.7 GB identity pass bounded per chunk.
            let hasData = try autoreleasepool {
                try check()
                guard let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !hasData { break }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        var after = stat(), path = stat()
        guard digest == AcousticInventory.checkpointSHA256, fstat(handle.fileDescriptor, &after) == 0,
              stat(modelFile.path, &path) == 0,
              Self.same(initial, after), Self.same(initial, path) else { throw AcousticInventoryError.identity }
        try check()

        self.file = handle; self.initial = initial; self.url = modelFile
        self.header = header; self.digest = digest
    }
    deinit { try? file.close() }
    func verify() throws {
        var descriptor = stat(), path = stat()
        guard fstat(file.fileDescriptor, &descriptor) == 0, stat(url.path, &path) == 0,
            Self.same(initial, descriptor), Self.same(initial, path) else { throw AcousticInventoryError.identity }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
}
#endif
