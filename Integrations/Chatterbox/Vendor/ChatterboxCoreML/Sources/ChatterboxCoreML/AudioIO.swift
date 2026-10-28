import Foundation
import AVFoundation
import Accelerate

/// Audio loading + the two signal-processing steps the conditioning pipeline
/// needs that aren't baked into the CoreML graphs: resampling (24 kHz ↔ 16 kHz)
/// and ITU-R BS.1770 loudness normalization. Everything else (STFT/mel/fbank) is
/// inside the `.mlpackage`s; the heavy FFT never touches Swift.
///
/// Decode + resample use AVFoundation (`AVAudioFile` / `AVAudioConverter`) — the
/// resampler is the one residual numeric difference vs the Python (librosa
/// `kaiser_fast`) path; it only perturbs the L2-normed f32 embeddings within the
/// cos≥0.99 budget. Loudness matches `pyloudnorm` (what `tts.norm_loudness` uses).
enum AudioIO {

    /// Loads an audio file (wav/m4a/mp3/…) as mono `[Float]` at `targetSampleRate`.
    static func loadMono(url: URL, targetSampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw ChatterboxError.invalidModelOutput("empty/undecodable audio at \(url.lastPathComponent)")
        }
        try file.read(into: inBuf)
        let mono = downmixToMono(inBuf)
        return resample(mono, from: srcFormat.sampleRate, to: targetSampleRate)
    }

    /// Averages all channels of a PCM buffer into a single `[Float]`.
    private static func downmixToMono(_ buf: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buf.frameLength)
        guard n > 0, let chans = buf.floatChannelData else { return [] }
        let c = Int(buf.format.channelCount)
        if c == 1 { return Array(UnsafeBufferPointer(start: chans[0], count: n)) }
        var out = [Float](repeating: 0, count: n)
        for ch in 0..<c {
            let p = chans[ch]
            for i in 0..<n { out[i] += p[i] }
        }
        let scale = 1.0 / Float(c)
        vDSP.multiply(scale, out, result: &out)
        return out
    }

    /// Resamples mono `samples` from `srcSR` to `dstSR` via `AVAudioConverter`
    /// (Apple's sample-rate converter — a proven framework, not hand-written DSP).
    static func resample(_ samples: [Float], from srcSR: Double, to dstSR: Double) -> [Float] {
        if srcSR == dstSR || samples.isEmpty { return samples }
        guard
            let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcSR,
                                      channels: 1, interleaved: false),
            let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: dstSR,
                                       channels: 1, interleaved: false),
            let conv = AVAudioConverter(from: inFmt, to: outFmt),
            let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }

        // Highest-quality SRC to track librosa's kaiser/soxr resampling as closely
        // as possible (the residual difference is the main parity gap vs the Python
        // conds — see VoiceClonerTests).
        conv.sampleRateConverterQuality = .max
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let outCapacity = AVAudioFrameCount(Double(samples.count) * dstSR / srcSR + 4096)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else {
            return samples
        }

        // Box the one-shot input state so the @Sendable input block captures a
        // reference, not a mutating var / non-Sendable buffer (silences the
        // strict-concurrency warnings; the convert call is synchronous).
        final class Feed: @unchecked Sendable { let buf: AVAudioPCMBuffer; var done = false; init(_ b: AVAudioPCMBuffer) { buf = b } }
        let feed = Feed(inBuf)
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if feed.done { outStatus.pointee = .endOfStream; return nil }
            feed.done = true
            outStatus.pointee = .haveData
            return feed.buf
        }
        guard status != .error, err == nil else { return samples }
        let n = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
    }

    /// In-place gain to bring `samples` to `targetLUFS` (ITU-R BS.1770 integrated
    /// loudness), matching `ChatterboxTurboTTS.norm_loudness` (pyloudnorm, -27 LUFS).
    /// Returns the samples unchanged if loudness is non-finite (silence).
    static func normalizeLoudness(_ samples: [Float], sampleRate: Double,
                                  targetLUFS: Double = -27) -> [Float] {
        let lufs = integratedLoudness(samples, sampleRate: sampleRate)
        guard lufs.isFinite else { return samples }
        let gainDB = targetLUFS - lufs
        let gain = Float(pow(10.0, gainDB / 20.0))
        guard gain.isFinite, gain > 0 else { return samples }
        var out = samples
        vDSP.multiply(gain, samples, result: &out)
        return out
    }

    // MARK: - BS.1770 integrated loudness (mono)

    /// K-weighting (two biquads) → 400 ms / 75 %-overlap blocks → absolute (-70 LUFS)
    /// then relative (-10 LU) gating → integrated loudness. Mirrors pyloudnorm.
    static func integratedLoudness(_ x: [Float], sampleRate fs: Double) -> Double {
        guard x.count > Int(0.4 * fs) else { return -.infinity }
        // Stage 1: high-shelf. Stage 2: high-pass. Coeffs from pyloudnorm IIRfilter.
        let s1 = highShelf(fs: fs)
        let s2 = highPass(fs: fs)
        let y = biquad(biquad(x.map(Double.init), s1), s2)

        let blockLen = Int(0.4 * fs)
        let step = Int(0.1 * fs)            // 75% overlap
        guard blockLen > 0, step > 0, y.count >= blockLen else { return -.infinity }

        var zs: [Double] = []               // mean-square per block
        var i = 0
        while i + blockLen <= y.count {
            var z = 0.0
            for j in i..<(i + blockLen) { z += y[j] * y[j] }
            zs.append(z / Double(blockLen))
            i += step
        }
        guard !zs.isEmpty else { return -.infinity }

        func loud(_ z: Double) -> Double { -0.691 + 10 * log10(z + 1e-30) }

        // Absolute gate at -70 LUFS.
        let absKept = zs.filter { loud($0) > -70.0 }
        guard !absKept.isEmpty else { return -.infinity }
        // Relative gate at (integrated_of_abs_kept - 10 LU).
        let zAbsMean = absKept.reduce(0, +) / Double(absKept.count)
        let gammaR = loud(zAbsMean) - 10.0
        let relKept = zs.filter { loud($0) > gammaR }
        guard !relKept.isEmpty else { return -.infinity }
        let zMean = relKept.reduce(0, +) / Double(relKept.count)
        return loud(zMean)
    }

    /// Biquad coefficients (b0,b1,b2,a1,a2); a0 normalized to 1.
    private struct Biquad { let b0, b1, b2, a1, a2: Double }

    private static func highShelf(fs: Double) -> Biquad {
        let dbGain = 3.999843853973347, q = 0.7071752369554196, fc = 1681.9744509555319
        let k = tan(.pi * fc / fs)
        let vh = pow(10.0, dbGain / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0)
    }

    private static func highPass(fs: Double) -> Biquad {
        let q = 0.5003270373238773, fc = 38.13547087602444
        let k = tan(.pi * fc / fs)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: 1.0,
            b1: -2.0,
            b2: 1.0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0)
    }

    /// Direct-form-I biquad filtering.
    private static func biquad(_ x: [Double], _ c: Biquad) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in 0..<x.count {
            let xn = x[n]
            let yn = c.b0 * xn + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            y[n] = yn
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
        }
        return y
    }

    // MARK: - librosa.effects.trim (top_db, waveform energy trim)

    /// Trims leading/trailing near-silence like `librosa.effects.trim(top_db:)`
    /// (frame_length 2048, hop 512, RMS in dB vs the per-clip max). Returns the
    /// non-silent slice; falls back to the whole clip if everything is "silent".
    static func trim(_ x: [Float], topDB: Double = 20, frameLength: Int = 2048,
                     hop: Int = 512) -> [Float] {
        guard x.count >= frameLength else { return x }
        // Per-frame RMS -> dB relative to max (librosa: ref = max, amplitude_to_db).
        var dbs: [Double] = []
        var i = 0
        while i + frameLength <= x.count {
            var s = 0.0
            for j in i..<(i + frameLength) { let v = Double(x[j]); s += v * v }
            dbs.append((s / Double(frameLength)).squareRoot())
            i += hop
        }
        guard let maxRMS = dbs.max(), maxRMS > 0 else { return x }
        let refDB = 20 * log10(maxRMS)
        let threshold = refDB - topDB
        let nonSilent = dbs.map { 20 * log10($0 + 1e-12) > threshold }
        guard let first = nonSilent.firstIndex(of: true),
              let last = nonSilent.lastIndex(of: true) else { return x }
        let start = first * hop
        let end = min(x.count, last * hop + frameLength)
        guard end > start else { return x }
        return Array(x[start..<end])
    }
}
