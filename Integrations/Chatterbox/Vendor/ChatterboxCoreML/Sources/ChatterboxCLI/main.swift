import Foundation
import AVFoundation
import ChatterboxCoreML

// chatterbox-cli — generate speech to a WAV file for end-to-end verification.
//
// Usage:
//   swift run chatterbox-cli "Hello there." \
//       [--model-dir PATH | --download] \
//       [--out out.wav] [--voice conds.safetensors] \
//       [--greedy] [--temperature 0.8] [--top-p 0.8] [--max-tokens 1000] [--seed 42]
//
// If neither --model-dir nor --download is given, falls back to the
// CHATTERBOX_MODEL_DIR environment variable.

struct Args {
    var text = "Hello there."
    var modelDir: String?
    var download = false
    var out = "out.wav"
    var voice: String?
    var cloneVoice: String?      // path to a reference recording to clone on-device
    var cloneOnly = false        // clone the voice then exit (skip model load + synth)
    var hfToken: String?
    var decoderSelfTest = false
    var options = GenerationOptions()
    /// Explicit `--variant`; `nil` infers it from `--language` (see `selectedVariant`).
    var variant: ModelRepository.Variant?
    // Multilingual-only: the `[lang]` tokenizer tag + stress language. `nil` on the
    // multilingual variant means `defaultMultilingualLanguage`. The English models
    // (turbo, nano) have no language input at all.
    var language: String?
    var exaggeration: Float?
    var cfgWeight: Float?
    /// Offline ruaccent model dir (`coreml/`,`dictpack/`,`nn/`); else it downloads.
    var ruaccentDir: String?
    /// Cross-chunk decode∥synth overlap (issue #22). `nil` keeps the library
    /// default (on); `--overlap`/`--no-overlap` force it via CHATTERBOX_OVERLAP_CHUNKS.
    var overlap: Bool?
    /// Offline Perth model dir (holding `PerthEncoder.mlpackage`/`.mlmodelc`); else
    /// the model dir is tried, then `iliasaz/perth-coreml` is downloaded.
    var perthDir: String?
    /// `--no-watermark` emits UNWATERMARKED audio. Off-label: upstream chatterbox
    /// always watermarks, and so does this CLI unless you ask it not to.
    var watermark = true
}

extension Args {
    /// Russian is the multilingual model's validated target (and the app's default
    /// language), so `--variant multilingual` on its own means Russian rather than an
    /// untagged run — the sampler is multilingual either way, so no combination can
    /// pair a model with the wrong sampler.
    static let defaultMultilingualLanguage = "ru"

    /// The variant the flags select — resolved ONCE and driving *everything*: the HF
    /// repo + globs (`--download` / discovery) AND the sampler / tokenizer / stress
    /// preset. An explicit `--model-dir`'s own contents still win over it at load
    /// (see `effectiveVariant`).
    var selectedVariant: ModelRepository.Variant {
        variant ?? (language != nil ? .multilingual : .turbo)
    }

    /// The sampler + tokenizer preset for the variant that actually loads. The
    /// multilingual T3 needs min-p (no top-k), CFG, and a `[lang]` tag; the GPT-2
    /// models (turbo, nano) keep the turbo top-k/top-p defaults and take no language.
    /// Applied in place so explicit `--temperature`/`--top-p`/`--max-tokens`/`--seed`/
    /// `--greedy` and the pauses survive either branch.
    func generationOptions(for variant: ModelRepository.Variant) -> GenerationOptions {
        var o = options
        guard variant == .multilingual else { return o }
        o.language = language ?? Args.defaultMultilingualLanguage
        o.minP = 0.05
        o.topK = 0
        o.exaggeration = exaggeration ?? 0.5
        o.cfgWeight = cfgWeight ?? MultilingualConstants.defaultCfgWeight
        return o
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    exit(1)
}

func parseArgs() -> Args {
    var args = Args()
    var positional: [String] = []
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--model-dir": args.modelDir = it.next()
        case "--download": args.download = true
        case "--out": if let v = it.next() { args.out = v }
        case "--voice": args.voice = it.next()
        case "--clone-voice": args.cloneVoice = it.next()
        case "--clone-only": args.cloneOnly = true
        case "--hf-token": args.hfToken = it.next()
        case "--decoder-selftest": args.decoderSelfTest = true
        case "--greedy": args.options.greedy = true
        case "--temperature": if let v = it.next(), let f = Float(v) { args.options.temperature = f }
        case "--top-p": if let v = it.next(), let f = Float(v) { args.options.topP = f }
        case "--max-tokens": if let v = it.next(), let n = Int(v) { args.options.maxTokens = n }
        case "--seed": if let v = it.next(), let s = UInt64(v) { args.options.seed = s }
        case "--sentence-pause": if let v = it.next(), let f = Double(v) { args.options.sentencePause = f }
        case "--comma-pause": if let v = it.next(), let f = Double(v) { args.options.commaPause = f }
        case "--variant":
            guard let v = it.next(), let m = ModelRepository.Variant(rawValue: v.lowercased()) else {
                let names = ModelRepository.Variant.allCases.map(\.rawValue).joined(separator: "|")
                fail("--variant must be one of \(names)")
            }
            args.variant = m
        case "--language", "--lang": args.language = it.next()
        case "--exaggeration": if let v = it.next(), let f = Float(v) { args.exaggeration = f }
        case "--cfg-weight": if let v = it.next(), let f = Float(v) { args.cfgWeight = f }
        case "--ruaccent-dir": args.ruaccentDir = it.next()
        case "--overlap": args.overlap = true
        case "--no-overlap": args.overlap = false
        case "--perth-dir": args.perthDir = it.next()
        case "--no-watermark": args.watermark = false
        case "-h", "--help":
            print("""
            Usage: chatterbox-cli "TEXT" [--model-dir PATH | --download] [--out out.wav]
                   [--voice conds.safetensors] [--hf-token TOKEN] [--greedy]
                   [--variant turbo|nano|multilingual]
                   [--temperature F] [--top-p F] [--max-tokens N] [--seed N]
                   [--sentence-pause S] [--comma-pause S]
                   [--language ru] [--exaggeration F] [--cfg-weight F]
                   [--ruaccent-dir PATH] [--overlap | --no-overlap]
                   [--perth-dir PATH] [--no-watermark]

            --variant selects the model: the HF repo used by --download / discovery
            AND the sampler/tokenizer/stress preset (turbo and nano are the English
            GPT-2 models; only multilingual takes a --language). Default: multilingual
            when --language is given, else turbo. --variant multilingual without a
            --language runs Russian (the validated target). With --model-dir the
            directory's contents win — load auto-detects the variant there.
            --overlap/--no-overlap toggle cross-chunk decode∥synth pipelining
            (on by default; overrides CHATTERBOX_OVERLAP_CHUNKS for this run).
            --sentence-pause/--comma-pause insert S seconds of silence after each
            sentence / comma (0 = off, the default). Each sentence/clause is then
            synthesized as its own unit so the pause lands at every boundary.
            --language switches to the multilingual model (min-p sampling, CFG);
            the model dir must be a multilingual bundle. Russian (ru) stress comes
            from ruaccent-coreml: --ruaccent-dir points at a local model dir
            (coreml/dictpack/nn), else it downloads iliasaz/ruaccent-coreml with
            the same HF token; if unavailable it falls back to manual +/U+0301 marks.
            Generated audio is watermarked with Perth (perth-coreml), matching
            upstream chatterbox, which watermarks every utterance it returns.
            --perth-dir points at a local dir holding PerthEncoder.mlpackage;
            otherwise the model dir is checked and then iliasaz/perth-coreml is
            downloaded (4.5 MB, encoder only). --no-watermark turns it off.
            The model repos are public, so --download needs no token; for a private
            fork pass one via --hf-token, the HF_TOKEN env var, or `hf auth login`.
            """)
            exit(0)
        default: positional.append(arg)
        }
    }
    if let first = positional.first { args.text = first }
    // The two flags can contradict each other (`--variant nano --language ru`): the
    // GPT-2 models have no language input — English BPE, no `[lang]` tag, no stress —
    // so pairing one with a non-English language would silently voice the text through
    // the wrong tokenizer. Reject it instead. (`en` is a no-op, so it's allowed.)
    if args.selectedVariant != .multilingual, let lang = args.language,
       !lang.lowercased().hasPrefix("en") {
        fail("--variant \(args.selectedVariant.rawValue) is English-only; "
             + "--language \(lang) needs --variant multilingual")
    }
    return args
}

func resolveModelDir(_ args: Args) async throws -> URL {
    // Download / discovery use the selected variant's repo + globs. An explicit
    // --model-dir is loaded as-is; `effectiveVariant` then re-reads the variant from
    // the directory, so a mismatched selection can't reach the sampler.
    let variant = args.selectedVariant
    if args.download {
        FileHandle.standardError.write(Data("Downloading \(variant.displayName) model…\n".utf8))
        func fetch() async throws -> ModelRepository.DownloadResult {
            try await ModelRepository.download(
                repoId: variant.repoId, hfToken: args.hfToken, matching: variant.runtimeGlobs
            ) { frac in
                let pct = Int(frac * 100)
                FileHandle.standardError.write(Data("\rdownload \(pct)%   ".utf8))
            }
        }
        var result = try await fetch()

        // A fetch can "succeed" without landing everything (HubApi's offline/cancelled branches
        // return success), and a half-applied commit mixes a new graph spec with an old weight —
        // the exact shape of the ANE-crashing model. Never synthesize with that.
        if result.isPartiallyApplied {
            // The snapshot disagrees with the manifest the fetch ran against: some files landed,
            // some didn't. That MAY be a two-revision mix (a new spec beside an old weight — the
            // ANE-crashing shape), so don't synthesize with it — but it is not proof of one.
            // Retry PLAIN, exactly as the app does: the files that didn't land still carry the
            // old commit's etag, so HubApi re-downloads exactly them, and nothing is deleted.
            let retrying = "\nwarning: the update landed only part of a commit (the snapshot may "
                + "mix two revisions) — re-fetching to finish it…\n"
            FileHandle.standardError.write(Data(retrying.utf8))
            result = try await fetch()
            if !result.stillStale.isEmpty {
                // Beyond an in-place repair, and the CLI has no force-wipe to offer. Fail loudly
                // with a remedy that actually works, rather than speaking with a model we have
                // just proved inconsistent.
                throw ChatterboxError.missingFile(
                    "the snapshot at \(result.directory.path) still mixes two revisions "
                    + "(\(result.stillStale.count) file(s) behind the Hub) after a re-fetch. "
                    + "Delete that directory and re-run with --download.")
            }
        } else if !result.stillStale.isEmpty {
            // The fetch landed nothing (offline?). The snapshot is untouched — the working one
            // it always was, merely behind the Hub — so it is safe to use.
            let warning = "\nwarning: \(result.stillStale.count) file(s) still differ from the "
                + "Hub (the fetch landed nothing — offline?). Using the model already on disk.\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        return result.directory
    }
    if let dir = args.modelDir ?? ProcessInfo.processInfo.environment["CHATTERBOX_MODEL_DIR"] {
        return URL(fileURLWithPath: dir)
    }
    // Discover an existing model under the inferred HF base (HF_HUB_CACHE / HF_HOME).
    if let found = ModelRepository.existingModelDirectory(repoId: variant.repoId) {
        FileHandle.standardError.write(Data("Using model at \(found.path)\n".utf8))
        return found
    }
    throw ChatterboxError.missingFile(
        "\(variant.rawValue) model directory not found. Use --download, --model-dir, CHATTERBOX_MODEL_DIR, "
        + "or set HF_HOME/HF_HUB_CACHE (searched under \(ModelRepository.downloadDirectory(repoId: variant.repoId).deletingLastPathComponent().path))")
}

/// The variant the run actually uses. `ChatterboxCoreMLModel.load` re-detects the
/// variant from the model directory, so a directory that contradicts the selection
/// wins here too — otherwise the sampler/tokenizer/stress would be preset for a model
/// that isn't the one loading. Falls back to the selection for a directory that names
/// no variant (it won't load either, and `load` reports why).
func effectiveVariant(_ args: Args, modelDir: URL) -> ModelRepository.Variant {
    let selected = args.selectedVariant
    guard let detected = ModelRepository.detectVariant(in: modelDir), detected != selected else {
        return selected
    }
    let note = "Note: \(modelDir.path) holds a \(detected.rawValue) model — "
        + "using it, not the selected \(selected.rawValue)\n"
    FileHandle.standardError.write(Data(note.utf8))
    return detected
}

/// One line naming everything the variant decides (model, sampler, tokenizer, stress),
/// so a run's pairing is visible up front and a mismatch cannot hide.
func configLine(_ variant: ModelRepository.Variant, _ o: GenerationOptions, ruaccent: Bool,
                watermark: Bool) -> String {
    let sampler = variant == .multilingual
        ? String(format: "min-p %.2f, cfg %.2f, no top-k", o.minP, o.cfgWeight)
        : "top-k \(o.topK), top-p \(o.topP)"
    let tokenizer = variant == .multilingual
        ? "grapheme [\(o.language ?? "no lang tag")]" : "GPT-2 BPE"
    return "[config] variant=\(variant.rawValue) repo=\(variant.repoId) sampler=\(sampler) "
        + "tokenizer=\(tokenizer) stress=\(ruaccent ? "ruaccent" : "none") "
        + "watermark=\(watermark ? "perth" : "OFF")"
}

let args = parseArgs()
// Map --overlap/--no-overlap onto the env flag the library reads at run time, so
// A/B-ing the pipeline needs no manual env juggling.
if let overlap = args.overlap {
    setenv("CHATTERBOX_OVERLAP_CHUNKS", overlap ? "1" : "0", 1)
}
do {
    let modelDir = try await resolveModelDir(args)
    // One variant drives the whole run: repo/globs above, and sampler + tokenizer +
    // stress below. Resolved against the directory that will actually load.
    let variant = effectiveVariant(args, modelDir: modelDir)
    let options = args.generationOptions(for: variant)
    // ruaccent is Russian-only: `MTLTextTokenizer.preprocess` applies the stresser
    // for `ru` and nothing else, so any other language skips the download entirely.
    let useRuAccent = variant == .multilingual && options.language == "ru"
    FileHandle.standardError.write(Data(
        (configLine(variant, options, ruaccent: useRuAccent, watermark: args.watermark) + "\n").utf8))

    // On-device voice cloning: build a *-conds.safetensors from a reference
    // recording and use it as the voice for this run.
    var voiceArg = args.voice
    if let refPath = args.cloneVoice {
        print("Cloning voice from \(refPath)…")
        let cloner = try await VoiceCloner(modelDirectory: modelDir)
        let outConds = URL(fileURLWithPath: args.voice ?? (refPath as NSString).deletingPathExtension + "-conds.safetensors")
        let cloneStart = Date()
        try cloner.cloneVoice(from: URL(fileURLWithPath: refPath), to: outConds)
        print(String(format: "  cloned in %.2fs → %@", Date().timeIntervalSince(cloneStart), outConds.path))
        voiceArg = outConds.path
        if args.cloneOnly { exit(0) }        // skip the model load + synth (fast clone for QA)
    }

    print("Loading model from \(modelDir.path)…")
    // Russian: build the neural stress source (ruaccent-coreml) — offline
    // `--ruaccent-dir`, else download with the shared HF token. Falls back to manual
    // marks if unavailable. Every other case keeps the load default (manual marks):
    // the English models have no stress step, and the tokenizer only stresses `ru`.
    let stress: RussianStressing = useRuAccent
        ? await RuAccentStress.makeOrFallback(
            localDirectory: args.ruaccentDir.map { URL(fileURLWithPath: $0) },
            downloadHFHome: nil,
            hfToken: args.hfToken)
        : ManualRussianStress()
    // Watermarking mirrors upstream chatterbox: on unless --no-watermark. Resolution
    // order is --perth-dir, then the model dir, then the Hub (same token as the model).
    let watermarker: AudioWatermarking = args.watermark
        ? await PerthWatermark.makeOrFallback(
            modelDirectory: modelDir,
            localDirectory: args.perthDir.map { URL(fileURLWithPath: $0) },
            hfToken: args.hfToken)
        : NoWatermark()
    let model = try await ChatterboxCoreMLModel.load(
        from: modelDir, russianStress: stress, watermarker: watermarker)
    print("Loaded \(model.loadedVariant.displayName)")

    let start = Date()
    let buffer: AVAudioPCMBuffer
    if args.decoderSelfTest {
        print("Decoder self-test: synthesizing default voice prompt tokens only…")
        buffer = try await model.vocoderSelfTest()
    } else {
        print("Generating: \(args.text)")
        buffer = try await model.generate(
            args.text,
            voice: voiceArg.map { URL(fileURLWithPath: $0) },
            options: options
        )
    }
    let dt = Date().timeIntervalSince(start)
    let seconds = Double(buffer.frameLength) / buffer.format.sampleRate

    let outURL = URL(fileURLWithPath: args.out)
    try AudioOutput.writeWAV(buffer, to: outURL)
    print(String(format: "Done in %.2fs → %.2fs of audio. Wrote %@", dt, seconds, outURL.path))
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
