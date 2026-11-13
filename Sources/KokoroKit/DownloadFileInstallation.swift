import Foundation
import CZlib

enum DownloadFileInstallation {
    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }
    static func target(_ path: String, in root: URL) throws -> URL {
        try validatePath(path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var location = root.resolvingSymlinksInPath()
        let components = path.split(separator: "/")
        for (index, component) in components.enumerated() {
            location.appendPathComponent(String(component))
            if let attrs = try? FileManager.default.attributesOfItem(atPath: location.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw CocoaError(.fileReadInvalidFileName)
            }
            if index < components.count - 1 {
                do { try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false) }
                catch {
                    let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
                    guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw error }
                }
            }
        }
        return location
    }
    static func install(_ file: NarrationDownloadPlan.File, from urls: [URL], in directory: URL) throws {
        try Task.checkCancellation()
        guard urls.count == file.artifacts.count, !urls.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let target = try target(file.installed.path, in: directory)
        if try NarrationAssets.matches(target, size: file.installed.size, sha256: file.installed.sha256) { return }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".inflate-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: stage.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: stage) }
        let output = try FileHandle(forWritingTo: stage)
        do {
            for (artifact, source) in zip(file.artifacts, urls) {
                try Task.checkCancellation()
                guard try NarrationAssets.matches(source, size: artifact.size, sha256: artifact.sha256) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try append(source, encoding: artifact.encoding, expectedSize: artifact.decodedSize, to: output)
            }
            try output.close()
        } catch { try? output.close(); throw error }
        guard try NarrationAssets.matches(stage, size: file.installed.size, sha256: file.installed.sha256) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        // The stage is private, same-directory and already verified. Moving it
        // through the existing publication seam avoids a second full decoded copy.
        var publication = VerifiedFilePublication()
        publication.operations.copy = { source, destination in try FileManager.default.moveItem(at: source, to: destination) }
        try publication.publish(stage, to: target) { staged in
            guard try NarrationAssets.matches(staged, size: file.installed.size, sha256: file.installed.sha256) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
    static func append(_ source: URL, encoding: NarrationDownloadPlan.Artifact.Encoding,
                       expectedSize: Int64, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var total: Int64 = 0
        if encoding == .raw {
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                let data = try input.read(upToCount: 65_536) ?? Data()
                if data.isEmpty { return false }
                total += Int64(data.count)
                guard total <= expectedSize else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: data)
                return true
            }) {}
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw CocoaError(.fileReadCorruptFile)
            }
            defer { inflateEnd(&stream) }
            var status = Z_OK
            while status != Z_STREAM_END {
                try autoreleasepool {
                try Task.checkCancellation()
                let data = try input.read(upToCount: 65_536) ?? Data()
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try data.withUnsafeBytes { raw in
                    stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(data.count)
                    repeat {
                        var buffer = [UInt8](repeating: 0, count: 65_536)
                        status = buffer.withUnsafeMutableBufferPointer { bytes in
                            stream.next_out = bytes.baseAddress; stream.avail_out = uInt(bytes.count)
                            return CZlib.inflate(&stream, Z_NO_FLUSH)
                        }
                        // An exactly full output buffer can require another
                        // inflate call after input was consumed. Z_BUF_ERROR
                        // here means read more input, not a malformed stream.
                        if status == Z_BUF_ERROR && stream.avail_in == 0 && stream.avail_out == uInt(buffer.count) {
                            status = Z_OK
                            break
                        }
                        guard status == Z_OK || status == Z_STREAM_END else { throw CocoaError(.fileReadCorruptFile) }
                        let produced = buffer.count - Int(stream.avail_out)
                        total += Int64(produced)
                        guard total <= expectedSize else { throw CocoaError(.fileReadCorruptFile) }
                        if produced > 0 { try output.write(contentsOf: buffer.prefix(produced)) }
                    } while status != Z_STREAM_END && (stream.avail_in > 0 || stream.avail_out == 0)
                    // One gzip member per artifact; reject concatenation/trailing bytes.
                    if status == Z_STREAM_END && stream.avail_in != 0 { throw CocoaError(.fileReadCorruptFile) }
                }
            }
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard total == expectedSize else { throw CocoaError(.fileReadCorruptFile) }
    }
}
