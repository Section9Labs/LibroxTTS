import AVFoundation

public enum AudioOutput {
    /// Wraps a mono Float32 sample buffer into an `AVAudioPCMBuffer` at 24 kHz.
    public static func pcmBuffer(from samples: [Float], sampleRate: Double = Constants.sampleRate) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ChatterboxError.audio("failed to create AVAudioFormat")
        }
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameCount, 1)) else {
            throw ChatterboxError.audio("failed to allocate AVAudioPCMBuffer")
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
            }
        }
        return buffer
    }

    /// Writes a PCM buffer to a 24 kHz WAV file (useful for verification).
    public static func writeWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    }
}
