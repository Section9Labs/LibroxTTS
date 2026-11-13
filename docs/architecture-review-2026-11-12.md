# LibroxTTS 1.0 architecture proposal

Superseded as the release direction by [the execution redesign](1.0-execution-redesign.md)
after the user requested a substantially larger improvement. The findings below
remain supporting qualification and implementation detail.

Reviewed against published `v0.9.0`, commit
`07fcf437004027f58ad8bb16de7877d0ee74a9a8`, on 2026-11-12. Remote main still
matches that revision. This is a source/evidence review, not an implementation or
new benchmark. No runtime, public declaration, model or audio has changed.

## Scope and acceptance rule

Make 1.0 a compatibility and operational-readiness milestone with measured internal
improvements. Preserve every existing public product/type/signature and applicable
availability, defaults, Codable representations, errors/precedence, source ranges,
chunk/event order, backpressure, cancellation/retirement, model/voice/style IDs,
asset receipts and prepared-audio identities. Include directly usable engine and
runtime types, not only the LibroxTTS facade. Do not redefine existing benchmark
fields. The 2,802-entry macOS inventory supplements behavioral and client tests;
it is not a binary ABI guarantee.

Compare candidate and 0.9 with the same backend, OS, toolchain, asset bytes, seeds,
request sequence and cold/warm state. Require exact PCM, frame boundaries and
chunk events. Test each supported platform separately: cross-backend or cross-OS
bit identity is not assumed. Do not accept a tolerance merely to make an audio
regression pass. No changes to weights, sampler steps, RNG draws, arithmetic
ordering, normalization results, chunking, DSP output or platform routing.

The 0.9 release's Swift 6.3.3 Debug/Release/iOS CI passes; its earlier local
candidate report predates that release work. Physical-device, sustained thermal/
energy, wider language/listening and Basic/Qwen real-model coverage remain gaps.
Do not present minimum-toolchain CI as still wholly unverified.

## 1. Compatibility and release qualification [Strong]

Files: `.github/workflows/swift.yml`, `Scripts/check-public-api.py`,
`Tests/PocketTTSCoreMLTests/Release07AudioTests.swift`,
`Tests/PocketTTSCoreMLTests/Release09BenchmarkTests.swift`,
`Tests/KokoroKitTests/NarrationBackendParityTests.swift`, `Examples/MaxDeviceProbe`.

Signal: API/audio parity exists locally, but CI currently runs package tests,
Python compilation and a generic iOS example build. External model suites remain
opt-in; the API inventory and Catalyst gate are not wired into that workflow.
The new sidecar uses short excerpts rather than long-running books.

Proposal: one reproducible qualification runner and versioned evidence manifest.
Run fast API/Codable/error/callback/client gates per change; run real-asset parity
and performance in an explicitly provisioned release lane. Include the minimum
and app-production toolchains, iOS/Catalyst client builds, a Basic real-model
baseline, all seven Max languages and representative Plus styles. Qualify Qwen
separately before modifying that product. Use paired 0.9/candidate builds on each
OS rather than treating one machine's golden waveform as universal.

Add 30–60 minute representative playback runs on available iPhone/iPad and
Mac/Catalyst hosts. Measure first accepted/audible audio separately, throughput,
p50/p95 frame service, underruns, peak/sampled memory, post-unload retention,
thermal state and energy where measurable. Exercise book/language/voice changes,
seeks, slow/failing receivers, memory pressure and lock/background/routes.
Playback acceptance belongs to a test host/app, not new SDK playback ownership.

Benefits: repeatable compatibility evidence and a defensible 1.0 support policy;
catch toolchain/resource packaging issues before publishing.

Proof: all old fixtures remain immutable; both public and direct-engine clients
compile; seeded PCM/events remain exact; no incomplete stream is cached as complete.

Commit plan: runner/receipt schema; CI/client gates; expanded parity workloads;
physical-device and sustained-run evidence. Report unavailable checks explicitly.

## 2. Recovery across actual process termination [Strong]

Files: `Sources/KokoroKit/VerifiedAssetTransfer.swift`,
`Integrations/PocketTTS/Sources/PocketTTSCoreML/PreparedModelTransaction.swift`,
`Tests/KokoroKitTests/VerifiedAssetTransferTests.swift`,
`Tests/PocketTTSCoreMLTests/PreparationRecoveryTests.swift`.

Signal: injected throws/cancellation cover many transitions, but process termination
bypasses defer cleanup. Download publication can leave `.download-UUID` siblings;
compiled generation recovery has its own ownership and validation rules.

Proposal: subprocess tests that terminate at controlled staging/adoption/receipt
points, then reopen with the real filesystem adapter. Add narrowly owned recovery
metadata/cleanup only where tests reveal a gap. Never delete a valid generation
merely because another stage is incomplete. Preserve host-serialized installation,
full hashes, error categories and existing progress sequence.

Benefits: stronger interrupted-update recovery and bounded abandoned storage.
The existing publication seam already has production and fault-injection adapters;
use it rather than introducing a second generic installer framework.

Proof: prior valid files survive failed staging; reopening selects only verified
bytes; failed cleanup cannot turn a successful install into a false failure;
unrelated files are untouched. A kill/restart test is not power-loss durability.

Commit plan: process-exit harness; targeted recovery fixes; restart/storage tests.
Do not quietly add automatic network retries, resume semantics, concurrent installs
or multi-file transactions: these can change observable errors and ordering.

## 3. Faster cold English dictionary preparation [Worth exploring]

Files: `Sources/PronunciationEnglish/Lexicon.swift` (884 lines),
`Sources/PronunciationEnglish/WeakResourceCache.swift`, its bundled JSON resources,
`docs/Preparation09.swift` and pronunciation parity suites.

Signal: 0.9 removes repeated decoding while owners remain alive, but measured cold
construction still costs about 0.55–0.64 s. The loader uses JSONSerialization,
creates typed dictionaries, grows casing variants, merges supplements and validates
phonemes. Those operations still occur on the first owner after resources retire.

Proposal: prototype a generated, indexed bundled representation or typed loader
that reduces cold decoding/allocation, keeping lookup policy separate from resource
loading. Retain the existing source resources/provenance and a versioned generator.
Keep weak ownership; do not retain every language permanently. A new representation
must preserve the existing variant/null handling, casing, merge precedence and
error behavior rather than silently correcting them. Account for OS-sensitive
Unicode casing instead of baking one machine's assumptions into generated data.

Benefits: potentially faster first Basic/English preparation and lower allocation
peaks. No numerical speedup target is claimed until measured. French already uses
mapped sorted TSV lookup; duplicating English-style caching there is not justified.

Proof: compare every effective dictionary lookup/variant and complete pronunciation
corpus against the old loader, then exact Basic audio. Test failure/retry, dialect
separation, concurrent owners, last-owner release and deterministic generation.

Commit plan: cold allocation profile/reference tests; alternative loader/resource
prototype; paired cold/warm/memory measurements; adopt only a material improvement.
Preserving observed resource failures is part of the design, not an afterthought.

## 4. Core ML input workspace and backend-local components [Worth exploring]

Files: `Integrations/PocketTTS/Sources/PocketTTSCoreML/PocketTTSCoreMLEngine.swift`,
particularly `Loaded.sample`, `transform`, `emptyMimiState` and `decode`.

Signal: sampling creates small input arrays for s/t/steps on generic sampler counts;
transform creates a position array; decode creates a latent array and feature
provider each frame. The same private Loaded type owns model loading, input
construction, flow execution, voice conversion and Mimi state operations.

Proposal: profile allocation/copy costs first. Introduce a render-owned fixed-shape
input workspace and cohesive private flow/transformer/codec helpers only where
that gives lifecycle ownership and testable failure seams. Reuse private input
storage after synchronous prediction completes; keep output arrays, published PCM,
voice/attention state and borrowed Core ML results out of shared pools. Keep exact
s/t Float conversion expressions, RNG ordering and specialized 4/8-step graphs.

Benefits: potentially lower per-frame allocation pressure, more predictable tail
latency and more local lifecycle code. The default four-step path does not allocate
the generic s/t/steps inputs, so those savings alone cannot justify a default-path
speed claim. No universal engine abstraction or public type move is proposed.

Proof: exact PCM/events for steps 1–8, cold/warm, continuation, styles, cancellation,
recovery and strided/aliased arrays. Check retained callback frames are unchanged
by later calls. Measure both default and generic-step paths plus memory/allocations.

Commit plan: allocation profile and ownership tests; backend-local extraction;
workspace experiment; paired end-to-end decision. Do not adopt on microbenchmarks
alone or repeat the neutral 0.9 DSP reuse work without new evidence.

## 5. Private MLX capacity cache [Speculative; separate experiment]

Files: `Integrations/PocketTTS/Sources/PocketTTSMLX/Runtime/KVCache.swift`,
`PocketTTSModel.swift`, `PocketTTSTransformer.swift`, `Transformer.swift`,
`Tests/PocketTTSMLXTests/CacheContract09Tests.swift`.

Signal: the 0.9 actual-model capacity experiment preserved sixteen tested CPU/GPU
audio cases, but failed public mutable-reference semantics. It was correctly
rejected; it did not establish a paired end-to-end improvement.

Proposal: design an internal-only cache path while retaining the original public
KVCacheSimple and all public model entry points. This is nontrivial: public
PocketTTSState.flowCache, transformer cache parameters/makeCache and model state
methods expose concrete caches. Merely renaming a class or hiding a field does not
make the optimized state private. Avoid two divergent copies of inference math.

Benefits: possible lower append cost during long generation. Memory and GPU gains
are uncertain; no promised percentage and no requirement to adopt it for 1.0.

Proof: all public aliasing/snapshot/offset/trim/reset semantics unchanged, exact
long-model PCM/events including growth and continuation, unchanged RNG/arithmetic,
then paired CPU/GPU/device throughput and memory. Reject if boundaries cannot be
kept clean or the total gain is inconclusive.

Commit plan: interface/exposure audit; test-only integration; equivalence gates;
paired performance; explicit adoption/rejection record. Keep outside the core 1.0
critical path.

## Optional Qwen maintenance track [Worth exploring after real-model baselines]

Files: `Sources/QwenANE/QwenANEEngine.swift`, `QwenTalkSession.swift` and vocoder
queue implementation. Public options are mutable and read at several points;
render serialization alone does not guard outside configuration writes. The
onAudio documentation also overstates cancellation: accepted prior chunks cannot
be retracted, and the implementation drains queued work on failure/cancellation.

Characterize supported between-render configuration, session sampler lifetime,
queue drain and callback ordering before introducing synchronized configuration
snapshots/internal ownership helpers. Do not change public callback Sendable
requirements, defaults, partial-stream semantics or render/session sampling behavior.
Real-model golden audio is required before adopting production changes. Document
actual behavior without inventing a new cancellation promise.

## Recommended order and exclusions

Do 1, then 2, then measured experiments 3 and 4; finish with the full qualification
matrix from 1. Start the capacity work only as a separately bounded experiment.
Qwen remains a separate track until its real-model baseline is available.

Top recommendation: turn the existing compatibility evidence into release gates
and add actual process-exit/sustained-device tests. A solid 1.0 does not require a
large rewrite or a claimed inference speedup.

Not recommended: changing weights/quantization/sampler counts, attention history,
backend routing, chunk boundaries or DSP; skipping hashes to make prompt caching
look faster; a global PCM/model cache; moving/removing public types to reduce the
module graph; retries that hide existing failures; splitting files only because
of line count. True MLX-free iOS packaging remains a separate API/dependency design,
not a safe drop-in refactor given public MLX runtime types and existing links.
