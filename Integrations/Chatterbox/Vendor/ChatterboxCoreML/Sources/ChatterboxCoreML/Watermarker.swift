import Foundation
import CoreML
import PerthCoreML

/// Embeds an inaudible watermark in generated audio.
///
/// Upstream chatterbox watermarks unconditionally — `ChatterboxTTS.generate` ends
/// with `self.watermarker.apply_watermark(wav, sample_rate=self.sr)` and offers no
/// way to turn it off — so this pipeline does the same by default
/// (``ChatterboxCoreMLModel/load(from:russianStress:watermarker:computeUnits:)``
/// resolves a Perth watermarker when the caller passes none).
///
/// The contract is deliberately **non-throwing**: a watermarker that cannot mark
/// a buffer returns it unchanged. Watermarking is an obligation of the *product*,
/// not a correctness precondition of synthesis, and failing a user's generation
/// because a 4.5 MB side model would not load is the wrong trade. Failures are
/// logged loudly instead (see ``PerthWatermark/makeOrFallback(modelDirectory:localDirectory:downloadHFHome:hfToken:computeUnits:)``).
public protocol AudioWatermarking: Sendable {
    /// Watermarks one buffer of mono 24 kHz samples, returning the same count.
    func watermark(_ samples: [Float]) -> [Float]
}

/// The opt-out: passes audio through untouched.
///
/// Not reachable from the app UI on purpose — a watermark the end user can
/// switch off is not a watermark. It exists for tests, for A/B measurement, and
/// for callers who watermark downstream themselves.
public struct NoWatermark: AudioWatermarking {
    public init() {}
    public func watermark(_ samples: [Float]) -> [Float] { samples }
}

/// Perth-Net Implicit watermarking (`perth-coreml`), the same watermarker
/// upstream chatterbox uses — its encoder conv stack runs on the ANE, the
/// STFT/ISTFT and gating on the host.
///
/// `@unchecked Sendable` is sound for the same reason `RuAccentStress`'s is:
/// `PerthWatermarker` is a `final class` over load-once CoreML models, and
/// ``watermark(_:)`` drives only the read-only `applyWatermark` path (the one
/// piece of lazy state inside it, the detector model, belongs to `getWatermark`,
/// which we never call). The pipeline calls this from the single-consumer synth
/// leg, so the calls are serialized anyway.
public struct PerthWatermark: AudioWatermarking, @unchecked Sendable {
    public let watermarker: PerthWatermarker

    public init(watermarker: PerthWatermarker) { self.watermarker = watermarker }

    public func watermark(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        do {
            // `.preserveLength` (the package default) — sample counts flow into
            // chunk pacing and the WAV writer, so the watermark must not change
            // the length. Perth returns anything under ~43 ms unchanged rather
            // than throwing, so short tail chunks are already safe.
            return try watermarker.applyWatermark(samples, sampleRate: Int(Constants.sampleRate))
        } catch {
            Log.pipeline.error(
                "[watermark] failed — emitting UNWATERMARKED audio: \(String(describing: error), privacy: .public)")
            return samples
        }
    }
}

extension PerthWatermark {
    /// Builds the watermarker `ChatterboxCoreMLModel.load` uses, resolving the
    /// `PerthEncoder` package from the first source that has it:
    ///
    ///   1. `localDirectory` — an explicit override (CLI `--perth-dir`, tests).
    ///   2. `modelDirectory` — the chatterbox model dir itself, so a model repo
    ///      (or a converter `out/`) that ships `PerthEncoder.mlpackage` beside
    ///      `T3LM` needs no network at all, and works offline forever after.
    ///   3. `iliasaz/perth-coreml` on the Hub, fetched with the **same** HF token
    ///      and HF_HOME chatterbox uses for its own model — the arrangement
    ///      ``RuAccentStress/makeOrFallback(localDirectory:downloadHFHome:hfToken:)``
    ///      already uses for the Russian stress models.
    ///
    /// Step 2 is the one that matters for reliability, and is worth keeping even
    /// though step 3 usually succeeds: **a watermark resolved by download is
    /// silently absent whenever the download is** — a first launch offline, a
    /// rate-limited fetch, an expired token. Shipping `PerthEncoder.mlpackage`
    /// alongside the model in each chatterbox HF repo turns that from a runtime
    /// gamble into a property of the install.
    ///
    /// Only `PerthEncoder` is fetched (4.5 MB). The 13 MB `PerthDecoder` exists to
    /// *verify* a watermark and is loaded lazily by the package, so an embed-only
    /// client never pays for it.
    ///
    /// Returns ``NoWatermark`` if every source fails, after logging an error: TTS
    /// keeps working, unwatermarked, and the log says so.
    public static func makeOrFallback(
        modelDirectory: URL? = nil,
        localDirectory: URL? = nil,
        downloadHFHome: URL? = nil,
        hfToken: String? = nil,
        computeUnits: MLComputeUnits = .all
    ) async -> AudioWatermarking {
        func make(_ dir: URL, _ how: String) -> AudioWatermarking? {
            do {
                let w = try PerthWatermarker(modelDirectory: dir, computeUnits: computeUnits)
                Log.load.notice("[watermark] Perth loaded from \(how, privacy: .public) \(dir.path, privacy: .public)")
                return PerthWatermark(watermarker: w)
            } catch {
                Log.load.error(
                    "[watermark] Perth load from \(dir.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        if let localDirectory, let w = make(localDirectory, "local dir") { return w }
        if let modelDirectory, hasPerthEncoder(in: modelDirectory),
           let w = make(modelDirectory, "model dir") { return w }
        do {
            let result = try await ModelRepository.download(
                repoId: ModelRepository.perthRepoId,
                hfHome: downloadHFHome,
                hfToken: hfToken,
                matching: ModelRepository.perthGlobs)
            if let w = make(result.directory, "hub \(ModelRepository.perthRepoId)") { return w }
        } catch {
            Log.load.error(
                "[watermark] \(ModelRepository.perthRepoId, privacy: .public) download failed: \(error.localizedDescription, privacy: .public)")
        }
        Log.load.error("[watermark] UNAVAILABLE — generated audio will NOT be watermarked")
        return NoWatermark()
    }

    /// True iff `dir` holds a loadable `PerthEncoder` in either shipping form
    /// (compiled `.mlmodelc` from the Hub, or `.mlpackage` from the converter) —
    /// the same either/or every other model in this pipeline accepts.
    static func hasPerthEncoder(in dir: URL) -> Bool {
        let fm = FileManager.default
        return ["PerthEncoder.mlmodelc", "PerthEncoder.mlpackage"].contains {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }
}
