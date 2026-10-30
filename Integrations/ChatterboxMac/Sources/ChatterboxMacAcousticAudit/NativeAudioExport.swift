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
    public let decodedPeak: Float?
    public let maximumSampleError: Float?
    public let samplePrecisionChecked: Bool?
}
public enum NativeAudioExport {
    public enum Codec: String, Codable, Sendable, CaseIterable {
        case wavFloat32 = "WAV-F32", wavPCM16 = "WAV-PCM16", alac24 = "ALAC-24bit", aac64 = "AAC-LC-64k-requested"
        public var fileExtension: String { self == .wavFloat32 || self == .wavPCM16 ? "wav" : "m4a" }
    }
    public enum Failure: Error {
        case decodedFrameCount(expected: Int, actual: Int)
        case decodedSample(codec: String, index: Int, expected: Float, actual: Float, tolerance: Float)
    }
    /// ALAC preserves the declared 24-bit PCM conversion. Original F32 WAV is
    /// retained separately; no claim of bit-identical F32-to-24-bit conversion.
    public static func write(_ samples: [Float], to url: URL, lossless: Bool) throws -> NativeAudioExportReport {
        try write(samples, to: url, codec: lossless ? .alac24 : .wavFloat32)
    }
    public static func write(_ samples: [Float], to url: URL, codec: Codec) throws -> NativeAudioExportReport {
        let began = Date()
        guard !samples.isEmpty, samples.count <= 120 * 24000, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
              !FileManager.default.fileExists(atPath: url.path),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw AcousticInventoryError.input }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let settings: [String: Any]
        switch codec {
        case .wavFloat32: settings = format.settings
        case .wavPCM16:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .alac24:
            settings = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 24000,
                        AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 24]
        case .aac64:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
                        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        try Task.checkCancellation()
        let reader = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let actualFormat = reader.fileFormat.streamDescription.pointee
        let encodingMatches: Bool = switch codec {
        case .wavFloat32: actualFormat.mFormatID == kAudioFormatLinearPCM && actualFormat.mBitsPerChannel == 32 && actualFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
        case .wavPCM16: actualFormat.mFormatID == kAudioFormatLinearPCM && actualFormat.mBitsPerChannel == 16 && actualFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0
        case .alac24: actualFormat.mFormatID == kAudioFormatAppleLossless && actualFormat.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData
        case .aac64: actualFormat.mFormatID == kAudioFormatMPEG4AAC
        }
        guard encodingMatches else { throw AcousticInventoryError.input }
        guard reader.length == samples.count else { throw Failure.decodedFrameCount(expected: samples.count, actual: Int(reader.length)) }
        guard reader.processingFormat.sampleRate == 24000, reader.processingFormat.channelCount == 1,
              let decoded = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 65536)
        else { throw AcousticInventoryError.input }
        let tolerance: Float? = switch codec {
        case .wavFloat32: 0
        case .wavPCM16: 1.0 / 32768
        case .alac24: 1.0 / 8_388_608
        case .aac64: nil // Lossy comparison is measured, never labelled bit/precision equivalent.
        }
        var offset = 0, decodedPeak: Float = 0, maximumError: Float = 0
        while offset < samples.count {
            try Task.checkCancellation()
            decoded.frameLength = 0
            try reader.read(into: decoded, frameCount: AVAudioFrameCount(min(65536, samples.count - offset)))
            guard let actual = decoded.floatChannelData?[0], decoded.frameLength > 0 else {
                throw Failure.decodedFrameCount(expected: samples.count, actual: offset)
            }
            for j in 0..<Int(decoded.frameLength) {
                let i = offset + j
                guard actual[j].isFinite, abs(actual[j]) <= 1 else { throw AcousticInventoryError.input }
                let error = abs(actual[j] - samples[i])
                if let tolerance, error > tolerance {
                    throw Failure.decodedSample(codec: codec.rawValue, index: i,
                        expected: samples[i], actual: actual[j], tolerance: tolerance)
                }
                decodedPeak = max(decodedPeak, abs(actual[j])); maximumError = max(maximumError, error)
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
        return .init(path: url.path, codec: codec.rawValue,
            sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(), bytes: count,
            frames: reader.length, seconds: Date().timeIntervalSince(began), frameCountMatches: true,
            decodedPeak: decodedPeak, maximumSampleError: maximumError, samplePrecisionChecked: tolerance != nil)
    }
}
#endif
