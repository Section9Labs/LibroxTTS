# Optional Chatterbox narration backend

This separate Swift package integrates a native Core ML Chatterbox Multilingual
renderer with the existing `KokoroNarration` library. It does not change the dirty
root package manifest, Libros playback, downloads, subscriptions, or release state.
“Enhanced Pro” remains a proposed product routing choice, not a quality result or
an implemented entitlement. No native Swift MLX backend is implemented here.

Products: `LibroxChatterbox` library and `librox-chatterbox-probe` executable.
Minimum runtime targets: macOS 15 / iOS 18. Physical-device results belong to the
separate `DeviceProbe` owner; a successful Mac build does not establish iPhone behavior.

## Existing library route

1. The existing `BookNarrationPlanner.plan` produces `BookNarrationUnit` values.
2. `ChatterboxNarrationBridge.prepare` checks the unit's source range and exact
   original text, retains voice/speaker identity and performance evidence, and
   consumes `NarrationPerformance.chatterboxSuggestion`.
3. The host explicitly maps each stable cast voice ID to a Chatterbox conditioning
   file. An absent mapping throws; Kokoro style vectors cannot serve as reference
   conditioning, and multiple characters are not silently assigned the default voice.
4. `ChatterboxNarrator.stream` sends natural text, explicit language, exaggeration
   and CFG to the native renderer and delivers ordered mono 24 kHz Float samples.
   No phoneme string, invented `[whisper]` tag, emotion prompt, pitch shift, or
   cleanup filter is added. Named delivery/mood semantics remain marked unmapped
   when the model only offers intensity controls.
5. A host may buffer a completed bounded unit and call
   `ChatterboxConversationSession.completeUnit` with the existing dialogue timing
   context. This delegates to `ConversationCadence`; it is not applied to arbitrary
   streaming chunks. Reset it on seek, book, account, or playback-generation changes.

The current planner still uses the Kokoro cast catalog and phoneme-oriented unit
limits. This bridge deliberately reuses those units; it is not a new renderer-neutral
chapter planner. Chatterbox's additional language catalog must not imply that the
existing planner has native pronunciation/acting support for every one of them.

## Runtime and cache contract

`ChatterboxLookaheadCache` optionally prepares the current planner unit plus at
most two contiguous upcoming units. It uses the existing single-decoder / single-
synthesizer batch pipeline, skips completed cache hits, and returns the original
unit/cast/source identity with each ready entry. Use its awaited `onReady`
callback to start current-unit playback immediately while the upcoming two are
prepared; announcements preserve source order, including cached gaps. Call
`samples(for:)` to feed the existing PCM playback queue. Awaiting only the final
array delays startup until all three finish. This API is not yet wired into
Libros playback.

Supply a dedicated disposable cache directory and the exact model/reference
hashes when constructing `ChatterboxCacheUnit`. Entries contain complete finite
24 kHz Float32 PCM, an explicit format/version header and an integrity digest;
partial or corrupt entries are never returned as ready audio. The default disk
budget is 64 MiB, at most 256 entries, and 120 seconds per unit. Eviction preserves
the requested three-unit window and ignores unrelated files and symlinks. A
window that exceeds the budget fails explicitly instead of discarding protected
audio. Complete entries from a failed window can be reused on a later attempt.

The host owns one playback-generation task: cancel and await it before seeking,
switching chapters/voices or stopping, then prepare the new window. Returned
cache entries do not advance the reading position. Source text, voice references,
expression settings and model identities remain part of cache identity. Keeping
two units ahead does not make a slower-than-playback decoder sustainable.

- Call `load(modelDirectory:watermarkDirectory:computePolicy:)` using installed
  assets. The adapter never downloads weights. Perth is constructed from local
  assets so the upstream automatic download fallback is not entered.
- `stream` is an awaited operation with an async consumer callback. Cancel the
  calling task to stop it. Concurrent stream/load/reference operations and unloading
  during synthesis throw `busy`. Requests reject more than 2,000 characters/8,000
  UTF-8 bytes rather than silently truncate whole chapters. Upstream streams still
  buffer produced chunks; callback pacing alone is not full model backpressure.
- Empty/nonfinite audio and a reached configured speech-token cap are errors.
  No independent gain normalization or clipping is applied. A host must treat a
  failed partially delivered utterance explicitly rather than marking it complete.
- `chunk.timings` carries upstream prefill/decode/synthesis/watermark seconds,
  speech-token count and decode backend. These are stage measurements, not an
  estimate from wall time; stages may overlap across chunks. Model load and host
  scheduling are measured separately by the caller.
  Host assembly time/cache hit are also available. With the explicit diagnostic
  `CHATTERBOX_PROFILE_DECODE=1`, `decodeSteps` reports aggregate input preparation,
  Core ML prediction, logits/CFG and sampling times, without per-token logging.
- `request.cacheKey(modelManifestSHA256:conditioningSHA256:)` hashes exact text,
  language, exposed sampling/expression controls, token cap, seed, stable cast IDs,
  backend revision and performance revision. Include a distinct `rendererProfile`
  when selecting padded flow or nondefault compute policy. The host must supply hashes of its
  immutable model manifest and actual conditioning bytes. Kokoro's existing cache
  revision alone is insufficient. This package does not mutate an app cache.
  The exposed `seed` controls T3 sampling only; upstream flow noise is separately
  stochastic. It is not a promise of deterministic waveform reproduction.

`.automatic` preserves upstream per-stage choices and T3 fallback; it does not
force `.all` and disable that fallback. `.neuralEngine` uses the upstream stage-aware
profile, which deliberately keeps S3Encoder on CPU. `.cpuOnly` and `.gpu` are explicit
diagnostic choices. `selectedT3ComputeUnits` reports the successful load configuration,
not measured NPU/GPU residency. CPU fallback can occur within allowed compute units.
No background execution, audio-session ownership, entitlement, or lock-screen guarantee
is provided. A future iOS 26+ host can separately investigate supported-resource-gated
`BGContinuedProcessingTask` GPU execution; this package adds no such app integration.
`load(... padFlowToMaximum: true)` selects fixed flow padding without process-global
environment mutation; nil preserves upstream defaults. This is an experimental
diagnostic profile, not a validated GPU fix or automatic default. Padded full-pipeline
runs also failed intermittently on the evaluation Mac. Unload before changing an already loaded profile.
`load(... computePolicy: .automatic, t3ComputeUnits: .cpuAndGPU)` overrides only T3
for controlled comparisons; synthesis and watermark policies remain unchanged.
Multilingual inference rejects the full text/prefix/generation budget before assembly
when it cannot fit the loaded model's prefill window or KV cache. For a 512-position
cache and generation cap 350, at most 126 encoded text tokens fit the 36-row fixed
conditioning/two-BOS overhead. Replan rejected source units; do not silently lower the cap.

The canonical V3 assembler retains learned text positions in the unconditional
CFG lane and appends both position-zero BOS rows. Its EN/ES input arrays match
the pinned Python MLX fixture bit for bit with shared conditioning. This isolates
assembly; it does not prove encoder, sampler, waveform or voice parity. Cache
revision `chatterbox-coreml-v3-librox-3-canonical` separates its PCM from earlier
community-frontend results. Historical phone measurements retain their original
source identities and are not measurements of this corrected frontend.

## Optional bounded batch scheduling

`streamBatch(_ requests: [ChatterboxRequest], receive: ...)` accepts 1...8 existing
requests totaling at most 32 KiB of UTF-8 text. `ChatterboxBatchChunk` carries the
original request/source/cast/performance metadata, request index, within-request
chunk index, final-chunk marker and audio. Text is never merged and no silence is
injected. Each request retains its language, voice conditioning and options.

One sequential decoder and one sequential synthesizer share the existing model
instance. The channel holds at most two decoded chunks, plus one producer-held
pending chunk and one consumer-held chunk; no unbounded PCM stream is created.
The async callback is awaited before another synthesis starts. Cancellation/error
wakes channel waits and joins both tasks before releasing the busy lease. An
in-flight synchronous Core ML prediction must return before cancellation completes;
host callbacks must also cooperate with cancellation.

This opt-in API does not change the single-request path or default scheduling.
Mock tests prove ordering, overlap, bounded backpressure, source identity and
shutdown, not hardware speed or thermal behavior. The captured iPhone warm baseline
spent about 83–84% of wall time decoding (~58 ms/token), with ~1 second in synthesis.
Hiding synthesis alone cannot make that decoder sustain real-time narration.

`ChatterboxLookaheadCache.prepareWindow` accepts the current unit plus two contiguous
upcoming units. It reuses complete, integrity-checked Float32 PCM from disk and
publishes each ready unit through an awaited, ordered `onReady` callback, allowing
playback before the whole window finishes. One resident decoder/synthesizer serves
cache misses. Default limits are 64 MiB on disk and 120 seconds per unit; atomic
writes, model/conditioning/profile identity and cancellation preserve cache validity.
The host must cancel and await generation when the book, voice or source position
changes. This library does not advance playback or own the audio session.

## Reference preparation and V3 boundaries

`prepareReference` accepts a per-call compute policy and optional per-model overrides;
it never mutates process environment variables. The adapter uses V3's six-second
T3 reference window (150 tokens), retaining the ten-second acoustic window.
The original S3Tokenizer GPU graph crashes MPS on this Mac. Automatic reference
preparation keeps that tokenizer on CPU unless the exact audited repaired graph
and unchanged weight file match the allowlist; explicit GPU on unknown graphs fails
before inference. The `rope-prefix-v2` repair replaces dynamic RoPE gathers with
equivalent prefix slices. Original assets are retained separately.

Default reference `.neuralEngine` is an allowed compute configuration, **not proof
of acceleration**: independent plans found CPU fallback for these clone graphs on
the evaluation Mac. Explicit `.gpu` with the repaired tokenizer did complete native
reference preparation. Do not infer every clone operation ran on GPU from that alone.

Vendored V3 preprocessing preserves full case for English and Spanish and applies
NFKD. Two token-ID regressions match the Python V3 tokenizer. Other languages retain
upstream preprocessing; all-23-language V3 parity is not claimed. Russian defaults to
manual stress marks, not an implicitly downloaded neural stress model.

## Validation and usage

```sh
swift test --scratch-path /tmp/librox-chatterbox-adapter-build -j 4
# Also run the tokenizer-only asset parity test:
CHATTERBOX_TEST_MODEL_DIR=/path/to/multilingual swift test --scratch-path /tmp/librox-chatterbox-adapter-build -j 4
swift run --scratch-path /tmp/librox-chatterbox-adapter-build librox-chatterbox-probe --help
```

The combined suite covers planner/source/cast
bridge, source mismatch, cancellation, busy lease, empty/invalid PCM, request bounds,
cache separation, reference duration bounds, unsafe GPU-reference refusal and en/es
token parity, batch scheduling, context admission and inference-boundary cancellation.
The optional real-asset cache check compares host conditioning assembly exactly;
it does not run Core ML model inference. See the current source-freeze validation receipt.

Native smoke evidence lives at
`/Volumes/T9.2025/LibroxTraining/runs/chatterbox-v3-evaluation-v01/coreml/adapter-smoke-report.json`.
Initial CPU rendering produced finite English 4.20 s and Spanish 5.16 s audio; these
predate the V3 fullcase/six-second corrections and are retained as mechanics diagnostics.
Corrected explicit GPU reference preparation produced 150 T3 and 250 acoustic tokens.
Corrected automatic rendering selected T3 `cpuAndGPU`, then failed in S3CFM's GPU
dynamic-shape lowering. Accelerator repair and physical tests are separately owned;
this receipt does not claim successful corrected accelerated speech or listening quality.

## Host integration points and release boundary

Optional native integration and saved voices: `../ChatterboxMLX/README.md` and
`docs/APP-INTEGRATION-HANDOFF.md` document the reusable native renderer, Librox
director/cadence/cache path, private `ChatterboxVoiceStore`, recording service
and `LibroxChatterboxUI` Create Your Voice sheet. These are not yet wired into
the installed Libros app. Current source hashes and validation are in the app
handoff manifests; earlier source freezes remain tied to their own experiments.

Existing Core ML engine: `Sources/KokoroKit/KokoroEngine.swift`, actor `KokoroEngine`
(`load`, `synthesize`, `synthesizeNarration`, `unload`). Its internal
`DynamicCoreMLModel`/`DecoderBackend` are Kokoro-specific, not generic backend protocols.
Existing reference-aware engine: `Sources/QwenANE/QwenNarrator.swift`, actor
`QwenNarrator` (`load`, `render`, `unload`), with `QwenVoicePrep` and `QwenVoiceFiles`.
Kokoro model installation uses `ModelAssets` plus `KokoroCatalog.AssetManifest` hashes.

The inspected primary Libros checkout still has `QwenTTSEngine`/`NeuralSpeechReader`
coupling and a Qwen-specific `NeuralTTSModel` in `TTSModelStore.swift`. It is not the
release owner's combined cut. A later host adapter should preserve `ListeningCenter`
audio-session and source-position ownership and add backend/capability/model selection
at that seam; it must not route Chatterbox text through Kokoro phonemization.

Source approval, app adoption, commit, release integration and physical validation
remain separate. The release owner controls app build numbers and distribution.
This package is not `READY_TO_SHIP`.

## Provenance and licenses

See `Vendor/PROVENANCE.md`, the bundled MIT notice, `Vendor/UPSTREAM-PATCH.diff`,
`Package.resolved`, and `source-freeze.json`. Model cards label the pinned multilingual
and Perth weights MIT. Preserve model/source attribution and all dependency licenses
when distributing. The license does not establish rights to arbitrary reference audio
or an imitated voice. Evaluation used a synthetic macOS Samantha recording, not a
human identity or a claim of perceptual clone fidelity.
