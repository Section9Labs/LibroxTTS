import Foundation
import Hub
import HuggingFace

/// Downloads the converted Chatterbox Turbo artifacts from the HuggingFace Hub,
/// pulling only the files needed at runtime (skips the 206 MB `text_emb.npy`,
/// the vocoder safetensors, and the superseded v1 `.mlmodelc`s).
///
/// Everything is keyed off an **HF_HOME** root. The cache base is `HF_HOME/hub`,
/// mirroring the Python `huggingface_hub` / swift-huggingface layout. The root
/// can come from:
///   - a user-selected folder (treated exactly like `HF_HOME`), or
///   - the environment (`HF_HUB_CACHE`, then `HF_HOME` + `/hub`, then
///     `~/.cache/huggingface/hub`).
public enum ModelRepository {
    public static let defaultRepoId = "iliasaz/chatterbox-turbo-coreml"
    /// Multilingual (LLaMA_520M) bundle. Same on-disk layout as turbo; the loader
    /// auto-detects the variant from `perceiver_query.npy`.
    public static let defaultMultilingualRepoId = "iliasaz/chatterbox-multilingual-coreml"
    /// Nano (GPT2_small: 12×768) bundle. Identical file *names* to turbo — same S3
    /// synth stack, same tokenizer, same host-table set, only narrower — so it
    /// reuses turbo's globs. A **distinct repo id** is what keeps its same-named
    /// `T3LM` from colliding with turbo's in the compiled-model cache
    /// (`ChatterboxCoreMLModel.modelIdentity` keys on repo + filename).
    public static let defaultNanoRepoId = "iliasaz/chatterbox-nano-coreml"
    /// Perth-Net Implicit watermarking weights (`perth-coreml`). A **separate**
    /// repo, not a per-variant one: the watermarker is variant-agnostic (it sees
    /// only 24 kHz audio), so all three models share one 4.5 MB download. Resolved
    /// last, after the model dir — see ``PerthWatermark/makeOrFallback(modelDirectory:localDirectory:downloadHFHome:hfToken:computeUnits:)``.
    public static let perthRepoId = "iliasaz/perth-coreml"

    /// Globs for the watermark **encoder** only. `PerthDecoder` (13 MB) verifies a
    /// watermark and is never run by this pipeline, and the `_fp32` pair is the
    /// numeric-parity reference tier — neither is worth a user's bandwidth.
    public static let perthGlobs: [String] = [
        "PerthEncoder.mlmodelc/*", "PerthEncoder.mlmodelc/**/*",
        "PerthEncoder.mlpackage/*", "PerthEncoder.mlpackage/**/*",
    ]
    /// Glob patterns for the runtime files. Single weight-shared multifunction
    /// T3LM (prefill + decode) plus the host-side embedding / projection tables
    /// the prefill needs (`text_emb.npy`, `spkr_enc_weight.npy`,
    /// `spkr_enc_bias.npy`), the three CoreML synth packages (S3Encoder/S3CFM/
    /// S3Vocoder), and tokenizer + voice. Each CoreML model ships in whichever form
    /// the repo holds — compiled `.mlmodelc` or `.mlpackage`.
    /// Globs for the **inference** runtime: the multifunction T3LM (prefill +
    /// decode), the S3 synth stack (Encoder / CFM / Vocoder), and the support
    /// files (token embeddings, speaker-projection weights, default voice
    /// conditioning, tokenizer). This is exactly what
    /// ``ChatterboxCoreMLModel/load(from:)`` loads — and all a text-to-speech
    /// client needs when it is **not** doing on-device voice cloning.
    public static let inferenceGlobs: [String] = [
        "T3LM.mlmodelc/*",
        "T3LM.mlmodelc/**/*",
        "T3LM.mlpackage/*",
        "T3LM.mlpackage/**/*",
        "S3Encoder.mlmodelc/*", "S3Encoder.mlmodelc/**/*",
        "S3Encoder.mlpackage/*", "S3Encoder.mlpackage/**/*",
        "S3CFM.mlmodelc/*", "S3CFM.mlmodelc/**/*",
        "S3CFM.mlpackage/*", "S3CFM.mlpackage/**/*",
        "S3Vocoder.mlmodelc/*", "S3Vocoder.mlmodelc/**/*",
        "S3Vocoder.mlpackage/*", "S3Vocoder.mlpackage/**/*",
        "speech_emb.npy",
        "text_emb.npy",
        "spkr_enc_weight.npy",
        "spkr_enc_bias.npy",
        "default-conds.safetensors",
        "tokenizer.json",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "added_tokens.json",
        "vocab.json",
        "merges.txt",
    ]

    /// Globs for the **voice-cloning** conditioning encoders (MatchaMel, VEMel,
    /// VELSTM, S3Tokenizer, CAMPPlus) that ``VoiceCloner`` uses to build a new
    /// `*-conds.safetensors` on device. **Not** loaded by `ChatterboxCoreMLModel`
    /// and not needed for plain TTS inference, so a TTS-only client can skip them
    /// (≈170 MB) by downloading with ``inferenceGlobs`` instead of ``runtimeGlobs``.
    public static let cloningGlobs: [String] = [
        "MatchaMel.mlmodelc/*", "MatchaMel.mlmodelc/**/*",
        "MatchaMel.mlpackage/*", "MatchaMel.mlpackage/**/*",
        "VEMel.mlmodelc/*", "VEMel.mlmodelc/**/*",
        "VEMel.mlpackage/*", "VEMel.mlpackage/**/*",
        "VELSTM.mlmodelc/*", "VELSTM.mlmodelc/**/*",
        "VELSTM.mlpackage/*", "VELSTM.mlpackage/**/*",
        "S3Tokenizer.mlmodelc/*", "S3Tokenizer.mlmodelc/**/*",
        "S3Tokenizer.mlpackage/*", "S3Tokenizer.mlpackage/**/*",
        "CAMPPlus.mlmodelc/*", "CAMPPlus.mlmodelc/**/*",
        "CAMPPlus.mlpackage/*", "CAMPPlus.mlpackage/**/*",
    ]

    /// The full runtime set: inference + voice-cloning encoders. The default for
    /// ``download(repoId:hfHome:hfToken:matching:progress:)`` (back-compatible —
    /// a TTS-only client passes ``inferenceGlobs`` to skip the cloning encoders).
    public static let runtimeGlobs: [String] = inferenceGlobs + cloningGlobs

    /// Globs for the **multilingual** inference runtime. Same multifunction
    /// `T3LM` + S3 synth stack + voice + grapheme tokenizer, but the host tables
    /// differ: the LLaMA backbone needs the learned position tables
    /// (`text_pos_emb`/`speech_pos_emb`), the emotion projection, and the full
    /// **Perceiver** weight set (`perceiver_*`) for the host-side 34-row cond
    /// block (`perceiver_query.npy` is also the variant-detection marker). No
    /// `vocab.json`/`merges.txt`/`added_tokens.json` (grapheme BPE is self-contained
    /// in `tokenizer.json`).
    public static let multilingualInferenceGlobs: [String] = [
        "T3LM.mlmodelc/*", "T3LM.mlmodelc/**/*",
        "T3LM.mlpackage/*", "T3LM.mlpackage/**/*",
        "S3Encoder.mlmodelc/*", "S3Encoder.mlmodelc/**/*",
        "S3Encoder.mlpackage/*", "S3Encoder.mlpackage/**/*",
        "S3CFM.mlmodelc/*", "S3CFM.mlmodelc/**/*",
        "S3CFM.mlpackage/*", "S3CFM.mlpackage/**/*",
        "S3Vocoder.mlmodelc/*", "S3Vocoder.mlmodelc/**/*",
        "S3Vocoder.mlpackage/*", "S3Vocoder.mlpackage/**/*",
        "speech_emb.npy",
        "text_emb.npy",
        "text_pos_emb.npy",
        "speech_pos_emb.npy",
        "spkr_enc_weight.npy",
        "spkr_enc_bias.npy",
        "emotion_adv_fc_weight.npy",
        "perceiver_query.npy",
        "perceiver_norm_weight.npy", "perceiver_norm_bias.npy",
        "perceiver_to_q_weight.npy", "perceiver_to_q_bias.npy",
        "perceiver_to_k_weight.npy", "perceiver_to_k_bias.npy",
        "perceiver_to_v_weight.npy", "perceiver_to_v_bias.npy",
        "perceiver_proj_out_weight.npy", "perceiver_proj_out_bias.npy",
        "default-conds.safetensors",
        "tokenizer.json",
        "tokenizer_config.json",
    ]

    /// A marker file every valid model directory contains.
    private static let markerFile = "default-conds.safetensors"

    /// Opt-out sentinel: a snapshot dir holding this file is **never** version-checked
    /// against the Hub (``staleFiles(dir:manifest:matching:)`` returns empty).
    ///
    /// Keeps a hand-injected local build (a model copied into the app's data container
    /// for testing) safe. A locally-built package differs in size from the Hub's
    /// by construction, which is exactly the "behind the Hub" signal — so `touch`ing this file
    /// says "these bytes are mine, leave them alone".
    ///
    /// The case it actually saves is a **same-weight, spec-only** local build: small enough
    /// (< ``autoUpdateByteLimit``) that ``launchPlan(modelOnDisk:dir:manifest:matching:autoApplyLimit:)``
    /// returns `.update` and silently overwrites it on the next launch. A full `T3LM.mlpackage`
    /// injection is far over the limit, so it is only ever `.offerUpdate` — the model still
    /// loads and nothing is replaced unless the user taps Download — but the sentinel spares
    /// you that prompt too, and the spec-only case needs it.
    ///
    /// Deliberately does **not** disable the *completeness* self-heal
    /// (``incompleteMLPackage(in:)``): a truncated weight is broken for a local build too.
    public static let localBuildSentinel = ".chatterbox-local-build"

    /// True iff `dir` holds a **multilingual** bundle: only the LLaMA host-table set
    /// ships the Perceiver cond block. The one marker both the loader
    /// (``ChatterboxCoreMLModel/load(from:russianStress:computeUnits:)``) and the
    /// pre-load ``detectVariant(in:)`` key their multilingual branch on.
    public static func isMultilingualModelDirectory(_ dir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("perceiver_query.npy").path)
    }

    /// The variant `dir` holds, by the rules `load` applies: the Perceiver cond block
    /// marks multilingual, else the T3 hidden width in `speech_emb.npy` tells nano
    /// (768) from turbo (1024). `nil` when neither is present (not a model directory).
    ///
    /// Runs **before** load — which is the point: a caller's sampler / tokenizer /
    /// stress preset must follow the model that will actually load, not the selection
    /// it made. Header-only, so it costs one 4 KB read, not the 27 MB table.
    public static func detectVariant(in dir: URL) -> Variant? {
        if isMultilingualModelDirectory(dir) { return .multilingual }
        guard let shape = NPYFloat32.shape(url: dir.appendingPathComponent("speech_emb.npy")),
              shape.count == 2 else { return nil }
        return shape[1] == NanoConstants.hidden ? .nano : .turbo
    }

    /// Selectable model variant: which HF repo + glob set to download/discover.
    /// (The loaded pipeline's actual variant is still auto-detected from the
    /// directory — `perceiver_query.npy` → multilingual, else the T3 hidden width
    /// 768 → nano / 1024 → turbo — so a mismatched selection self-corrects at load.)
    public enum Variant: String, CaseIterable, Sendable, Identifiable {
        case turbo
        case nano
        case multilingual
        public var id: String { rawValue }

        /// Kept short: three segmented-picker labels truncate on iPhone.
        public var displayName: String {
            switch self {
            case .turbo: return "Turbo (English)"
            case .nano: return "Nano (English)"
            case .multilingual: return "Multilingual (Russian)"
            }
        }

        public var repoId: String {
            switch self {
            case .turbo: return ModelRepository.defaultRepoId
            case .nano: return ModelRepository.defaultNanoRepoId
            case .multilingual: return ModelRepository.defaultMultilingualRepoId
            }
        }

        /// TTS-only download set (no voice-cloning encoders).
        public var inferenceGlobs: [String] {
            switch self {
            case .turbo, .nano: return ModelRepository.inferenceGlobs
            case .multilingual: return ModelRepository.multilingualInferenceGlobs
            }
        }

        /// Full download set (inference + voice-cloning encoders).
        public var runtimeGlobs: [String] {
            switch self {
            case .turbo, .nano: return ModelRepository.runtimeGlobs
            case .multilingual: return ModelRepository.multilingualInferenceGlobs + ModelRepository.cloningGlobs
            }
        }
    }

    // MARK: - Base resolution

    /// The hub cache base for a given HF_HOME root: `<hfHome>/hub`.
    public static func base(forHFHome hfHome: URL) -> URL {
        hfHome.appending(component: "hub")
    }

    /// The hub cache base inferred from the environment (`HF_HUB_CACHE`, then
    /// `HF_HOME` + `/hub`, then the default cache), or `nil` if none resolve.
    public static func environmentDownloadBase() -> URL? {
        CacheLocationProvider.environment.resolve()
    }

    private static func resolvedBase() -> URL {
        environmentDownloadBase()
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appending(component: "huggingface")
    }

    // MARK: - Discovery

    /// Searches the known on-disk layouts under `base` and returns the first
    /// directory that actually contains the model. Recognizes:
    ///   1. `<base>/models/<repoId>`                        (our swift-transformers download)
    ///   2. `<base>/<repoId>`                               (plain `--local-dir` download)
    ///   3. `<base>/models--<org>--<name>/snapshots/<hash>` (Python `huggingface_hub` cache)
    public static func existingModelDirectory(in base: URL, repoId: String = defaultRepoId) -> URL? {
        let fm = FileManager.default
        func hasModel(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(markerFile).path)
        }

        var candidates: [URL] = [
            base.appending(component: "models").appending(path: repoId),
            base.appending(path: repoId),
        ]

        let cacheName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        let snapshots = base.appending(path: cacheName).appending(component: "snapshots")
        if let subdirs = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: subdirs)
        }

        return candidates.first(where: hasModel)
    }

    /// Discovers an existing model under the given HF_HOME root.
    public static func existingModelDirectory(hfHome: URL, repoId: String = defaultRepoId) -> URL? {
        existingModelDirectory(in: base(forHFHome: hfHome), repoId: repoId)
    }

    /// Discovers an existing model under the environment-inferred base.
    public static func existingModelDirectory(repoId: String = defaultRepoId) -> URL? {
        existingModelDirectory(in: resolvedBase(), repoId: repoId)
    }

    /// Deletes the snapshot **we own** (``downloadDirectory(hfHome:repoId:)``) so the next
    /// `download` is a clean, full re-fetch — handles a changed *file set* (renamed/removed
    /// files), not just changed files. Returns `true` if something was removed.
    ///
    /// Once the files are gone, `HubApi`'s per-file cache check sees no local file and
    /// re-downloads regardless of leftover metadata.
    ///
    /// Scoped to our own download directory, **not** to whatever
    /// ``existingModelDirectory(in:repoId:)`` discovers: that also finds a `--local-dir` clone
    /// and a Python `hf_hub` cache snapshot, and deleting one of those would destroy the user's
    /// checkout and then re-fetch into a *different* directory. A dir we don't own is a no-op
    /// here (`false`).
    ///
    /// - Warning: A bare delete with no rollback. Only for the paths that can **prove** what
    ///   they hold is broken (or that the user asked to start over) — the three listed on
    ///   ``download(repoId:hfHome:hfToken:matching:force:manifest:progress:)``: `force:`, the
    ///   ``incompleteMLPackage(in:)`` self-heal, and autorun's failed-**load** recovery. A
    ///   *stale* snapshot is not one of them, and neither is a
    ///   ``DownloadResult/isPartiallyApplied`` one — both still load, `HubApi` repairs them in
    ///   place, and deleting first would only open a window where a dropped connection leaves
    ///   the user with no model at all, on precisely the launch whose network already failed.
    ///   Suspicion is not proof; see ``repairDecision(afterRetry:)``.
    @discardableResult
    public static func removeDownload(hfHome: URL? = nil, repoId: String = defaultRepoId) throws -> Bool {
        let dir = downloadDirectory(hfHome: hfHome, repoId: repoId)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        try FileManager.default.removeItem(at: dir)
        return true
    }

    /// Minimum plausible size (bytes) for a real CoreML `weight.bin`. A missing
    /// file is 0; an unresolved Git-LFS pointer is ~130 bytes. The smallest real
    /// weight here is VEMel's mel front-end at ~338 KB (mostly baked DFT/conv
    /// constants), so 100 KB cleanly separates "intact" from "broken" without
    /// false-flagging VEMel. (An earlier 1 MB floor wrongly tripped on VEMel,
    /// forcing an endless clean re-download that then threw `missingFile`.)
    private static let minWeightBytes = 100_000

    /// Returns the name of the first `*.mlpackage` under `dir` whose
    /// `weight.bin` is missing or implausibly small (incomplete download / LFS
    /// pointer), or `nil` if every package present looks intact.
    static func incompleteMLPackage(in dir: URL) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in entries.sorted() where name.hasSuffix(".mlpackage") {
            let weight = dir.appendingPathComponent(name)
                .appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
            let size = ((try? fm.attributesOfItem(atPath: weight.path))?[.size] as? Int) ?? 0
            if size < minWeightBytes { return name }
        }
        return nil
    }

    // MARK: - Staleness (is the local snapshot behind the Hub?)

    /// Network budget for the manifest lookup. Deliberately small: this runs on the
    /// app-launch path, and a slow/captive network must not stall the load of an
    /// already-present model.
    private static let manifestTimeout: TimeInterval = 5

    /// The Hub's authoritative file list for a repo: relative path → byte size, files
    /// only. `nil` if it can't be determined for **any** reason (offline, timeout,
    /// 401/403/404, 5xx, malformed JSON, empty tree). Callers must read `nil` as
    /// "cannot tell", never as "changed".
    ///
    /// Sizes come from `GET /api/models/<repo>/tree/main?recursive=1`. Single page, no cursor
    /// following: our repos are ~76–86 entries and the API pages at 1000, so a `Link: rel=next`
    /// cannot arise — if one ever does the manifest would be *partial*, and a partial manifest
    /// is only ever "cannot tell" (missing entries are skipped, never condemned), so it is
    /// logged loudly rather than handled.
    ///
    /// Two field-level traps, both verified against the live API (2026-07-12) rather
    /// than assumed:
    ///   - **Directory entries carry `size: 0`.** They are filtered out here (`type ==
    ///     "file"`). Left in, ``staleFiles(dir:manifest:matching:)`` would stat a local
    ///     *directory* (~96 B on APFS), compare it to 0, and condemn every snapshot on every
    ///     device.
    ///   - **For an LFS file the top-level `size` IS the real size** — it agrees with
    ///     `lfs.size` on all three repos; the pointer length is a separate `pointerSize`
    ///     field (~131–134 B). `lfs.size ?? size` is therefore correct under either
    ///     reading, so it is what we use.
    public static func remoteManifest(
        repoId: String = defaultRepoId,
        hfToken: String? = nil
    ) async -> [String: Int]? {
        guard let url = URL(
            string: "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=1")
        else { return nil }

        let token = resolvedToken(hfToken)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = manifestTimeout
        config.timeoutIntervalForResource = manifestTimeout
        config.waitsForConnectivity = false  // offline must fail fast, not hang the launch
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = manifestTimeout
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let http: HTTPURLResponse
        do {
            let (d, response) = try await session.data(for: request)
            guard let h = response as? HTTPURLResponse else { return nil }
            (data, http) = (d, h)
        } catch {
            Log.download.debug(
                "[manifest] \(repoId, privacy: .public): lookup failed (\(error.localizedDescription, privacy: .public)) — cannot tell")
            return nil
        }
        guard http.statusCode == 200 else {
            Log.download.debug(
                "[manifest] \(repoId, privacy: .public): HTTP \(http.statusCode) — cannot tell")
            return nil
        }
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            Log.download.debug("[manifest] \(repoId, privacy: .public): malformed JSON — cannot tell")
            return nil
        }
        if http.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") == true {
            Log.download.error(
                "[manifest] \(repoId, privacy: .public): the tree API paged (Link: rel=next) — the repo outgrew one page and this manifest is PARTIAL; add cursor following")
        }

        var manifest: [String: Int] = [:]
        for entry in entries {
            guard (entry["type"] as? String) == "file",  // directories report size 0
                  let path = entry["path"] as? String
            else { continue }
            let lfsSize = (entry["lfs"] as? [String: Any])?["size"] as? Int
            guard let size = lfsSize ?? entry["size"] as? Int else { continue }
            manifest[path] = size
        }
        return manifest.isEmpty ? nil : manifest  // an empty tree is "cannot tell", not "wipe"
    }

    /// The files in `dir` we **positively know** are behind the Hub: managed files we hold
    /// locally whose size disagrees with `manifest`. Empty means "nothing to repair" —
    /// including every "cannot tell".
    ///
    /// One of the two entry points to this file's update logic (the other is
    /// ``launchPlan(modelOnDisk:dir:manifest:matching:autoApplyLimit:)``, which decides what to
    /// *do* about the answer). A **trigger, not a repair mechanism**: `HubApi.snapshot` already
    /// re-downloads a file whose bytes changed upstream — what it never got was a reason to run,
    /// because the app only called `download()` when the model was *missing*.
    ///
    /// The asymmetry is the safety invariant: a non-empty answer makes the caller re-download,
    /// so every "cannot tell" answers empty — unreachable Hub, no token, malformed JSON, an
    /// empty tree, a nonexistent dir → `[]`.
    ///
    /// Three things are deliberately never stale:
    ///   - **Files outside `globs`.** The layouts ``existingModelDirectory(in:repoId:)``
    ///     discovers include full-repo checkouts (`README.md`, `.gitattributes`, `onnx/`), and a
    ///     file we never download must not be able to condemn a snapshot — else a model-card
    ///     commit triggers an unprompted ~1 GB refetch. Matched by `HubApi`'s own rule
    ///     (``isManaged(_:globs:)``), so "managed" means exactly what `snapshot` would fetch.
    ///   - **Files absent locally** (a glob subset we skipped, or a file the Hub added since) —
    ///     absent is `HubApi`'s job; it fetches those.
    ///   - **A dir carrying ``localBuildSentinel``** — a hand-injected local build.
    ///
    /// **Size-only, by design.** Hashing ~800 MB of weights on every launch is far too slow
    /// on-device, and the Hub's own hashes (`oid`/`xetHash`) aren't plain file digests. Residual
    /// gap: a content change that preserves the byte count. Every regression we've shipped
    /// changed the size.
    ///
    /// - Parameter manifest: The Hub's sizes (``remoteManifest(repoId:hfToken:)``). `nil`
    ///   is "cannot tell" and yields `[]` — never a wipe.
    public static func staleFiles(
        dir: URL,
        manifest: [String: Int]?,
        matching globs: [String] = runtimeGlobs
    ) -> [String] {
        guard let remote = manifest, !remote.isEmpty else { return [] }  // cannot tell
        if FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(localBuildSentinel).path)
        {
            Log.download.notice(
                "[manifest] \(localBuildSentinel, privacy: .public) present — local build, not version-checked")
            return []
        }

        var stale: [String] = []
        for path in remote.keys.sorted() {  // sorted: the logged mismatch is deterministic
            guard let remoteSize = remote[path],
                  isManaged(path, globs: globs),  // a file we never fetch can't condemn us
                  let localSize = regularFileSize(at: dir.appendingPathComponent(path))
            else { continue }  // absent locally (glob subset) ≠ stale
            if localSize != remoteSize {
                Log.download.notice(
                    "[manifest] stale: \(path, privacy: .public) local=\(localSize) remote=\(remoteSize)")
                stale.append(path)
            }
        }
        return stale
    }

    // MARK: - The launch-time decision

    /// The most an **automatic**, unprompted launch-time update may spend of the user's
    /// bandwidth: 25 MB.
    ///
    /// Why a gate at all: the update path fires on launch, with no confirmation — possibly on
    /// cellular, possibly metered. Left ungated it would, on the very next launch after a
    /// legitimate republish, silently pull the **whole changed weight**: measured against the
    /// live repos (2026-07-12) by staging their real pre-republish revisions, an existing *nano*
    /// install would fetch 120.3 MB (`T3LM/weight.bin` 211,678,982 → 119,997,254, plus its spec)
    /// and an existing *multilingual* install ~537 MB (1,027,777,988 → 537,254,468).
    /// Unacceptable unasked; trivial to consent to.
    ///
    /// Why **25 MB**: it is sized to the class of bug this whole mechanism exists for — a
    /// broken CoreML **graph spec** — and to nothing bigger. Across all three repos every
    /// `model.mlmodel` is ≤ 725 KB (the S3CFM fix that motivated this: 721,085 B; *all five*
    /// specs together ≈ 2.7 MB), every tokenizer/config ≤ 3.6 MB, and the largest small host
    /// table is 16.8 MB (multilingual `speech_pos_emb.npy`) — so every spec-level repair lands
    /// comfortably under the limit and applies silently, as it should. Above it sit exactly the
    /// things a user should get to say no to on a train: the model weights (S3Vocoder 35 MB,
    /// S3Encoder 93 MB, S3CFM 143–147 MB, T3LM 120–537 MB) and the big embedding tables
    /// (`text_emb.npy` up to 206 MB). 25 MB is also about a routine app update — the scale of
    /// download a phone makes without the user noticing.
    ///
    /// **Only the automatic path is gated.** The Download button and `download(force:)` are
    /// explicit user intent and always apply, at any size.
    public static let autoUpdateByteLimit = 25_000_000

    /// What launch-time autorun should do with the snapshot it found — the whole decision, in
    /// one pure function, so it can be tested without an app.
    public enum LaunchPlan: Equatable, Sendable {
        /// Nothing usable on disk: fetch, and there is nothing to fall back on if that fails.
        case download
        /// Behind the Hub, and small enough (≤ ``autoUpdateByteLimit``) to apply unattended.
        case update(files: [String], bytes: Int)
        /// Behind the Hub, but too big to spend unasked. **Load the stale model anyway** and
        /// tell the user what an update would cost; the Download button applies it.
        case offerUpdate(files: [String], bytes: Int)
        /// Load what is on disk: current, or we could not tell (offline / no token / 5xx), or
        /// the dir is not one we own.
        case load

        /// Whether failing to fetch leaves the user with **nothing to load** — true only for
        /// ``download``, where there is genuinely nothing on disk.
        ///
        /// This is the safety invariant of the whole launch path, in one line: a failed
        /// *update* must never cost a user their working model. Only the missing-model branch
        /// may abandon the launch **on a download failure**; every other plan falls through to
        /// the load it would have done anyway. (Regressing this is silent — the app just
        /// quietly stops loading on a flaky network — so it is pinned by
        /// `LaunchPlanTests.aFailedUpdateNeverDeniesTheUserTheirModel`.)
        ///
        /// One branch downstream of this flag also ends a launch without loading, and it is not
        /// a failed fetch: an update that came back ``DownloadResult/isPartiallyApplied`` and
        /// could not be cleared by a plain re-fetch (``repairDecision(afterRetry:)``). There the
        /// snapshot itself is under suspicion, so it is neither loaded **nor destroyed**.
        public var fetchIsRequired: Bool {
            if case .download = self { return true }
            return false
        }

        /// The bytes an update would fetch (`0` when there is nothing to update).
        public var bytes: Int {
            switch self {
            case .update(_, let bytes), .offerUpdate(_, let bytes): return bytes
            case .download, .load: return 0
            }
        }
    }

    /// The launch-time decision: fetch, update silently, offer the update, or just load.
    ///
    /// - Parameters:
    ///   - modelOnDisk: Whether a loadable snapshot is already present (the app's
    ///     `hasT3LMOnDisk()`). `false` → ``LaunchPlan/download``, and nothing else is consulted.
    ///   - manifest: The Hub's sizes, or `nil` for "cannot tell" → ``LaunchPlan/load``.
    ///   - autoApplyLimit: The unattended-spend gate; see ``autoUpdateByteLimit``.
    public static func launchPlan(
        modelOnDisk: Bool,
        dir: URL,
        manifest: [String: Int]?,
        matching globs: [String] = runtimeGlobs,
        autoApplyLimit: Int = autoUpdateByteLimit
    ) -> LaunchPlan {
        guard modelOnDisk else { return .download }
        let stale = staleFiles(dir: dir, manifest: manifest, matching: globs)
        guard !stale.isEmpty, let manifest else { return .load }
        // The cost is the REMOTE size of each stale file — the bytes that actually cross the
        // network. `HubApi` re-downloads a changed file whole (no range/delta transfer), so an
        // 8.7 KB content change in a 721 KB spec costs 721 KB.
        let bytes = stale.reduce(0) { $0 + (manifest[$1] ?? 0) }
        if bytes <= autoApplyLimit {
            Log.download.notice(
                "[update] \(stale.count) file(s) / \(bytes) B behind the Hub — under the \(autoUpdateByteLimit) B auto-apply limit, updating")
            return .update(files: stale, bytes: bytes)
        }
        Log.download.notice(
            "[update] \(stale.count) file(s) / \(bytes) B behind the Hub — over the \(autoUpdateByteLimit) B auto-apply limit, offering it to the user instead")
        return .offerUpdate(files: stale, bytes: bytes)
    }

    /// Whether `path` is a file **we** download — `HubApi`'s own selection rule, verbatim
    /// (`fnmatch(glob, path, 0)`; see the `private extension [String].matching(glob:)` in
    /// `HubApi.swift`). Reusing the exact matcher is the point: "managed" here must mean
    /// precisely the set `snapshot(from:matching:)` would fetch, or we would condemn a
    /// snapshot over a file the re-fetch is never going to touch.
    ///
    /// Flags `0` on purpose — `*` spans `/`, which is what makes `T3LM.mlpackage/*` cover
    /// the nested `Data/com.apple.CoreML/weights/weight.bin`.
    private static func isManaged(_ path: String, globs: [String]) -> Bool {
        globs.contains { fnmatch($0, path, 0) == 0 }
    }

    /// Byte size of a **regular** file, or `nil` if it is absent or is anything else.
    ///
    /// Resolves symlinks on purpose: a Python `huggingface_hub` cache snapshot — one of
    /// the layouts ``existingModelDirectory(in:repoId:)`` discovers — is a farm of
    /// symlinks into `blobs/`, and `attributesOfItem` has `lstat` semantics, so it would
    /// report the *link's* length (measured: 85 B) instead of the blob's (721,085 B) and
    /// condemn a perfectly good snapshot.
    private static func regularFileSize(at url: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: url.resolvingSymlinksInPath().path)
        guard (attrs?[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return attrs?[.size] as? Int
    }

    /// True when `error` means the disk is full, in any of the shapes Foundation and
    /// `URLSession` throw it. Worth distinguishing: "download failed" on a phone with no
    /// free space is actionable ("free up space"), and the generic message sends the user
    /// hunting a network problem they don't have.
    public static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isOutOfSpace(underlying)
        }
        return false
    }

    /// An explicit token, resolved the way `HubApi`'s `TokenProvider` does: the
    /// parameter, then `HF_TOKEN`, then `HUGGING_FACE_HUB_TOKEN`, then the standard CLI
    /// token **files** (`$HF_TOKEN_PATH`, `$HF_HOME/token`, `~/.cache/huggingface/token`,
    /// `~/.huggingface/token`).
    ///
    /// The file fallback is what makes the staleness check work at all on a machine
    /// authenticated only by `hf auth login`: `HubApi` finds those files itself, but a
    /// raw `URLSession` call to the HF API cannot, so the download would succeed while
    /// ``remoteManifest(repoId:hfToken:)`` silently 401'd — the check inert exactly
    /// where it is developed.
    /// (`NSHomeDirectory()`, not `homeDirectoryForCurrentUser`, which is macOS-only. On
    /// iOS it is the app sandbox, where no CLI token file exists — so the file fallback
    /// is simply a no-op there, which is exactly right.)
    static func resolvedToken(_ hfToken: String? = nil) -> String? {
        resolvedToken(
            hfToken,
            env: ProcessInfo.processInfo.environment,
            home: URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// Seam for the offline tests: `env`/`home` stand in for the process environment and
    /// the user's home, so the file-fallback order can be exercised without mutating
    /// either.
    static func resolvedToken(_ hfToken: String?, env: [String: String], home: URL) -> String? {
        if let token = trimmed(hfToken) { return token }
        if let token = trimmed(env["HF_TOKEN"]) { return token }
        if let token = trimmed(env["HUGGING_FACE_HUB_TOKEN"]) { return token }

        var files: [URL] = []
        if let path = trimmed(env["HF_TOKEN_PATH"]) { files.append(URL(fileURLWithPath: path)) }
        if let hfHome = trimmed(env["HF_HOME"]) {
            files.append(URL(fileURLWithPath: hfHome).appending(component: "token"))
        }
        files.append(home.appending(path: ".cache/huggingface/token"))
        files.append(home.appending(path: ".huggingface/token"))
        for file in files {
            if let token = trimmed(try? String(contentsOf: file, encoding: .utf8)) { return token }
        }
        return nil
    }

    /// Whitespace-trimmed, or `nil` when absent/blank (a blank token must not be sent
    /// as `Bearer `).
    private static func trimmed(_ value: String?) -> String? {
        let token = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }

    // MARK: - Download

    /// The one directory ``download(repoId:hfHome:hfToken:matching:force:manifest:progress:)``
    /// writes into, and the only one ``removeDownload(hfHome:repoId:)`` will delete:
    /// `<base>/models/<repoId>` — the swift-transformers layout (`HubApi.localRepoLocation`),
    /// and the first candidate ``existingModelDirectory(in:repoId:)`` looks for.
    public static func downloadDirectory(hfHome: URL? = nil, repoId: String = defaultRepoId) -> URL {
        let root = hfHome.map { base(forHFHome: $0) } ?? resolvedBase()
        return root.appending(component: "models").appending(path: repoId)
    }

    /// True iff `dir` is the snapshot **we** manage: the very directory `download` writes into.
    ///
    /// ``existingModelDirectory(in:repoId:)`` also discovers two layouts we do *not* own — a
    /// Python `huggingface_hub` cache snapshot (`models--org--name/snapshots/<hash>`) and a
    /// `--local-dir` clone (`<base>/<repoId>`). Those are somebody else's checkout, and
    /// "repairing" one is not a repair at all: `download` would fetch a **fresh full snapshot
    /// into a different directory**, leaving the original untouched on disk — a surprise ~1 GB
    /// download that doesn't even fix the model the app is about to load.
    ///
    /// So the automatic staleness check is scoped to a dir we own, for the same reason it is
    /// already scoped away from `source == .folder`: a snapshot the app didn't create is not a
    /// snapshot the app gets to silently replace. (Cannot arise on iOS — there is only ever the
    /// one app-container layout — so this is a macOS/dev-machine guard.)
    ///
    /// Both sides are symlink-resolved: `/var` → `/private/var` on macOS would otherwise make
    /// an identical path compare unequal.
    public static func ownsSnapshot(
        at dir: URL,
        hfHome: URL? = nil,
        repoId: String = defaultRepoId
    ) -> Bool {
        let target = downloadDirectory(hfHome: hfHome, repoId: repoId)
        return dir.standardizedFileURL.resolvingSymlinksInPath().path
            == target.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The outcome of a ``download(repoId:hfHome:hfToken:matching:force:manifest:progress:)``:
    /// the snapshot directory, plus **what the fetch actually did to it**.
    ///
    /// The second part is not a nicety. `HubApi.snapshot` returns *success without downloading
    /// anything* when the network is down (`HubApi.swift:902`) and when the task is cancelled
    /// (`:966`), and it applies a commit **one file at a time** — so "the fetch didn't throw"
    /// does not mean "the fresh bytes are on disk", and a cancellation between two files of the
    /// same commit can leave a NEW `model.mlmodel` beside an OLD `weight.bin`. Nothing else
    /// catches that: ``incompleteMLPackage(in:)`` is a *completeness* check and the old weight
    /// is perfectly complete. Loading such a package is exactly the failure mode this whole fix
    /// exists to prevent, so the caller is told, and decides.
    public struct DownloadResult: Sendable, Equatable {
        /// The local snapshot directory (what the caller passes to `load(from:)`).
        public let directory: URL
        /// Managed files that were behind the Hub **before** the fetch and are now current.
        public let repaired: [String]
        /// Managed files that are **still** behind the Hub after the fetch. Non-empty means the
        /// update did not (fully) land: offline, cancelled, or a commit that raced us. Empty
        /// whenever we couldn't tell (no manifest) — never a false alarm.
        public let stillStale: [String]
        /// Whether the before/after comparison had Hub truth to compare against at all.
        ///
        /// `false` is **"cannot tell"**, and it is why the flag has to exist: with no manifest
        /// (offline, no token, 5xx, or a fresh install / `force:` where there was nothing to
        /// compare) `repaired` and `stillStale` are both empty *for lack of evidence*, which is
        /// byte-for-byte indistinguishable from "verified current". A caller that must not act
        /// on a guess — ``repairDecision(afterRetry:)`` — reads this to tell the two apart.
        public let checkedAgainstHub: Bool

        /// The snapshot **disagrees with the manifest it was fetched against**: some of that
        /// manifest's files landed and some did not.
        ///
        /// Read it as exactly that, and no more. It is *evidence of*, not *proof of*, a
        /// two-revision mix — the shape we actually fear, a new graph spec beside an old weight
        /// (precisely the inconsistency that SIGSEGV'd `bnns::GraphCompile`), which no other
        /// check catches because the old weight is perfectly *complete*. But the same flag is
        /// raised by an innocent case: a commit landing on the Hub **between** the caller's
        /// manifest lookup and its fetch leaves the snapshot fully current at `main` while
        /// disagreeing with the (now one commit old) manifest it was handed. So this is a reason
        /// to **re-check against current Hub truth** — a plain, manifest-less `download`, which
        /// deletes nothing — never a reason to destroy anything.
        ///
        /// The conjunction is the whole point, and dropping either half is a real bug:
        ///   - `stillStale` alone would also be true of the **offline no-op** (nothing was
        ///     downloaded, the snapshot is byte-for-byte the working one it always was, merely
        ///     stale).
        ///   - `repaired` alone is just a successful update.
        public var isPartiallyApplied: Bool { !repaired.isEmpty && !stillStale.isEmpty }
    }

    /// What autorun may do with a snapshot whose first fetch came back
    /// ``DownloadResult/isPartiallyApplied`` and was then re-fetched plain.
    ///
    /// **There is deliberately no destructive case.** That is the type doing the enforcing:
    /// the only states reachable here are "proved current" and "could not prove anything", and
    /// a model we cannot prove is broken is a model we do not get to delete.
    public enum RepairDecision: Equatable, Sendable, CaseIterable {
        /// The re-fetch was checked against **current** Hub truth and nothing is behind it.
        /// Load it.
        case load
        /// We could not prove the snapshot is current — and, just as importantly, could not
        /// prove it is broken. The retry threw (offline / 429 / expired token / ENOSPC), or the
        /// Hub still disagrees, or the manifest lookup came back `nil`. Leave the snapshot
        /// exactly where it is, load nothing, and tell the user to tap Download.
        case askUser
    }

    /// The decision after re-fetching a partially-applied snapshot — pure, so the one path that
    /// could cost a user their model is unit-testable without an app.
    ///
    /// `.load` requires **positive proof**: the retry succeeded, it had a fresh manifest to
    /// check against (``DownloadResult/checkedAgainstHub``), and nothing is behind the Hub.
    /// Everything else is ``RepairDecision/askUser`` — including a plain throw, which proves
    /// nothing at all about the bytes on disk.
    ///
    /// - Parameter retry: the outcome of a **plain, manifest-less** re-fetch. Manifest-less is
    ///   load-bearing: `download` does not re-read the Hub when it is handed a manifest, so
    ///   passing the launch-time one back in would re-compare against the very sizes that
    ///   raised the flag — structurally unclearable, and wrong whenever the Hub moved under us.
    public static func repairDecision(
        afterRetry retry: Result<DownloadResult, Error>
    ) -> RepairDecision {
        guard case .success(let result) = retry,
              result.checkedAgainstHub,  // "cannot tell" is not "clean"
              result.stillStale.isEmpty
        else { return .askUser }
        return .load
    }

    /// Downloads (or reuses the cache of) the runtime artifacts and returns the local model
    /// directory to pass to `ChatterboxCoreMLModel.load(from:)`, plus what the fetch actually
    /// changed (``DownloadResult``).
    ///
    /// **On the ordinary path nothing is deleted or moved — that is what makes it safe.** A
    /// snapshot behind the Hub is still a *working* snapshot, so it is left where it is and the
    /// fetch simply runs over it; `HubApi` re-downloads the files whose remote etag stopped
    /// matching and leaves the unchanged weights alone. A fetch that fails (offline, cancelled,
    /// ENOSPC) therefore costs the user nothing: the model is still there, still loadable, and
    /// the size check fires again next launch. The one thing that *can* be lost is the file
    /// `HubApi` is actively replacing — `copyFileToDestinationIfNeeded` removes-then-copies, not
    /// atomically — and that self-heals on the next online launch.
    ///
    /// "The fetch didn't throw" does **not** mean the fresh bytes landed; see
    /// ``DownloadResult`` for what it does mean and how to tell the cases apart.
    ///
    /// No size gate here: this function always applies what it is asked to. The unattended
    /// launch-time path is gated on ``autoUpdateByteLimit`` *before* it calls
    /// (``launchPlan(modelOnDisk:dir:manifest:matching:autoApplyLimit:)``); a caller that gets
    /// here — the Download button, `force:`, the CLI — is explicit user intent.
    ///
    /// **Exactly three paths destroy a snapshot, and each has a positive reason to.** The rule
    /// they share: *we never destroy a model we cannot prove is broken.*
    ///   1. `force:` — the user explicitly asked to start over ("Force re-download").
    ///   2. The ``incompleteMLPackage(in:)`` self-heal, below — what we hold is provably broken
    ///      (truncated weight / unresolved LFS pointer) and cannot be loaded anyway. Note it
    ///      wipes the **whole snapshot dir**, not just the offending package.
    ///   3. **Autorun's failed-LOAD recovery** (`ContentView.tryAutoRun` → `autoDownload(force: true)`,
    ///      the only automatic wipe there is): a snapshot that will not load is *provably*
    ///      broken, not merely stale, so there is nothing there worth protecting. This is the
    ///      one destroy path no user tap authorised, and it is deliberately reachable only
    ///      **after a load has actually failed** — never on suspicion.
    /// A stale snapshot is on none of these lists, and neither is a
    /// ``DownloadResult/isPartiallyApplied`` one: autorun re-fetches it plain (deleting
    /// nothing) and, if that cannot *prove* the snapshot current, stops and asks the user
    /// rather than destroying something it only suspects — see ``repairDecision(afterRetry:)``.
    ///
    /// - Parameters:
    ///   - hfHome: When provided, the selected folder is treated as
    ///     `HF_HOME` and the snapshot is written under `<hfHome>/hub`. Otherwise the
    ///     environment-inferred base is used.
    ///   - hfToken: An explicit Hugging Face access token used to authenticate the
    ///     download. Needed only for **private** repos (the default `iliasaz/...`
    ///     repos are public). Resolution order:
    ///       1. this explicit parameter,
    ///       2. the `HF_TOKEN` environment variable,
    ///       3. the `HUGGING_FACE_HUB_TOKEN` environment variable,
    ///       4. the standard CLI token files (`$HF_TOKEN_PATH`, `$HF_HOME/token`,
    ///          `~/.cache/huggingface/token`, `~/.huggingface/token`) — so a prior
    ///          `hf auth login` also works (see ``resolvedToken(_:)``).
    ///     A public repo needs no token at all.
    ///   - force: Wipe the local snapshot and re-fetch it from clean, even when it looks
    ///     current (the app's "Force re-download" toggle, and the recovery path when a
    ///     present model fails to load). Explicit user intent to start over — the one path
    ///     that deletes a *working* snapshot, and it also ignores ``localBuildSentinel``.
    ///   - manifest: An already-fetched ``remoteManifest(repoId:hfToken:)``. The caller that
    ///     just used one to *decide* to call this (the app's launch check) passes it back in
    ///     so the update costs one Hub lookup, not two. `nil` → looked up here, but only when
    ///     there is an existing snapshot to check.
    public static func download(
        repoId: String = defaultRepoId,
        hfHome: URL? = nil,
        hfToken: String? = nil,
        matching globs: [String] = runtimeGlobs,
        force: Bool = false,
        manifest: [String: Int]? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        let resolvedToken = resolvedToken(hfToken)

        let downloadBase: URL? =
            if let hfHome {
                base(forHFHome: hfHome)
            } else {
                environmentDownloadBase()
            }
        let api = HubApi(downloadBase: downloadBase, hfToken: resolvedToken)
        let repo = Hub.Repo(id: repoId)
        func fetch() async throws -> URL {
            try await api.snapshot(from: repo, matching: globs) { p in
                progress?(p.fractionCompleted)
            }
        }

        let fm = FileManager.default
        let target = downloadDirectory(hfHome: hfHome, repoId: repoId)

        // The Hub's authoritative sizes, fetched ONCE and reused for the post-fetch check.
        // Only worth asking when there IS a snapshot to compare against (on a fresh install
        // every file is absent, which `fetch` handles), and never under `force` (which is
        // about to delete it). `nil` == "cannot tell" (offline / no token / 5xx) → `staleFiles`
        // answers `[]`, and this whole block is inert.
        var remote: [String: Int]?
        var staleBefore: [String] = []
        if force {
            Log.download.notice(
                "[download] \(repoId, privacy: .public): force — wiping the local snapshot")
            try removeDownload(hfHome: hfHome, repoId: repoId)
        } else if fm.fileExists(atPath: target.path) {
            // (`??` can't take an `await` on its right-hand side — it's an autoclosure.)
            if let manifest {
                remote = manifest
            } else {
                remote = await remoteManifest(repoId: repoId, hfToken: resolvedToken)
            }
            staleBefore = staleFiles(dir: target, manifest: remote, matching: globs)
            if !staleBefore.isEmpty {
                // Nothing to do about it here but say so and fetch: `HubApi` re-downloads a
                // file whose remote etag stopped matching the stored one, which repairs
                // exactly these and leaves the rest of the snapshot on disk untouched.
                Log.download.notice(
                    "[download] \(repoId, privacy: .public): \(staleBefore.count) file(s) behind the Hub (\(staleBefore.prefix(4).joined(separator: ", "), privacy: .public)) — re-fetching")
            }
        }

        var dir = try await fetch()

        // Self-heal an incomplete model. HubApi fetches newly-added files into an
        // existing cache correctly (verified by HubDownloadTests), but an
        // interrupted/partial incremental update can leave a `.mlpackage` whose
        // weight is missing or an unresolved LFS pointer. That must NOT reach
        // Load — a truncated weight compiles to a broken model (the iPhone
        // `ANECCompile FAILED` a clean reinstall fixed). If any package looks
        // incomplete, drop the snapshot and re-fetch once from clean.
        //
        // A bare wipe, deliberately: unlike a merely *stale* snapshot (which still works, and
        // so is never deleted), one that fails the completeness check is provably broken and
        // unloadable — there is nothing here worth protecting.
        if let bad = incompleteMLPackage(in: dir) {
            Log.download.notice("[download] \(bad, privacy: .public) is incomplete (missing/truncated weight); forcing clean re-download")
            _ = try? removeDownload(hfHome: hfHome, repoId: repoId)
            dir = try await fetch()
            if let stillBad = incompleteMLPackage(in: dir) {
                throw ChatterboxError.missingFile("\(stillBad): incomplete model package after clean re-download")
            }
        }

        // Did the fetch actually land the fresh bytes? Answered against the FINAL on-disk state
        // (after the self-heal above), because that is what the caller is about to load.
        //
        // `HubApi.snapshot` returns success without downloading anything when the network is
        // down or the task is cancelled, so a stale file can survive a "successful" call — and
        // because it applies a commit one file at a time, a cancellation *between* two files of
        // the same commit leaves a NEW spec beside an OLD weight, which nothing else here
        // catches (the old weight is complete). Reported, never thrown: an otherwise-good
        // download must not become a hard failure, and what we hold is still exactly the
        // snapshot we started with. The caller reads `isPartiallyApplied` to decide whether it
        // may load this, and either way the same size check fires again next launch. (A commit
        // landing between the manifest lookup and the fetch trips `stillStale` too — transient,
        // self-correcting, and indistinguishable from the real mix, which is why nothing here
        // is allowed to *destroy* on the strength of it.)
        //
        // `remote == nil` is "cannot tell", and it is reported as such (`checkedAgainstHub`):
        // an empty `stillStale` for want of a manifest must not read as "verified current".
        let stillStale = staleFiles(dir: dir, manifest: remote, matching: globs)
        let repaired = staleBefore.filter { !stillStale.contains($0) }
        if !stillStale.isEmpty {
            Log.download.error(
                "[download] \(repoId, privacy: .public): \(stillStale.count) file(s) STILL differ from the Hub after the fetch, \(repaired.count) repaired (\(stillStale.prefix(4).joined(separator: ", "), privacy: .public)) — snapshot left as-is, will re-check next time")
        }

        let entries = (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        // Report each model package's weight size so an incomplete model is
        // obvious in the log (the real "downloaded but won't load" signal).
        let weights = entries.filter { $0.hasSuffix(".mlpackage") }.map { name -> String in
            let wb = dir.appendingPathComponent(name)
                .appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
            let mb = (((try? fm.attributesOfItem(atPath: wb.path))?[.size] as? Int) ?? 0) / 1_000_000
            return "\(name)=\(mb)MB"
        }.joined(separator: ", ")
        Log.download.debug("[download] repo=\(repoId, privacy: .public) dir=\(dir.path, privacy: .public)")
        Log.download.debug("[download] weights: \(weights, privacy: .public)")
        Log.download.debug("[download] entries: \(entries.joined(separator: ", "), privacy: .public)")
        return DownloadResult(
            directory: dir, repaired: repaired, stillStale: stillStale,
            checkedAgainstHub: remote != nil)
    }
}
