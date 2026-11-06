import AVFoundation
import Foundation

/// SDK-owned delivery, independent of the host's 24 kHz resonant-voice filter.
public enum CTDelivery {
    public static let revision = "ct-delivery-v2:native-dynamics"
    /// Frozen CT F1 en-return-relief reference: -16.36134471783063 LUFS.
    /// Calibrate once to its accepted -24 LUFS audition, not once per passage.
    /// Shared across languages so a new sentence cannot reset relative dynamics.
    public static let nativeGainDB = -7.6386552821693705
    public enum Level: Sendable {
        /// Compatibility for matched laboratory auditions.
        case referenceLoudness
        /// Fixed F1 reference calibration; retain between-passage loudness.
        case nativeDynamics
    }
    public struct Output: Sendable {
        public let samples: [Float]
        public let sampleRate: Int
        public let gainDB: Double
        public let measuredLUFS: Double
        public let peakLimited: Bool
        /// Interior punctuation alignment is deliberately not claimed by v1.
        public let pausePolicy = "native-context-with-passage-boundaries"
    }
    public static func prepare(_ native: [Float], sampleRate: Int = 24_000,
                               boundaryPause: Double = 0, level: Level = .referenceLoudness) throws -> Output {
        guard [24_000, 44_100].contains(sampleRate), boundaryPause.isFinite, (0...1).contains(boundaryPause),
              !native.isEmpty, native.count <= 44_100 * 31, native.allSatisfy(\.isFinite) else { throw CTError.invalidAudio }
        let loudness = try integratedLoudness(native)
        let desiredGain = pow(10, (level == .referenceLoudness ? -24 - loudness : nativeGainDB) / 20)
        let peak = native.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { throw CTError.invalidAudio }
        // A single gain preserves waveform shape. No clipping, compressor or limiter.
        var gain = min(desiredGain, 0.98 / Double(peak))
        var samples = native.map { $0 * Float(gain) }
        if sampleRate != 44_100 { samples = try resample(samples, to: sampleRate) }
        let outputPeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if outputPeak > 0.98 {
            let adjustment = 0.98 / Double(outputPeak)
            samples = samples.map { $0 * Float(adjustment) }; gain *= adjustment
        }
        samples += [Float](repeating: 0, count: Int((boundaryPause * Double(sampleRate)).rounded()))
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
        return Output(samples: samples, sampleRate: sampleRate, gainDB: 20 * log10(gain),
                      measuredLUFS: loudness, peakLimited: gain < desiredGain)
    }
    /// Mono BS.1770 K weighting and gated 400 ms blocks (75% overlap), matching
    /// the frozen audition's pyloudnorm default coefficients at 44.1 kHz.
    public static func integratedLoudness(_ samples: [Float]) throws -> Double {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw CTError.invalidAudio }
        let shelfB = [1.5309095946396625, -2.651169032402396, 1.1691668584809876]
        let shelfA = [1.0, -1.663750110244495, 0.7126575309627482]
        let highB = [0.994607809439911, -1.989215618879822, 0.994607809439911]
        let highA = [1.0, -1.9892010416922554, 0.9892301960673886]
        func filter(_ input: [Double], b: [Double], a: [Double]) -> [Double] {
            var z1 = 0.0, z2 = 0.0
            return input.map { x in
                let y = b[0] * x + z1
                z1 = b[1] * x - a[1] * y + z2; z2 = b[2] * x - a[2] * y
                return y
            }
        }
        let filtered = filter(filter(samples.map(Double.init), b: shelfB, a: shelfA), b: highB, a: highA)
        let block = min(17_640, filtered.count), hop = 4_410
        var energies: [Double] = []
        for start in stride(from: 0, through: filtered.count - block, by: hop) {
            let energy = filtered[start..<(start + block)].reduce(0) { $0 + $1 * $1 } / Double(block)
            if energy > 0, -0.691 + 10 * log10(energy) > -70 { energies.append(energy) }
        }
        guard !energies.isEmpty else { throw CTError.invalidAudio }
        let gate = -0.691 + 10 * log10(energies.reduce(0, +) / Double(energies.count)) - 10
        energies = energies.filter { -0.691 + 10 * log10($0) > gate }
        guard !energies.isEmpty else { throw CTError.invalidAudio }
        return -0.691 + 10 * log10(energies.reduce(0, +) / Double(energies.count))
    }
    private static func resample(_ samples: [Float], to rate: Int) throws -> [Float] {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * Double(rate) / 44_100) + 1024)),
              let channel = input.floatChannelData?[0] else { throw CTError.invalidAudio }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .endOfStream; return nil }
            consumed = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard status != .error, let result = output.floatChannelData?[0], output.frameLength > 0 else { throw CTError.invalidAudio }
        return Array(UnsafeBufferPointer(start: result, count: Int(output.frameLength)))
    }
}
