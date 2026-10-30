# Resident Mac chapter renderer — local integration contract

`LibroxChatterboxMac` is an additive macOS-only SwiftPM product. Its implementation is a local checkpoint until signed, pinned, and qualified through an authorized real-generation host. It is not a `ChapterService` or a CloudKit backend. The existing reader and native companion must not adopt an uncommitted tree or replace their frozen SDK pin for a synthetic fixture.

The app supplies an authorized exact chapter, language (`en`/`es`), delivery choice, direction/grouping, optional reviewed source-bound expressions, and seed. It does not assemble model outputs, cadence, codecs, or source/frame maps.

```swift
let worker = ChatterboxMacResidentRenderer(assets: assets)
let startup = try await worker.prepare() // Once; cold validation/loading measured separately.
let request = try ChatterboxMacChapterRequest(
    text: exactChapter, language: "es", delivery: .smaller,
    grouping: .sentences, performanceDirections: reviewedChapterDirections)
let binding = try await worker.bindChapter(
    source: originalChapterIdentity, request: request, session: session, gate: gate)
let completed = try await worker.renderChapter(
    binding, gate: gate, outputDirectory: privateWorkerDirectory)
let playable = try await binding.adopt(
    completed, gate: gate, storageDirectory: privateCustodyDirectory)
// playable is the existing account-bound ChapterLocalArtifact handle.
// Access playback through playable.withFileAccess(session:gate:_:).
// Do not play completed.audioFile directly.
await worker.shutdown() // Terminal; cancel/join before any model/runtime release.
```

Use a dedicated native worker process with `MLX_ENABLE_TF32=0` set before any MLX initialization. Runtime bootstrap is actor-owned and precedes all model arrays. The existing original Standard decoder identity and startup oracle remain mandatory. Native acoustics retain full F32 weights, ten cosine/CFG steps, .7 acoustic guidance, deterministic-gather-2 waveform policy, fixed vocoder request seed, no watermark/Perth, and no peak normalization. Compiled decode trials, parallel workers, shorter solvers, private recordings, and implicit fallback are not exposed by this API. It uses serial preparation and the existing buffer-trim policy; no new performance improvement is claimed.

Before and after frontend loading, exact admission checks the 20 required frontend files and seven explicit absent tokenizer/config alternatives bound by the frozen native EN/ES run. This is a checksum/data-admission guard, not a replacement decoder oracle. The SDK model-pack identity binds these pins together with decoder, oracle and full-F32 acoustic checkpoint identities. No alternate frontend or mixed checkpoint is silently accepted.

`prepare()` validates/loads once, and repeated calls while ready reuse that backend. Models remain resident between chapters. A second operation while loading/rendering is rejected. `shutdown()` signals cancellation without waiting for the actor's mailbox, then awaits the exact owned loading/rendering task before clearing backend, acoustic model, and runtime handles. A detached codec task is explicitly cancelled and joined by its parent. Terminal shutdown cannot reopen the worker. A caller cancelling prepare/render must await the operation before discarding its owner.

The exact chapter is fully planned before model units begin, within the reviewed chapter scope: 131,072 UTF-16 units, 393,216 UTF-8 bytes, 4,096 directed units. Existing model/token/output/resource guards remain unchanged. The SDK streams its existing three-unit windows into one private PCM spool, maintaining one generation and continuous global source positions/cadence. The spool rejects ordering changes, generation changes, grapheme splits, source mismatches, missing non-whitespace text, invalid fragments, and nonfinite/out-of-scale samples. Attachment placeholders may occupy unspoken gaps; their original offsets remain intact. Actual post-cadence frame counts define each `ChapterAudioUnit`. Component fragments do not gain invented sentence/word audio timestamps.

PCM is written in 65,536-frame chunks. The file-backed exporter then verifies the exact spool hash while encoding and while decoding/comparing the output. AAC-LC requested 64 kb/s is the new request default; explicit lossless uses ALAC24. The original PCM is never reconstructed from lossy audio. Delivery, expression, planner/cadence/scope revision, seed, grouping, direction, and renderer profile bind the local settings digest. Complete audio and a read-only JSON receipt are published without replacing an existing file. The receipt is linked last after encoded-audio verification; cancellation or storage failure after a completed link can leave output needing reconciliation. A file's presence alone is not an accepted return value or playback acknowledgement.

`bindChapter` is the canonical SDK bridge: it validates the original book/chapter/extraction source identity against the exact text and constructs `ChapterRenderRecipe`, `ChapterRenderRequest` and `ChapterSubmission` from the actual resident backend, conditioning/model identities and effective expression/sampling policy. Hosts do not reconstruct a recipe from an opaque settings digest. Delivery is excluded from the synthesis-options identity and included in the delivered render key. Receipt V2 records the exact bound render key, account partition and producer epoch. Bound rendering validates the gate at admission, passage delivery and export/publication boundaries; the service must also cancel and join on lifecycle revocation.

`binding.adopt` rejects unbound diagnostic outputs, other chapters, recipe/profile/codec mismatches and stale epochs. It creates and validates the canonical `ChapterArtifactManifest`, then delegates actual byte-hash/format/frame/sample verification and private copying to `ChapterLocalArtifact.adopt`. The original file is preserved. No playable state exists until verified custody returns under the current gate. The renderer does not discover an account or infer its partition/environment; the host/service supplies its actual admitted session and owns that gate's lifecycle.

This binding is an immutable **live-process** value, not a serializable cross-process authorization or durable spool. A producer epoch cannot stand in for a reader process's current epoch. The additive `ChapterLocalHandoff` component publishes immutable complete files and re-adopts under the receiving role's own request/source/session/gate; see `CHAPTER-LOCAL-HANDOFF.md`. Durable intent/reference journals, actual signed-process wiring, a catalog and a `ChapterService` factory remain pending. No cross-process runtime or cloud backend is established by the component tests.

`ChatterboxMacRendererError` is public and has stable NSError domain `LibroxChatterboxMac.Renderer`, codes 0–6 for invalid source, invalid passage, source coverage, storage, closed, busy and unavailable. Native codec/model/OS errors retain their own typed contracts. No host string matching is required; the eventual service translates errors into `ChapterServiceFailure` according to their actual cause.

`artifact.completeWarmSeconds` measures this local operation through receipt synchronization/publication, including planning, model work, cadence, PCM spooling, encoding, and decoded verification. `receipt.warmSecondsBeforeReceipt` ends before receipt publication; cold startup is separate. Neither includes iCloud transfer or host playback startup. Synthetic test timings are not model-speed evidence.

The output directory must be existing, private, app-owned Worker storage with one writer. Every operation creates a fresh UUID job child, never reads the reader's mutable journal, and preserves completed files on shutdown. This prototype retains completed PCM and unit caches alongside audio for verified reuse/recovery. Aggregate disk retention, durable adoption/checkpoint indexing, account epochs, immutable reader/worker spool transfer, and conditional distributed claims/publication still need their own implementation. It does not protect against adversarial same-user mutation of a private job directory. The app must perform existing artifact/account admission before crossing those boundaries.

Validation at this checkpoint uses synthetic conditioning and fake rendering with real WAV/AAC/ALAC codec work. Source coverage, Unicode, actual gapless decoding, repeated resident factory use, missing-output rejection, cancellation, failed-load cleanup, and join-before-close are tested. No model forward, new audio-quality approval, signed production host, live account/cloud call, full-chapter throughput, or five-times-playback acceptance is established by these tests. LocalReview353's synthetic-only permission does not authorize calling the real model factory.
