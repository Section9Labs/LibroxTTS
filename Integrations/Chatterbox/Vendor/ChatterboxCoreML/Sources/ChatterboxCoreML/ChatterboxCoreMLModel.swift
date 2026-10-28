import Foundation
import AVFoundation
import CoreML
#if canImport(Darwin)
import Darwin
#endif

/// Logs current resident memory (RSS) at `.debug` on the `memory` channel.
func debugRSS(_ label: String) {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kerr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if kerr == KERN_SUCCESS {
        let gb = Double(info.resident_size) / 1_073_741_824
        Log.memory.debug("[rss] \(label, align: .left(columns: 28), privacy: .public) \(gb, format: .fixed(precision: 2), privacy: .public) GB")
    }
}

/// On-device Chatterbox Turbo text-to-speech for Apple Silicon.
///
/// Pipeline (all on the Apple Neural Engine on iPhone, GPU on Mac):
///   Text → GPT-2 BPE tokenizer
///        → T3LM prefill (multifunction CoreML, ANE)  — speaker + text + speech conditioning
///        → T3LM decode loop (same package, ANE)       — autoregressive speech tokens
///        → CoreML synth (S3Encoder/S3CFM/S3Vocoder)   — tokens → 24 kHz waveform
///
/// Prefill and decode are two functions of one weight- and state-sharing
/// multifunction `T3LM.mlpackage`, validated fully ANE-resident on iPhone.
///
/// ```swift
/// let model = try await ChatterboxCoreMLModel.load(from: modelDirectory)
/// let audio = try await model.generate("Hello there.")
/// // audio is AVAudioPCMBuffer at 24kHz
/// ```
public actor ChatterboxCoreMLModel {
    /// T3 front end (tokenize + prefill/decode), turbo or multilingual. Owns the
    /// multifunction `T3LM` CoreML model + its shared `MLState` KV cache.
    private let backend: T3Backend
    /// Optional so decode-only benchmarking (`CHATTERBOX_SKIP_SYNTH=1`) can avoid
    /// loading the three synth CoreML packages.
    private let synth: SynthRunner?
    private let defaultConds: Conditionals
    private let variant: ModelRepository.Variant
    /// Applied to every chunk of generated audio before it leaves the pipeline —
    /// see ``AudioWatermarking``. Resolved at `load` (Perth by default), never a
    /// per-call option: upstream chatterbox watermarks unconditionally, and a
    /// watermark the caller can switch off per utterance is not one.
    private let watermarker: AudioWatermarking

    private init(
        backend: T3Backend, synth: SynthRunner?, defaultConds: Conditionals,
        variant: ModelRepository.Variant, watermarker: AudioWatermarking
    ) {
        self.backend = backend
        self.synth = synth
        self.defaultConds = defaultConds
        self.variant = variant
        self.watermarker = watermarker
    }

    /// The variant actually loaded (auto-detected from the model directory at
    /// load), regardless of what the caller selected. `nonisolated` so UI can read
    /// it synchronously. (`variant` is an immutable `Sendable` `let`.)
    public nonisolated var loadedVariant: ModelRepository.Variant { variant }
    /// Successful T3 load configuration, NOT proof of operation/device residency.
    public nonisolated var selectedT3ComputeUnits: String {
        switch backend.selectedComputeUnits {
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .all: "all"
        @unknown default: "unknown"
        }
    }

    /// Nano's T3 hidden width — the only thing that tells a nano model directory
    /// apart from a turbo one (identical file names, identical everything else).
    private static let nanoHidden = NanoConstants.hidden

    /// Compiles a `.mlpackage` to `.mlmodelc` **once** and persists the result at a
    /// stable, app-owned path, reusing it on later launches. A `.mlmodelc` input is
    /// already compiled and is returned as-is.
    ///
    /// Why persist (issue #23): `MLModel.compileModel(at:)` writes a fresh
    /// `tmp/<UUID>.mlmodelc` on **every** call. The Neural-Engine E5 AOT compile
    /// inside the subsequent `MLModel(contentsOf:)` caches its product
    /// (`Library/Caches/com.apple.e5rt.e5bundlecache/…`) keyed by the compiled
    /// model's **path**, so a new tmp path each launch ⇒ cache miss ⇒ the full ANE
    /// recompile (~52 s for the multilingual T3LM, less for turbo) is paid *every*
    /// launch. Reusing a stable `.mlmodelc` lets that cache hit: warm load drops to
    /// ~0.5–1 s. (A fast *second* load of the same path within one process proves
    /// nothing about the cross-launch cache — it hits regardless.)
    ///
    /// The persisted copy lives under Application Support (not `tmp/` or
    /// `Library/Caches/`, both purgeable) and is keyed on the source package path
    /// **and** a cheap content stamp, so a re-download/re-export invalidates it and
    /// the two variants' same-named `T3LM` never evict each other. `cacheDir` is a
    /// test seam; production passes `nil` (→ Application Support).
    static func compiledModel(at url: URL, cacheDir: URL? = nil) async throws -> URL {
        guard url.pathExtension == "mlpackage" else { return url }   // already a .mlmodelc

        let fm = FileManager.default
        guard let cacheDir = cacheDir ?? compiledModelCacheDir() else {
            return try await compileFresh(url)   // no stable home → compile, don't persist
        }
        let (key, prunePrefix) = compiledModelCacheNames(for: url)
        let stable = cacheDir.appendingPathComponent("\(key).mlmodelc", isDirectory: true)

        // Warm path: a prior launch already compiled this exact package version.
        // Reusing the SAME .mlmodelc path lets aned's E5 bundle cache hit, so the
        // ANE AOT compile inside MLModel(contentsOf:) is skipped entirely. Gate on a
        // completeness sentinel (`coremldata.bin`, present in every compiled
        // `.mlmodelc`): if an earlier compile was interrupted and left a partial dir,
        // a bare `fileExists` would warm-hit a corrupt artifact *forever* (the
        // consumer's `MLModel(contentsOf:)` throws and nothing re-compiles). Missing
        // sentinel ⇒ evict and fall through to a fresh compile (self-heal).
        if fm.fileExists(atPath: stable.path) {
            if isCompleteCompiledModel(stable) {
                Log.load.notice("[load] \(key, privacy: .public): cached .mlmodelc reused (no recompile)")
                return stable
            }
            Log.load.error("[load] \(key, privacy: .public): cached .mlmodelc incomplete — evicting + recompiling")
            try? fm.removeItem(at: stable)
        }

        // Cold path: compile once, then publish at the stable path. The MLModel load
        // that follows uses `stable`, so the E5 bundle is cached under the SAME path
        // the next launch reuses (warm hit on launch #2).
        let compiled = try await compileFresh(url)
        do {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            // Derived, fully-regenerable data: keep it out of iCloud/device backups
            // (Application Support is backed up by default, unlike Caches/tmp).
            excludeFromBackup(cacheDir)
            // Evict only STALE versions of THIS source; leave other packages — incl.
            // the other variant's same-named T3LM, whose path hash differs — untouched.
            pruneStaleSiblings(in: cacheDir, prunePrefix: prunePrefix, keep: stable)
            try? fm.removeItem(at: stable)
            try fm.moveItem(at: compiled, to: stable)
            Log.load.notice("[load] \(key, privacy: .public): compiled .mlmodelc persisted for warm reuse")
            return stable
        } catch {
            // Cache trouble (no disk, move raced/failed): the freshly compiled temp
            // .mlmodelc still loads fine — just not warm-cached this launch.
            Log.load.error("[load] \(key, privacy: .public): persist failed (\(error.localizedDescription, privacy: .public)); using temp compile")
            return compiled
        }
    }

    /// One-shot `.mlpackage → .mlmodelc` compile (the cold path), with timing.
    private static func compileFresh(_ url: URL) async throws -> URL {
        let t = Date()
        let compiled = try await MLModel.compileModel(at: url)
        Log.load.debug("[load] compile \(url.lastPathComponent, privacy: .public): \(Date().timeIntervalSince(t), format: .fixed(precision: 2), privacy: .public)s")
        return compiled
    }

    /// True iff `mlmodelc` is a *complete* compiled bundle — it contains the
    /// `coremldata.bin` sentinel that every compiled `.mlmodelc` has at top level. A
    /// persisted artifact failing this was left partial by an interrupted compile;
    /// the warm path evicts + recompiles it rather than load a corrupt model.
    static func isCompleteCompiledModel(_ mlmodelc: URL) -> Bool {
        FileManager.default.fileExists(atPath: mlmodelc.appendingPathComponent("coremldata.bin").path)
    }

    /// Removes persisted compiles of the SAME source package other than `keep` —
    /// stale versions left by a re-download/re-export. Matches by `prunePrefix`
    /// (`<stem>-<pathHash>-`), so a *different* package — including the other
    /// variant's same-named `T3LM`, whose path hash differs — is never touched.
    /// Bounds the cache to one artifact per source.
    static func pruneStaleSiblings(in cacheDir: URL, prunePrefix: String, keep: URL) {
        let fm = FileManager.default
        guard let sibs = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for s in sibs where s.lastPathComponent.hasPrefix(prunePrefix)
            && s.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: s)
        }
    }

    /// Best-effort: exclude `url` (and, for a directory, its whole subtree) from
    /// iCloud/device backups. The compiled `.mlmodelc`s are large and fully
    /// regenerable from the source `.mlpackage`, so backing them up is pure waste.
    private static func excludeFromBackup(_ url: URL) {
        var u = url
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    /// App-owned, **non-purgeable** home for persisted compiled models, namespaced
    /// under the log subsystem. `nil` if Application Support can't be resolved (then
    /// `compiledModel` falls back to a non-persisted temp compile).
    static func compiledModelCacheDir() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return base.appendingPathComponent(Log.subsystem, isDirectory: true)
                   .appendingPathComponent("CompiledModels", isDirectory: true)
    }

    /// A path-INDEPENDENT identity for a model package, used to key the persisted
    /// compile. It is stable across the two on-disk layouts the SAME repo can have —
    /// the flat swift-transformers `…/models/<org>/<name>/<file>` and the
    /// swift-huggingface HubApi `…/models--<org>--<name>/snapshots/<sha>/<file>` —
    /// and across `/var` vs `/private/var` and per-launch snapshot paths.
    ///
    /// Hashing the *absolute path* here (the previous behaviour) made the resolved
    /// model path leak into the key, so whenever discovery returned a different path
    /// for the same model across launches (a different layout, or `/var` vs
    /// `/private/var`) the warm `.mlmodelc` was never found and the full ~24–52 s ANE
    /// AOT compile was paid EVERY launch, piling up duplicate compiled bundles.
    /// Keying on the repo + filename collapses those to one stable artifact while
    /// still separating distinct repos/variants. Falls back to the parent-dir name +
    /// file when no HF repo marker is present (still separates distinct sources).
    static func modelIdentity(for url: URL) -> String {
        let comps = url.pathComponents
        let file = comps.last ?? url.lastPathComponent
        // HF python / HubApi cache: `…/models--<org>--<name>/snapshots/<sha>/<file>`.
        if let i = comps.lastIndex(where: { $0.hasPrefix("models--") }) {
            let repo = comps[i].dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            return "\(repo)/\(file)"
        }
        // Flat swift-transformers layout: `…/models/<org>/<name>/<file>`.
        if let i = comps.lastIndex(of: "models"), i + 2 < comps.count {
            return "\(comps[i + 1])/\(comps[i + 2])/\(file)"
        }
        // Fallback: immediate parent-dir name + file (path-form-independent).
        return "\(url.deletingLastPathComponent().lastPathComponent)/\(file)"
    }

    /// Stable filename (sans `.mlmodelc`) for the persisted compile, plus the
    /// prune-prefix shared by every version of THIS source package.
    /// Key = `<stem>-<identityHash>-<contentStamp>`: the identity hash separates two
    /// repos (turbo vs multilingual `T3LM`) while staying stable across layouts and
    /// launches (see ``modelIdentity(for:)``); the content stamp invalidates on update.
    static func compiledModelCacheNames(for url: URL) -> (key: String, prunePrefix: String) {
        let stem = url.deletingPathExtension().lastPathComponent
        let idTag = String(format: "%016llx", fnv1a(modelIdentity(for: url)))
        let prefix = "\(stem)-\(idTag)-"
        return (prefix + packageVersionStamp(url), prefix)
    }

    /// Cheap content version of a `.mlpackage`: a deterministic hash over each
    /// contained file's relative path, size, and mtime (stat only — no file
    /// *contents* read, so it's fast even for the ~500 MB `weight.bin`). Changes
    /// whenever the package is re-downloaded or re-exported, so the persisted
    /// compile invalidates correctly; stable within an install, so warm loads hit.
    static func packageVersionStamp(_ url: URL) -> String {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var entries: [String] = []
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for case let f as URL in en {
                guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                let rel = String(f.path.dropFirst(url.path.count))
                let mtimeMs = Int((v.contentModificationDate?.timeIntervalSince1970 ?? -1) * 1000)
                entries.append("\(rel):\(v.fileSize ?? -1):\(mtimeMs)")
            }
        }
        if entries.isEmpty {   // not a readable dir → fall back to the package's own mtime
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            entries = ["\(Int((v?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))"]
        }
        // Sort so the hash is independent of enumeration order.
        return String(format: "%016llx", fnv1a(entries.sorted().joined(separator: "|")))
    }

    /// Deterministic 64-bit FNV-1a hash. Deliberately NOT `Hasher`/`hashValue`:
    /// those are seeded per process, so they'd change the cache key every launch
    /// and defeat the whole point (reuse across launches).
    private static func fnv1a(_ string: String) -> UInt64 {
        var h: UInt64 = 14695981039346656037
        for b in string.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }

    /// Loads all model components from a local model directory (the layout
    /// produced by `ModelRepository.download`). The variant (turbo vs
    /// multilingual) is detected from the directory contents.
    ///
    /// `russianStress` is the multilingual stress source plugged into the
    /// tokenizer (the Phase-7 `ruaccent-coreml` adapter slots in here); ignored by
    /// the turbo path. Defaults to manual marks only.
    ///
    /// `computeUnits` optionally forces the per-stage compute units of the whole
    /// pipeline — the multifunction T3LM (prefill+decode) and the three CoreML synth
    /// models (encoder / CFM / vocoder). Default `.init()` (all nil) keeps the
    /// built-in placement (`.all` T3LM, foreground GPU CFM); `.neuralEngine` pins
    /// every stage to the ANE for a background-capable run. See
    /// ``PipelineComputeUnits``.
    public static func load(
        from modelDirectory: URL,
        russianStress: RussianStressing = ManualRussianStress(),
        watermarker: AudioWatermarking? = nil,
        computeUnits: PipelineComputeUnits = .init(),
        padFlowToMaximum: Bool? = nil
    ) async throws -> ChatterboxCoreMLModel {
        let fm = FileManager.default
        func require(_ relative: String) throws -> URL {
            let url = modelDirectory.appendingPathComponent(relative)
            guard fm.fileExists(atPath: url.path) else { throw ChatterboxError.missingFile(relative) }
            return url
        }

        // T3LM ships either compiled (`.mlmodelc`, HF) or as a package
        // (`.mlpackage`, straight from the converter's output dir). Accept both.
        func requireFirst(_ relatives: [String]) throws -> URL {
            for r in relatives {
                let url = modelDirectory.appendingPathComponent(r)
                if fm.fileExists(atPath: url.path) { return url }
            }
            throw ChatterboxError.missingFile(relatives.joined(separator: " | "))
        }

        let skipSynth = ProcessInfo.processInfo.environment["CHATTERBOX_SKIP_SYNTH"] != nil
        let condsURL = try require("default-conds.safetensors")

        // Per-component load timing — pinpoints where load latency goes
        // (.mlpackage compile vs MLModel ANE-AOT load vs synth model load).
        func step(_ label: String, _ start: Date) {
            Log.load.debug("[load] \(label, privacy: .public): \(Date().timeIntervalSince(start), format: .fixed(precision: 2), privacy: .public)s")
        }

        // Multifunction T3LM (prefill + decode, shared weights and MLState),
        // shared by both variants. First cold load is ~16-25 s ANE AOT compile.
        let t3lmURL = try requireFirst(["T3LM.mlmodelc", "T3LM.mlpackage"])
        Log.load.notice("[load] T3LM found at \(t3lmURL.path, privacy: .public)")
        if let entries = try? fm.contentsOfDirectory(atPath: modelDirectory.path) {
            Log.load.notice("[load] modelDir entries=[\(entries.sorted().joined(separator: ","), privacy: .public)]")
        }
        let compiledT3LMURL = try await compiledModel(at: t3lmURL)
        Log.load.notice("[load] T3LM compiled at \(compiledT3LMURL.path, privacy: .public)")

        // Variant detection: the multilingual host-table set ships
        // `perceiver_query.npy` (the Perceiver cond block); turbo and nano ship
        // none, and are told apart below by their T3 hidden width (nano 768).
        let isMultilingual = ModelRepository.isMultilingualModelDirectory(modelDirectory)

        var t = Date()
        let backend: T3Backend
        let variant: ModelRepository.Variant
        if isMultilingual {
            variant = .multilingual
            Log.load.notice("[load] variant=\(variant.rawValue, privacy: .public)")
            let tokenizer = try await MTLTextTokenizer(modelFolder: modelDirectory, stresser: russianStress)
            step("tokenizer (multilingual)", t)
            t = Date()
            let runner = try MTLT3LMRunner(contentsOf: compiledT3LMURL, hostTablesDir: modelDirectory, computeUnits: computeUnits.t3)
            step("MTLT3LM (prefill+decode) load", t)
            backend = MultilingualBackend(tokenizer: tokenizer, runner: runner)
        } else {
            let speechEmbURL = try require("speech_emb.npy")
            let textEmbURL = try require("text_emb.npy")
            let spkrWeightURL = try require("spkr_enc_weight.npy")
            let spkrBiasURL = try require("spkr_enc_bias.npy")
            let tokenizer = try await TextTokenizer(modelFolder: modelDirectory)
            step("tokenizer", t)
            t = Date()
            let speechEmbedding = try SpeechEmbedding(contentsOf: speechEmbURL)
            let textEmbedding = try EmbeddingTable(contentsOf: textEmbURL, name: "text_emb")
            let spkrProjection = try SpeakerProjection(weightURL: spkrWeightURL, biasURL: spkrBiasURL)
            step("embeddings", t)
            // Turbo and nano ship the same file names; the host tables' width is the
            // discriminator (`T3LMRunner` then rejects a table/graph width mismatch).
            variant = speechEmbedding.hidden == nanoHidden ? .nano : .turbo
            Log.load.notice("[load] variant=\(variant.rawValue, privacy: .public) hidden=\(speechEmbedding.hidden, privacy: .public)")
            t = Date()
            let runner: T3LMRunner
            do {
                runner = try T3LMRunner(
                    contentsOf: compiledT3LMURL,
                    speechEmb: speechEmbedding,
                    textEmb: textEmbedding,
                    spkrProjection: spkrProjection,
                    computeUnits: computeUnits.t3)
            } catch {
                Log.load.error("[load] T3LMRunner init FAILED — model on disk is likely the obsolete (pre-host-mask) T3LM; re-download required. error=\(error.localizedDescription, privacy: .public)")
                throw error
            }
            step("T3LM (prefill+decode) MLModel load", t)
            backend = TurboBackend(tokenizer: tokenizer, runner: runner)
        }

        // CoreML synth: three packages (S3Encoder/S3CFM/S3Vocoder), each shipped
        // compiled (`.mlmodelc`, HF) or as a package (`.mlpackage`, converter output).
        t = Date()
        let synth: SynthRunner?
        if skipSynth {
            synth = nil
        } else {
            let encURL = try requireFirst(["S3Encoder.mlmodelc", "S3Encoder.mlpackage"])
            let cfmURL = try requireFirst(["S3CFM.mlmodelc", "S3CFM.mlpackage"])
            let vocURL = try requireFirst(["S3Vocoder.mlmodelc", "S3Vocoder.mlpackage"])
            synth = try SynthRunner(
                encoderURL: try await compiledModel(at: encURL),
                cfmURL: try await compiledModel(at: cfmURL),
                vocoderURL: try await compiledModel(at: vocURL),
                computeUnits: computeUnits,
                padFlowToMaximum: padFlowToMaximum
            )
        }
        step("synth (S3Encoder+S3CFM+S3Vocoder) load", t)
        let defaultConds = try Conditionals(contentsOf: condsURL)

        // Watermarking is ON unless the caller explicitly passes `NoWatermark()`.
        // `makeOrFallback` never throws — a missing/unloadable Perth encoder costs
        // the watermark, not the generation, and says so in the log.
        t = Date()
        let mark: AudioWatermarking
        if let watermarker {
            mark = watermarker
        } else {
            mark = await PerthWatermark.makeOrFallback(
                modelDirectory: modelDirectory,
                computeUnits: computeUnits.watermark ?? .all)
        }
        step("watermark (PerthEncoder) load", t)

        return ChatterboxCoreMLModel(
            backend: backend, synth: synth, defaultConds: defaultConds, variant: variant,
            watermarker: mark)
    }

    /// Pure budget computation (turbo), extracted so the prefill/vocoder bounding
    /// is unit-testable without loading the model. Bounded by the tighter of:
    ///   - **prefill** (`MAX − T_cond − 2`), and
    ///   - **vocoder**: a chunk's generated speech tokens plus the synth prompt
    ///     must fit the S3Encoder (`Constants.maxVocoderTokens`). (`SynthRunner`
    ///     still windows any overshoot, so this is a quality bound, not a
    ///     correctness one.) The multilingual budget lives in `MultilingualBackend`.
    static func textBudget(
        maxLen: Int,
        condPromptSpeechTokenCount: Int,
        synthPromptTokenCount: Int
    ) -> Int {
        let prefillBudget = maxLen - condPromptSpeechTokenCount - 2
        let vocoderWindow = Constants.maxVocoderTokens - synthPromptTokenCount
        let vocoderBudget = vocoderWindow / Constants.maxSpeechTokensPerTextToken
        return max(1, min(prefillBudget, vocoderBudget))
    }

    // `nonisolated`: pure reads of immutable `let`s (`defaultConds`, `backend`),
    // so the off-actor pipeline tasks can call them without hopping the executor.
    private nonisolated func resolveConds(_ voice: URL?) throws -> Conditionals {
        if let voice { return try Conditionals(contentsOf: voice) }
        return defaultConds
    }

    private nonisolated func chunkSegments(_ text: String, conds: Conditionals, options: GenerationOptions) -> [TextChunker.Segment] {
        backend.segments(text, conds: conds, options: options)
    }

    /// Normalizes the silence around a separately-rendered clause so the gap is
    /// close to the requested `pause` (`options.sentencePause` / `.commaPause`):
    /// trims the unit's own trailing near-silence when a pause follows it, and its
    /// leading near-silence when a pause precedes it (`trimLead`), then appends
    /// exactly `pause` seconds. Without this, each unit's ~0.3–0.5s of synth
    /// head/tail padding compounds into an overlong gap. A 20 ms guard around the
    /// low-amplitude threshold means onsets/decays aren't clipped. Returns the
    /// chunk unchanged when there's nothing to do (`!trimLead && pause <= 0`) — so
    /// the no-pause path (every pause 0, no lead trim) stays byte-identical, and
    /// the final unit keeps its natural tail. Applied identically on the serial and
    /// overlap paths, so their audio stays identical (the overlap-parity invariant).
    private nonisolated func paced(_ chunk: AudioChunk, trimLead: Bool, pause: Double) -> AudioChunk {
        guard trimLead || pause > 0 else { return chunk }
        let sr = Constants.sampleRate
        let guardSamples = Int(0.02 * sr)              // 20 ms
        let threshold: Float = 0.015
        var s = chunk.samples
        if pause > 0 {                                  // drop trailing near-silence
            var end = s.count
            while end > 0 && abs(s[end - 1]) < threshold { end -= 1 }
            let keep = min(s.count, end + guardSamples)
            s.removeLast(s.count - keep)
        }
        if trimLead {                                   // drop leading near-silence
            var start = 0
            while start < s.count && abs(s[start]) < threshold { start += 1 }
            let drop = max(0, start - guardSamples)
            if drop > 0 { s.removeFirst(drop) }
        }
        if pause > 0 { s.append(contentsOf: repeatElement(0, count: Int(pause * sr))) }
        return AudioChunk(samples: s, prefillTime: chunk.prefillTime, decodeTime: chunk.decodeTime,
                          synthTime: chunk.synthTime, watermarkTime: chunk.watermarkTime,
                          tokenCount: chunk.tokenCount, decodeBackend: chunk.decodeBackend,
                          hostAssemblyTime: chunk.hostAssemblyTime,
                          conditioningCacheHit: chunk.conditioningCacheHit, decodeStepTimings: chunk.decodeStepTimings)
    }

    /// Whether to overlap chunk N+1 decode (ANE) with chunk N synth (GPU) —
    /// issue #22. **On by default**; set `CHATTERBOX_OVERLAP_CHUNKS=0` (or
    /// `false`/`no`/`off`) to force the serial path (kill-switch). Single-chunk
    /// utterances always run serial (nothing to overlap).
    static func overlapEnabled() -> Bool {
        switch ProcessInfo.processInfo.environment["CHATTERBOX_OVERLAP_CHUNKS"]?.lowercased() {
        case "0", "false", "no", "off": return false
        default: return true
        }
    }

    /// Engine that ran prefill+decode. Kept as an enum so callers can still
    /// surface this in UI / logs, even though `T3LM` is the only path now.
    public enum DecodeBackend: String, Sendable {
        case coreml = "CoreML"   // stateful multifunction T3LM
    }

    /// One generated chunk's audio plus its per-stage timings, so callers can
    /// report where the time went (prefill / decode / synth).
    public struct AudioChunk: Sendable {
        /// Mono 24 kHz samples for this chunk.
        public let samples: [Float]
        /// CoreML T3LM prefill time.
        public let prefillTime: TimeInterval
        /// Autoregressive decode-loop time (T3LM decode function).
        public let decodeTime: TimeInterval
        /// CoreML synth time (S3Encoder → S3CFM Euler loop → S3Vocoder).
        public let synthTime: TimeInterval
        /// Perth watermark-embed time. `0` when watermarking is off
        /// (``NoWatermark``) or the Perth encoder was unavailable.
        public let watermarkTime: TimeInterval
        /// Number of speech tokens the decode loop produced.
        public let tokenCount: Int
        /// Engine that ran prefill+decode for this chunk (always `.coreml` now).
        public let decodeBackend: DecodeBackend
        public var hostAssemblyTime: TimeInterval = 0
        public var conditioningCacheHit: Bool? = nil
        public var decodeStepTimings: DecodeStepTimings? = nil

        /// Combined decode + synth time.
        public var onnxTime: TimeInterval { decodeTime + synthTime }
    }

    /// Decode half (ANE): T3LM prefill + decode loop for one chunk of text tokens
    /// that already fits the prefill window. Returns the speech tokens + per-stage
    /// timings tagged with the chunk `index`. `nonisolated` (reads only the
    /// immutable `backend` `let`) so the pipeline's decode task runs off-actor.
    /// The chunk's `MLState` is created and dropped entirely inside
    /// `backend.generate` — nothing here outlives this call but the token array.
    private nonisolated func decodeChunkParts(
        index: Int, tokens: [Int32], conds: Conditionals, options: GenerationOptions
    ) throws -> DecodedChunk {
        Log.pipeline.debug("[chunk] \(tokens.count, privacy: .public) text tokens")
        debugRSS("before prefill")
        let out = try backend.generate(textTokens: tokens, conds: conds, options: options)
        let speechTokens = out.tokens
        debugRSS("after decode (\(speechTokens.count) tokens)")
        let lo = speechTokens.filter { $0 <= Constants.speechTokenMaxValid }.count
        Log.pipeline.debug("[speech] \(speechTokens.count, privacy: .public) tokens (\(lo, privacy: .public) in 0..6560), prefillLen=\(out.prefillLength, privacy: .public)")
        if let dumpPath = ProcessInfo.processInfo.environment["CHATTERBOX_DUMP_TOKENS"] {
            let line = speechTokens.map(String.init).joined(separator: ",") + "\n"
            if let h = FileHandle(forWritingAtPath: dumpPath) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(toFile: dumpPath, atomically: true, encoding: .utf8)
            }
        }
        return DecodedChunk(index: index, result: out, conds: conds)
    }

    /// Synth half (GPU): turns one decoded chunk's speech tokens into 24 kHz
    /// samples, timing the synth stage. `nonisolated` (reads only the immutable
    /// `synth` `let`) so the pipeline's synth task runs off-actor, concurrently
    /// with the next chunk's decode. The serial path and the overlap path both
    /// call this — identical work, identical output; only scheduling differs.
    private nonisolated func synthesizeChunkParts(_ decoded: DecodedChunk) throws -> AudioChunk {
        let speechTokens = decoded.result.tokens
        let tSynth = Date()
        let samples = try synth?.synthesize(generatedTokens: speechTokens, conds: decoded.conds) ?? []
        let synthTime = Date().timeIntervalSince(tSynth)
        debugRSS("after synth")
        // Watermark here, on the raw synth output, so BOTH pipeline paths (serial
        // and overlapped) and BOTH entry points (`generate` drains `generateStream`)
        // go through exactly one apply. Deliberately before `paced` appends its
        // inter-sentence silence: Perth gates on the loudest frame of whatever it
        // is handed, and digital silence carries no mark to begin with.
        let tMark = Date()
        try Task.checkCancellation()
        let marked = watermarker.watermark(samples)
        let watermarkTime = Date().timeIntervalSince(tMark)
        Log.pipeline.debug("[timing] prefill \(decoded.result.prefillTime, format: .fixed(precision: 3), privacy: .public)s · decode[CoreML] \(decoded.result.decodeTime, format: .fixed(precision: 3), privacy: .public)s (\(speechTokens.count, privacy: .public) tok) · synth \(synthTime, format: .fixed(precision: 3), privacy: .public)s · watermark \(watermarkTime, format: .fixed(precision: 3), privacy: .public)s")
        return AudioChunk(
            samples: marked,
            prefillTime: decoded.result.prefillTime,
            decodeTime: decoded.result.decodeTime,
            synthTime: synthTime,
            watermarkTime: watermarkTime,
            tokenCount: speechTokens.count,
            decodeBackend: .coreml,
            hostAssemblyTime: decoded.result.hostAssemblyTime,
            conditioningCacheHit: decoded.result.conditioningCacheHit,
            decodeStepTimings: decoded.result.decodeStepTimings
        )
    }

    /// Generates speech for `text`, splitting long text into prefill-sized chunks
    /// and concatenating the audio. Pass `voice` to clone a custom voice from a
    /// `*-conds.safetensors` file; otherwise the bundled default voice is used.
    ///
    /// For lower time-to-first-audio, prefer `generateStream` and play each chunk
    /// as it arrives.
    @discardableResult
    public func generate(
        _ text: String,
        voice: URL? = nil,
        options: GenerationOptions = .default
    ) async throws -> sending AVAudioPCMBuffer {
        // Drain the single pipeline path so batch and streaming share identical
        // scheduling (serial or overlapped). The stream is ordered, so concat is.
        var samples: [Float] = []
        for try await chunk in generateStream(text, voice: voice, options: options) {
            samples.append(contentsOf: chunk.samples)
        }
        return try AudioOutput.pcmBuffer(from: samples)
    }

    /// Streams generated audio one chunk at a time, so the caller can start
    /// playing chunk *N* while the model is still generating chunk *N+1*
    /// (pipelined playback — lower time-to-first-audio for long text).
    ///
    /// Each yielded `AudioChunk` carries one text chunk's 24 kHz samples plus its
    /// per-stage timings (CoreML prefill / CoreML decode / CoreML synth), in order.
    /// The stream finishes after the last chunk, or throws if generation fails.
    /// Cancelling the consuming task stops generation.
    public nonisolated func generateStream(
        _ text: String,
        voice: URL? = nil,
        options: GenerationOptions = .default
    ) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.produce(text, voice: voice, options: options, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One unchanged natural-text unit in an opt-in bounded batch. This API does
    /// not combine texts or inject pauses; pacing must remain disabled here.
    public struct BatchRequest: Sendable {
        public let text: String
        public let voice: URL?
        public let options: GenerationOptions
        public init(text: String, voice: URL? = nil, options: GenerationOptions) {
            self.text = text; self.voice = voice; self.options = options
        }
    }

    public struct BatchAudioChunk: Sendable {
        public let requestIndex: Int
        public let chunkIndex: Int
        public let isFinalChunk: Bool
        public let audio: AudioChunk
    }

    private struct BatchDecoded: Sendable {
        let requestIndex: Int
        let chunkIndex: Int
        let isFinalChunk: Bool
        let decoded: DecodedChunk
    }

    /// One T3 producer overlaps one synth consumer across request boundaries.
    /// The callback is awaited inside the synth leg: no unbounded PCM stream or
    /// extra engine exists. A failed batch may have delivered only a prefix;
    /// callers must not advance an undelivered unit's source position.
    public nonisolated func generateBatch(
        _ requests: [BatchRequest],
        receive: @escaping @Sendable (BatchAudioChunk) async throws -> Void
    ) async throws {
        guard (1...8).contains(requests.count),
              requests.allSatisfy({ $0.text.utf8.count <= 8_000 }),
              requests.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768,
              requests.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.options.sentencePause == 0 && $0.options.commaPause == 0 }) else {
            throw ChatterboxError.invalidModelOutput("batch requires 1...8 bounded, nonempty, unpaced requests")
        }
        try await BoundedBatchPipeline<BatchDecoded>.run { channel in
            var sequence = 0
            for (requestIndex, request) in requests.enumerated() {
                try Task.checkCancellation()
                let conds = try self.resolveConds(request.voice)
                let segments = self.chunkSegments(request.text, conds: conds, options: request.options)
                guard !segments.isEmpty else { throw ChatterboxError.tokenizer("empty batch unit") }
                for (chunkIndex, segment) in segments.enumerated() {
                    try Task.checkCancellation()
                    let decoded = try self.decodeChunkParts(index: sequence, tokens: segment.tokens,
                                                           conds: conds, options: request.options)
                    guard decoded.result.tokens.count < request.options.maxTokens else {
                        throw ChatterboxError.invalidModelOutput("batch speech-token limit reached at unit \(requestIndex)")
                    }
                    try await channel.send(BatchDecoded(requestIndex: requestIndex, chunkIndex: chunkIndex,
                        isFinalChunk: chunkIndex == segments.count - 1, decoded: decoded))
                    sequence += 1
                }
            }
        } consume: { value in
            try Task.checkCancellation()
            let audio = try self.synthesizeChunkParts(value.decoded)
            try Task.checkCancellation()
            try await receive(BatchAudioChunk(requestIndex: value.requestIndex, chunkIndex: value.chunkIndex,
                isFinalChunk: value.isFinalChunk, audio: audio))
        }
    }

    /// The single pipeline path behind both `generate` and `generateStream`.
    ///
    /// `nonisolated` is **load-bearing**: the two child tasks must NOT be pinned to
    /// the actor's serial executor, or they would serialize and the decode∥synth
    /// overlap would be lost. `MLModel.prediction` is synchronous and blocks its
    /// calling thread, so the only way the OS schedules the ANE (decode) and GPU
    /// (synth) concurrently is to run them on two distinct concurrent tasks.
    /// `backend`/`synth` are immutable `Sendable` `let`s and the runners own
    /// disjoint models/state, so reading them off-actor is race-free.
    private nonisolated func produce(
        _ text: String,
        voice: URL?,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) async throws {
        let conds = try resolveConds(voice)
        let segments = chunkSegments(text, conds: conds, options: options)
        guard !segments.isEmpty else { throw ChatterboxError.tokenizer("empty text") }
        // Pacing (per-sentence/comma pauses) is on when either pause is set; only
        // then do we trim inter-unit silence (a pause precedes every non-first unit).
        let pacing = options.sentencePause > 0 || options.commaPause > 0

        let tStart = Date()
        // Serial path (flag off, or nothing to overlap): byte-identical to the
        // pre-pipeline behavior — decode then synth, one chunk at a time.
        guard Self.overlapEnabled(), segments.count > 1 else {
            for (i, seg) in segments.enumerated() {
                try Task.checkCancellation()
                let decoded = try decodeChunkParts(index: i, tokens: seg.tokens, conds: conds, options: options)
                let audio = try synthesizeChunkParts(decoded)
                continuation.yield(paced(audio, trimLead: pacing && i > 0, pause: seg.trailingPause))
            }
            Log.pipeline.debug("[pipeline] serial \(segments.count, privacy: .public) chunk(s) in \(Date().timeIntervalSince(tStart), format: .fixed(precision: 3), privacy: .public)s")
            return
        }

        // Overlap path: decode (ANE) and synth (GPU) run as two concurrent tasks
        // joined by a bounded FIFO. Depth ≤2 → at most one extra decoded chunk
        // buffered; only ever one `MLState` alive (it dies inside each
        // `backend.generate` before the result is sent).
        let channel = BoundedChunkChannel(capacity: 2)
        try await withThrowingTaskGroup(of: Void.self) { group in
            // DECODE — ANE. Strictly in chunk order, one T3 `MLState` at a time.
            // `.userInitiated`: this leg feeds live playback. Under ANE contention
            // `aned` is a strict QoS-priority queue, so an inherited/low QoS here is
            // exactly the background head-of-line-blocking / starvation failure mode
            // (background-mode plan §3). Escalate to `.userInteractive` if a contended
            // locked measurement still shows decode blocking.
            group.addTask(priority: .userInitiated) {
                do {
                    for (i, seg) in segments.enumerated() {
                        try Task.checkCancellation()
                        let decoded = try self.decodeChunkParts(index: i, tokens: seg.tokens, conds: conds, options: options)
                        await channel.send(decoded)
                    }
                    await channel.finish()
                } catch {
                    await channel.fail(error)
                    throw error
                }
            }
            // SYNTH — GPU. Single consumer → emits `AudioChunk` in chunk order,
            // each with its segment's trailing pause appended (same as serial).
            // `.utility` — one notch below decode: synth has ~2.7 s of slack per
            // utterance and self-recovers, so it yields the ANE to decode under
            // contention without stalling playback. Never `.background` (§3).
            group.addTask(priority: .utility) {
                do {
                    var expected = 0
                    while let decoded = try await channel.receive() {
                        try Task.checkCancellation()
                        assert(decoded.index == expected, "pipeline reorder: got \(decoded.index), expected \(expected)")
                        let audio = try self.synthesizeChunkParts(decoded)
                        continuation.yield(self.paced(audio, trimLead: pacing && decoded.index > 0,
                                                      pause: segments[decoded.index].trailingPause))
                        expected += 1
                    }
                } catch {
                    await channel.fail(error)
                    throw error
                }
            }
            try await group.waitForAll()   // rethrows the first task error
        }
        Log.pipeline.debug("[pipeline] overlap \(segments.count, privacy: .public) chunk(s) in \(Date().timeIntervalSince(tStart), format: .fixed(precision: 3), privacy: .public)s")
    }

    /// Diagnostic: runs ONLY the conditional decoder on the default voice's
    /// prompt tokens (no generated tokens). The output should be clean
    /// reference-voice speech if the decoder + conditioning are correct.
    public func vocoderSelfTest() throws -> sending AVAudioPCMBuffer {
        // Feed the reference voice's own prompt tokens as the "generated"
        // sequence. A correct decoder reconstructs intelligible reference speech.
        let refTokens = defaultConds.promptTokens.map(Int.init)
        guard let synth else {
            throw ChatterboxError.invalidModelOutput("vocoderSelfTest unavailable: synth skipped (CHATTERBOX_SKIP_SYNTH)")
        }
        let samples = try synth.synthesize(generatedTokens: refTokens, conds: defaultConds)
        return try AudioOutput.pcmBuffer(from: samples)
    }
}
