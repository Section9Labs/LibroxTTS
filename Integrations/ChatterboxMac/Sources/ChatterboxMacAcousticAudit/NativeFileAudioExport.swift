#if os(macOS)
import Foundation
import Darwin
import AVFoundation
import AudioToolbox
import CryptoKit

/// File-backed chapter encoding. The existing <=120s array API is unchanged.
/// Input is exact little-endian IEEE F32 mono24k, with a required producer hash.
/// Output is privately staged, decoded/verified, then linked without replacement.
/// Requires a private app-owned destination directory; no shared mutable writer.
public enum NativeFileAudioExport {
    public static let maximumFrames: Int64 = 6 * 60 * 60 * 24_000
    public static let maximumEncodedBytes: Int64 = 1_073_741_824
    public enum Failure: Error, Equatable { case input, sourceIdentity, sourceHash, destinationExists, storage, encodedBudget }
    public static func write(rawPCM: URL, frames: Int64, pcmSHA256: String, to destination: URL,
                             codec: NativeAudioExport.Codec) throws -> NativeAudioExportReport {
        try encode(rawPCM: rawPCM, frames: frames, pcmSHA256: pcmSHA256, to: destination, codec: codec, check: health)
    }
    // Internal cancellation/fault seam; no alternate publication/admission path.
    static func encode(rawPCM: URL, frames: Int64, pcmSHA256: String, to destination: URL,
                       codec: NativeAudioExport.Codec, check: () throws -> Void) throws -> NativeAudioExportReport {
        let began = Date()
        try check()
        guard rawPCM.isFileURL, !rawPCM.path.utf8.contains(0), frames > 0, frames <= maximumFrames,
              pcmSHA256.utf8.count == 64, pcmSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw Failure.input }
        if codec == .wavFloat32, frames * 4 + 256 > maximumEncodedBytes { throw Failure.encodedBudget }
        if codec == .wavPCM16, frames * 2 + 256 > maximumEncodedBytes { throw Failure.encodedBudget }
        let fd = Darwin.open(rawPCM.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.input }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? input.close() }
        var source = stat()
        guard fstat(fd, &source) == 0, source.st_mode & S_IFMT == S_IFREG, source.st_size == frames * 4 else { throw Failure.input }
        func sourceStable() throws {
            var current = stat(), path = stat()
            guard fstat(fd, &current) == 0, lstat(rawPCM.path, &path) == 0,
                  same(current, source), same(path, source) else { throw Failure.sourceIdentity }
        }
        try sourceStable()
        let stage = try Stage(destination: destination, codec: codec)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536),
              let channel = buffer.floatChannelData?[0] else { throw Failure.input }
        var expectedHash = SHA256()
        do {
            let writer = try AVAudioFile(forWriting: stage.fileURL, settings: settings(codec, format: format),
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try stage.bindFile()
            var offset: Int64 = 0
            while offset < frames {
                // FileHandle bridges through autoreleased NSData. Keep the full
                // chunk lifetime inside this pool, not merely the read call.
                try autoreleasepool {
                try check()
                let count = Int(min(65536, frames - offset)), data = try read(input, bytes: count * 4, check: check)
                expectedHash.update(data: data)
                for i in 0..<count {
                    let value = sample(data, i)
                    guard value.isFinite, abs(value) <= 1 else { throw Failure.input }
                    channel[i] = value
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try writer.write(from: buffer); offset += Int64(count)
                try stage.validateFile(budget: maximumEncodedBytes)
                }
            }
        } // Finalize encoder/packet table before readback.
        try check(); try sourceStable(); try stage.validateFile(budget: maximumEncodedBytes)
        guard hex(expectedHash.finalize()) == pcmSHA256 else { throw Failure.sourceHash }
        let reader = try AVAudioFile(forReading: stage.fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        try encoding(reader, codec: codec)
        guard reader.length == frames else { throw NativeAudioExport.Failure.decodedFrameCount(expected: Int(frames), actual: Int(reader.length)) }
        guard let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 65536) else { throw Failure.input }
        try input.seek(toOffset: 0)
        var offset: Int64 = 0, peak: Float = 0, maximumError: Float = 0, secondHash = SHA256()
        let tolerance: Float? = switch codec {
        case .wavFloat32: 0
        case .wavPCM16: 1.0 / 32768
        case .alac24: 1.0 / 8_388_608
        case .aac64: nil
        }
        while offset < frames {
            try autoreleasepool {
            try check()
            decoded.frameLength = 0
            try reader.read(into: decoded, frameCount: AVAudioFrameCount(min(65536, frames - offset)))
            let count = Int(decoded.frameLength)
            guard count > 0, Int64(count) <= frames - offset, let actual = decoded.floatChannelData?[0] else { throw Failure.input }
            let reference = try read(input, bytes: count * 4, check: check); secondHash.update(data: reference)
            for i in 0..<count {
                let expected = sample(reference, i), value = actual[i]
                guard value.isFinite, abs(value) <= 1 else { throw Failure.input }
                let error = abs(value - expected)
                if let tolerance, error > tolerance {
                    throw NativeAudioExport.Failure.decodedSample(codec: codec.rawValue, index: Int(offset) + i,
                        expected: expected, actual: value, tolerance: tolerance)
                }
                peak = max(peak, abs(value)); maximumError = max(maximumError, error)
            }
            offset += Int64(count)
            }
        }
        guard reader.framePosition == reader.length, hex(secondHash.finalize()) == pcmSHA256 else { throw Failure.sourceHash }
        try check(); try sourceStable(); try stage.validateFile(budget: maximumEncodedBytes)
        let (hash, bytes) = try stage.hashFile(check: check)
        try check(); try sourceStable()
        try stage.publish()
        try check()
        return .init(path: destination.path, codec: codec.rawValue, sha256: hash, bytes: bytes, frames: frames,
            seconds: Date().timeIntervalSince(began), frameCountMatches: true, decodedPeak: peak,
            maximumSampleError: maximumError, samplePrecisionChecked: tolerance != nil)
    }
    private static func health() throws {
        try Task.checkCancellation()
        let p = ProcessInfo.processInfo
        guard !p.isLowPowerModeEnabled, p.thermalState != .serious, p.thermalState != .critical else { throw AcousticInventoryError.unsafeResource }
    }
    private static func read(_ input: FileHandle, bytes: Int, check: () throws -> Void) throws -> Data {
        var result = Data(); result.reserveCapacity(bytes)
        while result.count < bytes {
            try check()
            let part = try input.read(upToCount: bytes - result.count) ?? Data()
            guard !part.isEmpty else { throw Failure.input }
            result.append(part)
        }
        return result
    }
    private static func sample(_ data: Data, _ index: Int) -> Float {
        data.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))) }
    }
    private static func hex<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode & S_IFMT == S_IFREG &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
    private static func settings(_ codec: NativeAudioExport.Codec, format: AVAudioFormat) -> [String: Any] {
        switch codec {
        case .wavFloat32: format.settings
        case .wavPCM16: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .alac24: [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 24]
        case .aac64: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        }
    }
    private static func encoding(_ reader: AVAudioFile, codec: NativeAudioExport.Codec) throws {
        let f = reader.fileFormat.streamDescription.pointee
        let matches: Bool = switch codec {
        case .wavFloat32: f.mFormatID == kAudioFormatLinearPCM && f.mBitsPerChannel == 32 && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        case .wavPCM16: f.mFormatID == kAudioFormatLinearPCM && f.mBitsPerChannel == 16 && f.mFormatFlags & kAudioFormatFlagIsFloat == 0
        case .alac24: f.mFormatID == kAudioFormatAppleLossless && f.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData
        case .aac64: f.mFormatID == kAudioFormatMPEG4AAC
        }
        guard matches, reader.processingFormat.sampleRate == 24000, reader.processingFormat.channelCount == 1 else { throw Failure.input }
    }
    private final class Stage {
        let parentFD, directoryFD: Int32
        let parentURL, directoryURL, fileURL: URL
        let name, leaf, destination: String
        let parentIdentity, directoryIdentity: stat
        var fileFD: Int32 = -1
        var fileIdentity: stat?
        init(destination: URL, codec: NativeAudioExport.Codec) throws {
            guard destination.isFileURL, !destination.path.utf8.contains(0), !destination.lastPathComponent.isEmpty,
                  ![".", ".."].contains(destination.lastPathComponent), destination.pathExtension.lowercased() == codec.fileExtension else { throw Failure.input }
            let parent = destination.deletingLastPathComponent(), fd = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.storage }
            var p = stat(), existing = stat()
            guard fstat(fd, &p) == 0 else { Darwin.close(fd); throw Failure.storage }
            if fstatat(fd, destination.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 { Darwin.close(fd); throw Failure.destinationExists }
            guard errno == ENOENT else { Darwin.close(fd); throw Failure.storage }
            let name = ".librox-export-" + UUID().uuidString
            guard mkdirat(fd, name, 0o700) == 0 else { Darwin.close(fd); throw Failure.storage }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var d = stat()
            guard child >= 0, fstat(child, &d) == 0 else {
                if child >= 0 { Darwin.close(child) }
                unlinkat(fd, name, AT_REMOVEDIR); Darwin.close(fd); throw Failure.storage
            }
            parentFD = fd; directoryFD = child; parentURL = parent
            parentIdentity = p; directoryIdentity = d; self.name = name
            self.destination = destination.lastPathComponent; leaf = "encoded." + codec.fileExtension
            directoryURL = parent.appendingPathComponent(name); fileURL = directoryURL.appendingPathComponent(leaf)
            try validateDirectory()
        }
        deinit {
            if let expected = fileIdentity {
                var current = stat()
                if fstatat(directoryFD, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == expected.st_dev, current.st_ino == expected.st_ino { unlinkat(directoryFD, leaf, 0) }
            }
            var current = stat()
            if fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == directoryIdentity.st_dev, current.st_ino == directoryIdentity.st_ino {
                unlinkat(parentFD, name, AT_REMOVEDIR) // Preserve any unknown entries, never recursively remove.
            }
            if fileFD >= 0 { Darwin.close(fileFD) }
            Darwin.close(directoryFD); Darwin.close(parentFD)
        }
        func validateDirectory() throws {
            var p = stat(), d = stat()
            guard lstat(parentURL.path, &p) == 0, p.st_dev == parentIdentity.st_dev, p.st_ino == parentIdentity.st_ino,
                  lstat(directoryURL.path, &d) == 0, d.st_dev == directoryIdentity.st_dev, d.st_ino == directoryIdentity.st_ino
            else { throw Failure.storage }
        }
        func bindFile() throws {
            try validateDirectory()
            fileFD = openat(directoryFD, leaf, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            var f = stat()
            guard fileFD >= 0, fstat(fileFD, &f) == 0, f.st_mode & S_IFMT == S_IFREG else { throw Failure.storage }
            fileIdentity = f
        }
        func validateFile(budget: Int64) throws {
            try validateDirectory()
            guard let original = fileIdentity else { throw Failure.storage }
            var f = stat(), path = stat()
            guard fstat(fileFD, &f) == 0, fstatat(directoryFD, leaf, &path, AT_SYMLINK_NOFOLLOW) == 0,
                  f.st_dev == original.st_dev, f.st_ino == original.st_ino,
                  path.st_dev == original.st_dev, path.st_ino == original.st_ino else { throw Failure.storage }
            guard f.st_size > 0, f.st_size <= budget else { throw Failure.encodedBudget }
        }
        func hashFile(check: () throws -> Void) throws -> (String, Int) {
            guard lseek(fileFD, 0, SEEK_SET) == 0 else { throw Failure.storage }
            let duplicate = dup(fileFD); guard duplicate >= 0 else { throw Failure.storage }
            let input = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true); defer { try? input.close() }
            var hash = SHA256(), count = 0
            while true {
                let finished = try autoreleasepool {
                try check()
                let part = try input.read(upToCount: 1024 * 1024) ?? Data()
                if part.isEmpty { return true }
                guard part.count <= Int(maximumEncodedBytes) - count else { throw Failure.encodedBudget }
                hash.update(data: part); count += part.count
                return false
                }
                if finished { break }
            }
            try validateFile(budget: maximumEncodedBytes)
            return (NativeFileAudioExport.hex(hash.finalize()), count)
        }
        func publish() throws {
            try validateFile(budget: maximumEncodedBytes)
            guard fchmod(fileFD, 0o400) == 0, fsync(fileFD) == 0 else { throw Failure.storage }
            guard linkat(directoryFD, leaf, parentFD, destination, 0) == 0 else {
                if errno == EEXIST { throw Failure.destinationExists }
                throw Failure.storage
            }
            // A completed link is preserved even on later cancellation/fsync
            // uncertainty; a missing receipt does not promise no file was written.
            guard fsync(parentFD) == 0 else { throw Failure.storage }
            try validateDirectory()
            var target = stat()
            guard fstatat(parentFD, destination, &target, AT_SYMLINK_NOFOLLOW) == 0,
                  target.st_dev == fileIdentity?.st_dev, target.st_ino == fileIdentity?.st_ino else { throw Failure.storage }
        }
    }
}
#endif
