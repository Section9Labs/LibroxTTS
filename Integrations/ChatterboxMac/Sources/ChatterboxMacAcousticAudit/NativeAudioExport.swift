#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit

public struct NativeAudioExportReport: Codable, Sendable {
    public let path, codec, sha256: String
    public let bytes: Int
    public let frames: Int64
    public let seconds: Double
    public let frameCountMatches: Bool
}
public enum NativeAudioExport {
    public enum Failure: Error {
        case decodedFrameCount(expected: Int, actual: Int)
        case decodedSample(codec: String, index: Int, expected: Float, actual: Float, tolerance: Float)
    }
    /// ALAC preserves the declared 24-bit PCM conversion. Original F32 WAV is
    /// retained separately; no claim of bit-identical F32-to-24-bit conversion.
    public static func write(_ samples: [Float], to url: URL, lossless: Bool) throws -> NativeAudioExportReport {
        let began = Date()
        guard !samples.isEmpty, samples.count <= 120 * 24000, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              !FileManager.default.fileExists(atPath: url.path),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw AcousticInventoryError.input }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let settings: [String: Any] = lossless ? [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 24] : format.settings
        do {
            let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        try Task.checkCancellation()
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard reader.processingFormat.sampleRate == 24000, reader.processingFormat.channelCount == 1,
              reader.length == samples.count,
              let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 65536)
        else { throw AcousticInventoryError.input }
        let tolerance: Float = lossless ? 1.0 / 8_388_608 : 0
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            decoded.frameLength = 0
            try reader.read(into: decoded, frameCount: AVAudioFrameCount(min(65536, samples.count - offset)))
            guard let actual = decoded.floatChannelData?[0], decoded.frameLength > 0 else {
                throw Failure.decodedFrameCount(expected: samples.count, actual: offset)
            }
            for j in 0..<Int(decoded.frameLength) {
                let i = offset + j
                guard actual[j].isFinite, abs(actual[j] - samples[i]) <= tolerance else {
                    throw Failure.decodedSample(codec: lossless ? "ALAC-24bit" : "WAV-F32", index: i,
                        expected: samples[i], actual: actual[j], tolerance: tolerance)
                }
            }
            offset += Int(decoded.frameLength)
        }
        // AVAudioFile may throw eofErr or its opaque nilError when asked to
        // read AFTER EOF. Exact decoded count and the actual terminal position
        // prove consumption; do not issue an invalid extra read to probe EOF.
        guard offset == samples.count, reader.framePosition == reader.length else {
            throw Failure.decodedFrameCount(expected: samples.count, actual: offset)
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var sha = SHA256(), count = 0
        while true {
            let more = try autoreleasepool {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1024*1024), !data.isEmpty else { return false }
                count += data.count; sha.update(data: data); return true
            }
            if !more { break }
        }
        return .init(path: url.path, codec: lossless ? "ALAC-24bit" : "WAV-F32",
            sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(), bytes: count,
            frames: reader.length, seconds: Date().timeIntervalSince(began), frameCountMatches: true)
    }
}
#endif
