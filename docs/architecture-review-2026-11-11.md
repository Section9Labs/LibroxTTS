# LibroxTTS 0.7 — compatible performance and reliability

## Recommendation

Make **0.7 a measured internal-runtime release**, preserving the 0.6.2 public
surface, saved settings, model assets, synthesis decisions and host integration.
There are credible improvements here without retraining or swapping models.
The strongest opportunities are repeated text preparation, unnecessary model
loading/retention, tensor transport, and lifecycle/installation recovery.

Do not promise a multiplier for the whole library. Planning, cold startup,
steady inference, memory and playback continuity are different workloads.
This review establishes candidates and a baseline; it does not implement or
release the proposed runtime changes.

## Baseline and scope

- Source: tag `v0.6.2`, commit `f75bacfbdc86c0c6dd81f0fb11cb9bcd160e49dd`.
  Remote `main` was independently checked and matched this commit.
- Isolated branch: `codex/0.7-architecture-review` in
  `/Users/matt/Code/swift/librox-tts-07-review`.
- The initiating checkout is an older Companion/Chatterbox branch. Its dirty
  files were preserved. Companion, Chatterbox and CloudKit workers are absent
  from 0.6.2 and must not accidentally be reintroduced or become the release base.
- Inventory: **20 products, 31 targets, 35,184 Swift lines**, including tests and
  executable probes, excluding dependencies and inactive experiments.
- Survey covered every active target and test area. Detailed code inspection
  focused on planning, asset handling, engine state, streaming, tensor transport,
  cancellation, memory policies and compatibility. This is not an exhaustive
  numerical audit of every neural layer or linguistic rule.
- [`ARCHITECTURE.md`](../ARCHITECTURE.md) maps current ownership and dependencies.
  [`inventory.json`](architecture-07/inventory.json) records target sizes/edges.
  [`api-baseline.json`](architecture-07/api-baseline.json) records **2,802 public
  module-symbol entries**, including reexports. These are not 2,802 unique APIs.

## What is already good

The code already has substantial architecture worth keeping: actor-owned engines,
an explicit facade lease across actor hops, source-aware plans, pinned assets,
bounded vocoder windows, failure cleanup, synchronous streaming backpressure,
separate host playback ownership, and numerical comparison hooks. Most original
files are modestly sized. Splitting every file or wrapping every engine in a new
public protocol would add churn without solving the expensive paths.

Plus already retains Core ML feature values across its ten generator steps;
it does **not** round-trip every generator step through Swift arrays. Its bounded
vocoder and single active generator specialization are intentional memory controls.
Likewise, Basic's decoder reload on shape changes deliberately bounds workspaces.

## Frozen 0.7 compatibility ledger

| Contract | Required protection |
|---|---|
| Products/imports/public declarations | Keep all current products, including direct engine/runtime APIs, overloads, parameter labels, defaults, isolation and usable conformances. Compile representative 0.6.2 clients unchanged. |
| Platforms/toolchain | Retain iOS/Catalyst 18+, macOS 15+ and Swift 6.3 minimum. A local 6.4.2 pass does not validate the minimum compiler. |
| Persisted values | Preserve `NarrationModel` raw cases, voice/style IDs, `BookVoiceCast`, chunking/sampling/delivery encodings and old defaults. Keep disabled historical selections decodable. |
| New-book behavior | Caro Davy / Calm, Careful reading, temperature 0.3, four steps. Explicit saved choices retain their behavior; steps 1–8 remain supported. |
| Runtime routing | Max Core ML CPU on iPhone/iPad; MLX on Mac/Catalyst. Keep background authorization and explicit CPU-budget semantics. |
| Audio | Mono Float32, Basic/Max 24 kHz and Plus 44.1 kHz. Preserve weights, flow arithmetic, RNG consumption, EOS, continuation, fades, punctuation, pauses and postprocessing. |
| Planning | Exact source ranges, spoken text, voices, paragraph/dialogue boundaries, cast updates, diagnostics and context bindings. No heuristic chunking change disguised as optimization. |
| Streaming | Same frame order/content, synchronous throwing callbacks and backpressure. Completed-chunk events only after accepted PCM; same cumulative half-open sample ranges. |
| Errors/lifetime | Preserve public error types/cases and recoverable behavior; no silent truncation, quality fallback, voice substitution or success for partial output. Unload remains joined with active work. |
| Assets/caches | Existing valid installations remain usable, without mandatory redownload. Preserve published manifests and preparation/render identities when behavior is unchanged. Do not turn a size/mtime check into integrity proof. |
| Host ownership | No new app-side scheduler, audio session, player, mandatory dependency injection, or migration of book positions. |

The symbol snapshot is a **starting artifact**, not a complete compatibility test:
it is macOS-only, omits synthesized members, and does not by itself prove default
arguments, behavior, external subclassing or iOS-only availability. Capture iOS
and Catalyst interfaces, conformance graphs and client-compilation fixtures in
the implementation's first phase. Do not promise binary ABI stability based on
a source-package review.

## Priorities

| Order | Work | Expected benefit | Confidence |
|---|---|---|---|
| 0 | Compatibility and benchmark harness | Makes every later change reviewable | Strong |
| 1 | Text preparation and planning | Lower time-to-plan and cancellation latency on long text | Strong hotspot; algorithmic rewrite needs equivalence proof |
| 2 | Model/conditioning residency and text-only preview | Lower cold/preview cost, less repeated I/O and retained memory | Strong source evidence |
| 3 | Core ML tensor transport and disabled tracing | Less host allocation/copying per render | Strong source evidence; end-to-end gain unmeasured |
| 4 | Renderer admission and failure transitions | Prompt queued cancellation; easier lifecycle tests | Strong source evidence |
| 5 | Installation/compile recovery | Survive interrupted preparation without losing the last usable generation | Strong source evidence |
| 6 | MLX attention-cache storage | Potentially substantial long-passage speed/memory gain | Worth exploring; profile and exact-output gate |
| 7 | Internal shared services and maintenance | Reduce backend drift and testing cost | Strong for narrow helpers; broader target split conditional |

## 1. Text preparation and source planning [Strong]

**Files:** `Sources/KokoroNarration/TextNativeNarrationPlanner.swift:23–38,61–96`;
`Sources/KokoroPronunciation/TextNormalizer.swift:7–55`;
`Integrations/CTNative/Sources/LibroxCTNative/CTTokenizer.swift:29–64`;
`Integrations/PocketTTS/Sources/PocketTTSMLX/Runtime/PocketTTSPassageChunker.swift:63–68,138–160`.

**Signal/problem:** The source planner grows an overlong sentence one grapheme
at a time, calling the full spoken-reading/normalization pipeline on every
prefix. Each Spanish normalization constructs a formatter and several regexes;
Plus also performs CT Unicode normalization. Token-aware Pocket chunking repeats
preparation/tokenization of the same current/joined strings. Cancellation is
checked outside some potentially expensive inner scans.

**Proposal:** An invocation-owned text-preparation context caches immutable
regexes, bounded normalization/token results and source-boundary metadata. Keep
the existing decision algorithm as the oracle initially. Add proven fast paths
for ordinary text, retaining the general path for numbers, Unicode and lexicon
substitutions. A naive binary search is unsafe: replacement rules can make
normalized prefix length non-monotonic, and the old algorithm stops at its first
over-budget prefix. Preserve that behavior explicitly.

**Benefits:** Faster preparation and fewer allocations across Basic/Plus/Max;
one place to inspect text costs. Keep mutable formatters/taggers local to their
owner; do not introduce unsynchronized process-global caches.

**Measured evidence:** A synthetic Spanish sentence with repeated clause commas
and no sentence-ending punctuation took a median **28.91 seconds for Plus** and
**29.61 seconds for Max** at 16,000 scalars in the Release build (three runs each).
At 8,192 scalars both were about 14.8 seconds. This is source planning only, with
no model inference. A one-second stack sample showed repeated normalization and
regex compilation inside the prefix scan. The runs used a shared Mac and partly
overlapped other review work; treat them as hotspot evidence, not a calibrated
device-performance baseline. See the detailed method and confirmation run in
[`architecture-07/README.md`](architecture-07/README.md).

**Proof:** Exact plan snapshots for source ranges, text, boundaries, voices,
cast, diagnostics and cache identity. Include 16,384-scalar inputs, CJK, combining
characters, long numbers, expanding/shrinking dictionary entries and cancellation
during a split. Measure cold/warm planning separately from model execution.

**Commit plan:** (1) Freeze outputs and timing corpus. (2) Reuse rule objects
without changing evaluation order. (3) Add per-plan memoization. (4) Only then
replace repeated prefix scans where differential tests prove equivalence.

## 2. Text preview and immutable conditioning [Strong]

**Files:** `PocketTTSEngine.swift:167–203`;
`PocketTTSCoreMLEngine.swift:43–49,175–187,296–312`;
`CTEngine.swift:111–137`; `KokoroEngine.swift` voice loading.

**Signal/problem:** Both `previewChunks` paths load the acoustic model, despite
needing only configuration/tokenizer data. Core ML renders reread/convert voice
safetensors each invocation; MLX likewise reloads voice state in
`PocketTTSModel.loadVoiceState`. Plus redecodes JSON conditioning when switching
voices. Basic keeps only the current voice pack, so dialogue can cause rereads.

**Proposal:** Separate internal text resources from loaded acoustic resources;
cache a small, byte-bounded set of **immutable** verified conditioning templates
per loaded installation/language. Each invocation gets fresh mutable cache
ownership. Start with the last-used template, expanding only if measured dialogue
workloads justify it. Preserve invalid-assets and loaded-language semantics for
the existing preview method through characterization tests; a lighter preview
must not silently accept an installation the current method rejects.
The existing benchmark deliberately uses preview to warm models. If residency
side effects are relied upon, retain that path and provide additive pure text
inspection; do not advertise an unconditional drop-in preview speedup.

**Benefits:** Avoid expensive model work for inspection and recurring disk work
between units. The Module hides resource lifetime; callers stay unchanged.

**Proof:** Same plans; same seeded PCM across voice A/B/A and style switches;
no cross-render cache mutation; bounded retained bytes; unload invalidation;
unchanged failures for missing/corrupt files. Measure preview, first render and
subsequent renders independently. Moving work out of preview must not be sold as
an end-to-end startup improvement if Play simply pays it later.

**Commit plan:** (1) Extract text-resource ownership. (2) Introduce one immutable
conditioning cache. (3) Add byte accounting/eviction and switch tests.

## 3. Core ML flow-model residency [Strong]

**Files:** `PocketTTSCoreMLEngine.swift:218–220,266–271`.

**Signal/problem:** `flows` is keyed by sampler step count. Counts 1, 2, 3, 5, 6
and 7 all load `flowstep.mlmodelc` separately. A session that visits every setting
can retain eight `MLModel` objects for just three distinct graph files. Actual
weight/workspace duplication is a runtime measurement, not an eightfold-memory claim.

**Proposal:** Key the internal cache by graph identity (`flow4`, `flow8`,
`flowstep`) and placement. The sampler count remains an input to generic flow.
If residency still matters, characterize a bounded active-model policy separately.

**Benefits:** Direct reduction in redundant loads/objects without changing any
sampler computation or public setting. Small first runtime change for 0.7.

**Proof:** Loader-count test for 1→2→3→4→5→6→7→8→4; fixed-seed audio for every
count; footprint before/after switches; unload cleanup. Avoid asserting a specific
physical-memory saving based only on object count.

**Commit plan:** (1) Characterize load selection. (2) Key by graph identity.
(3) Run all-count parity and retained-memory measurements.

## 4. Tensor transport and optional diagnostics [Strong]

**Files:** `PocketTTSCoreMLEngine.swift:132–140,273–289,314–340`;
`CTEngine.swift:304–308`; `CTTensor.swift:20–21`.

**Signal/problem:** Max converts the transformer hidden output to `[Float]`, then
immediately copies it into another `MLMultiArray` for flow. Small input/position/
sampler arrays are allocated repeatedly. Plus calls
`record("waveform", try CTTensor(samples, ...))` even with `captureTrace == false`;
the argument creates a Data copy before `record` decides not to keep it.

**Proposal:** Pass compatible Core ML feature arrays directly between graphs;
reuse invocation-owned scalar/input storage only where prediction completion and
aliasing permit it. Keep stride/type validation and an explicit conversion fallback.
Guard trace construction before allocating it, or make trace construction lazy.
Do not reuse buffers retained as model outputs or caller-owned frame arrays.

**Benefits:** Less per-frame allocation, lower peak transient PCM storage and
clearer separation between production execution and diagnostics.

**Proof:** Strided/contiguous outputs, all sampler counts, exact within-backend
PCM, same event ranges, trace-on/off equivalence and cancellation reuse. At the
431-latent Plus limit, the waveform trace copy alone is 5,296,128 bytes of payload;
that is a source-derived allocation size, not a measured RSS saving.

**Commit plan:** (1) Remove eager disabled trace construction. (2) Eliminate the
hidden-feature round trip. (3) Introduce bounded scalar/input reuse with ownership
tests and stage timing. Keep each transport optimization independently revertible.

## 5. Render admission and lifetime [Strong]

**Files:** `Sources/KokoroKit/NarrationRenderer.swift:45–55,76–85,141–213,221–287`.

**Signal/problem:** The explicit lease correctly protects against actor
reentrancy, but pending continuations cannot be cancelled while queued. A
cancelled render waits behind previous work before reaching its cancellation
check. `removeFirst` shifts the queue. Selection and lifetime are spread across
several optional engines and identity fields; Max error mapping/dispatch is copied.

**Proposal:** A private cancellation-aware admission queue with stable waiter
IDs, plus a private loaded-session state representing the valid combinations.
Use one internal dispatch/error adapter for both whole-output and streaming APIs.
Keep nonthrowing `unload` as a joined retirement operation; do not make cancellation
skip cleanup. Preserve FIFO order for surviving waiters and existing public errors.
Do not make synchronous callbacks reentrant into the same leased renderer.

**Benefits:** Prompt cancellation of work that never started, fewer impossible
states and lifecycle tests that can run without model weights. A production
adapter and a controllable fake make the test Seam useful.

**Proof:** Cancel before/after enqueue, cancellation racing admission, receiver
throw, queued unload, repeated load failure, backend change and observer change.
Exactly one owner, exactly-once continuation completion, no later frames after
method completion, and all work joined before releasing resources.

**Commit plan:** (1) Add a controllable internal engine adapter. (2) Replace only
admission. (3) Consolidate state. (4) Consolidate dispatch without changing errors.

## 6. Installation and compiler-cache recovery [Strong]

**Files:** `NarrationAssets.swift:236–259,295–324`;
`PocketTTSCoreMLAssets.swift:79–124`;
`CTCompiledModelCache.swift:42–81`; `ModelAssets.swift`.

**Signal/problem:** Download/validation logic is repeated across installers.
Pocket compilation stages output and can roll back a thrown move error, but
moves the current `compiled` directory aside before adopting staging. Process
death between those moves leaves the canonical directory absent; no recovery of
`previous-*` is implemented there. CT's global blocking compiler lock serializes
unrelated cache keys and checks cancellation only after obtaining the lock.

**Proposal:** An internal verified-file helper and recoverable publication
transaction: explicit staging/previous/current states, deterministic recovery
and cleanup. Keep current directory names and receipts readable. Use per-key
compiler coordination with cancellable waiting where compatible with synchronous
entry points. This supplements the existing documented host serialization/staging
contract; it does not assume concurrent mutation was previously supported.

**Benefits:** Repair resumes reliably after disk-full, cancellation, failed
compilation or process termination. Shared validation reduces divergent behavior.

**Proof:** Inject failures before/after every write/rename, reopen, corrupt same-size
files, OS receipt mismatch, and independent-language preparation. Never publish
partial assets, delete a working installation before replacement is recoverable,
or skip SHA-256 validation based only on old receipts. Preserve error mapping.

**Commit plan:** (1) Characterize current receipt/errors. (2) Add file-operation
test adapter. (3) Add recovery. (4) Share verification helpers. (5) Narrow locking.

## 7. Max attention-cache storage [Worth exploring]

**Files:** `Integrations/PocketTTS/Sources/PocketTTSMLX/Runtime/KVCache.swift:15–20`;
`PocketTTSModel.swift` cache slicing/render loop;
`PocketTTSCoreMLEngine.swift:314–322`.

**Signal/problem:** MLX appends new keys/values with `concatenated` every step,
then evaluates growing state. This is a plausible repeated-copy bottleneck for
long continuations. Core ML transports twelve growing cache outputs, but its
implementation cost belongs to Core ML and cannot be inferred from Swift alone.

**Proposal:** First measure attention, cache update, flow and Mimi separately.
For MLX, try capacity-backed storage and active views with exact logical offsets;
preserve the public `KVCacheSimple` interface and snapshot behavior. No sliding
window, history dropping, quantization or changed attention arithmetic.
Core ML stateful-cache graphs are a separate experiment because they require
new compiled assets and a different graph contract.

**Benefits:** Potentially the largest sustained-inference improvement, if copying
is a material share of the profile. It may be small if neural compute dominates.

**Proof:** Per-frame cache tensors and offsets across prefill/continuation,
snapshot isolation, trim/reset, fixed-seed full PCM, cancellation and long-passage
footprint. Keep the old implementation available to the benchmark until proved.

**Commit plan:** (1) Profile. (2) Prototype behind an internal benchmark choice.
(3) Differential checks. (4) Adopt only with repeatable end-to-end benefit.

## 8. Shared backend services and package boundaries [Worth exploring]

**Files:** `Package.swift:35–40,63–65`; both Pocket engine entry points;
`PocketTTSResources.swift`; `PocketTTSBackend.swift`.

**Signal/problem:** Core ML depends on the entire Pocket MLX target for shared
text/config/error/budget types, safetensor loading and seeded noise. Max validation,
resource cleanup and whole-output collection have backend-specific copies. A
nominally CPU-only execution path still carries MLX package/runtime dependencies.

**Proposal:** Extract narrow internal text/resource/validation implementations;
retain public types at their current module paths using compatible facades.
Share policy without forcing Core ML and MLX tensor execution into one abstraction.
An MLX-free iOS runtime is a later conditional deliverable: it must reproduce the
existing RNG stream and safetensor semantics, not just the same noise distribution.

**Benefits:** Less backend drift and lighter testing/build dependencies. This is
primarily maintainability/package-size work until startup measurements prove more.

**Proof:** Unchanged external client builds and public type identities, settings,
error precedence, callback order, RNG state/draw count and platform-specific APIs.
The MLX target exposes hundreds of public runtime symbols; those are contracts
even if originally intended as implementation details. Do not internalize them.

**Commit plan:** (1) Share pure helpers within existing boundaries. (2) Add a
private common target only where useful. (3) Evaluate dependency reduction
separately from the main 0.7 compatibility work.

## 9. Basic pronunciation and DSP resources [Worth exploring]

**Files:** `PronunciationEnglish/Lexicon.swift:150–174`;
`KokoroPronunciation/Pronunciation.swift:64–70,121–128`;
`KokoroKit/NarrationRenderer.swift:365–386`; `KokoroAudio/VoiceEnhancer.swift`.

**Signal/problem:** Each English frontend parses large dictionaries, while
several independently owned planning/rendering frontends can coexist. Basic's
facade constructs DFT plans and working buffers for every enhanced unit.

**Proposal:** Explore an immutable, generated dictionary index (there is already
a mapped Japanese lexicon pattern) and reusable actor-owned DSP setup. Preserve
dictionary precedence and validation. Reset all DSP history at the exact existing
unit boundaries; retaining history across units would change current facade audio.
Keep public standalone `VoiceEnhancer` streaming behavior intact.

**Benefits:** Lower cold parsing cost, repeated setup cost and duplicate immutable
storage. Avoid replacing bounded ownership with a permanent global dictionary cache.

**Proof:** Full pronunciation corpus/diagnostics, US/UK alternation, unknown words,
Unicode and malformed-resource behavior; sample-identical DSP at every block
boundary and tail; cold/warm memory measurements.

**Commit plan:** (1) Measure dictionary/setup cost. (2) Separate immutable data.
(3) Reuse reset DSP setup. (4) Adopt mapped data only if the complete corpus agrees.

## 10. Qwen concurrency and callback contract [Strong audit finding]

**Files:** `QwenANEEngine.swift:140–144,223,254–262,318–341`;
`CoreMLVocoder.swift:90–105`.

**Signal/problem:** Qwen is public despite being disabled in the main model
selection. Its `@unchecked Sendable` class has a publicly mutable `options` value
whose documentation requires writes between renders. Its render docs say nothing
is delivered for a cancelled render, yet streaming callbacks occur during
generation and queued vocoder work is drained on cancellation. Already-emitted
audio cannot be retracted. Swift 6.4.2 also warns about the queue closure's
Sendable conversion.

**Proposal:** Characterize late-cancellation behavior and clarify the actual
callback contract; add an operation-generation gate for future delivery if needed.
Snapshot configuration under a defined lock strategy while retaining the public
synchronous API. Do not turn it into an actor or buffer all streaming audio merely
to make the inaccurate sentence true. That would change source/timing contracts.

**Benefits:** Better direct-client reliability and a smaller unchecked concurrency
surface. This is maintenance of an existing product, not promotion of Qwen.

**Proof:** Overlapped/inline cancellation after first callback, queue drain,
receiver reentry constraints, options snapshot, repeated failure/recovery and race
checking with a deterministic fake talker/vocoder before expensive model tests.

**Commit plan:** (1) Add contract tests. (2) Correct docs around observed partial
streams. (3) Narrow unsafe crossings and configuration ownership independently.

## Measurement and release gates

The benchmark Module already measures generation/first-frame timing, but
`PocketBackendBenchmark.run` calls `previewChunks` before its first render.
The reported `coldGeneration` row therefore excludes that acoustic loading;
`loadSeconds` is separate. Its `realTimeFactor` field is audio seconds divided by
wall seconds (throughput multiplier), and footprint is sampled during callbacks,
not continuously or across Core ML services. Preserve existing public/report
fields; add clearly named measurements rather than silently redefining them.

For 0.7 capture: cold install/compile, verified cold load, first accepted frame,
warm render, p50/p95 frame service time, wall and CPU time, allocations/copy bytes,
footprint and system-service memory where observable, thermals, cancellation
latency and playback underruns. Measure each actual shipping route on iPhone,
iPad, Mac and Catalyst. Include short text, long punctuation-free text, dialogue,
all seven Max languages, Plus/Basic regressions, steps 1–8, style/language switches,
seeks, slow/failing receivers, lock/background, interruptions and repeated cycles.

Use paired baseline/candidate runs with pinned assets, identical input and seeds,
the same compiler/OS, randomized or ABBA order, separated cold/warm runs and
recorded load/thermal conditions. Within a backend, start with exact PCM and
event equality. Cross-backend numerical tolerance is not permission for a new
within-backend regression. Any changed audio needs a separate reviewed behavior
change, cache decision and listening acceptance.

Suggested success targets, **not measured results**: remove repeated same-graph
loads; eliminate the measured pathological planning delay; improve a nominated
cold/warm bottleneck materially (for example 20%+) without shifting the cost to
another user path or growing memory unboundedly. No 0.7 claim should say faster
solely because fewer tests ran, validation was skipped, quality was lowered, or
benchmark timing moved from one field to another.

Release gates: unchanged client compilation and persisted fixtures; Debug/Release
and minimum-toolchain builds; complete numerical/callback parity; failure-injection
and lifecycle tests; actual device listening and sustained playback; honest
before/after receipts. Existing 0.6.2 listening acceptance is one Spanish seed-42
case, and its device/endurance gaps remain open.

## Top recommendation and sequence

**Start with the compatibility/measurement harness, then the planning hotspot
and small model-residency/trace changes.** They have concrete waste to remove and
can be reviewed in small commits. Follow with cancellation and recovery. Treat
attention-cache work as the larger performance experiment, gated by profiling.
Broader dependency separation follows only when it demonstrably helps.

Considered, not recommended for this release: retraining/quantizing/changing
sampler counts; ANE/GPU routing changes; dropping attention history; changing
chunking/punctuation; new public universal-engine interfaces; removing legacy
products or runtime types; speculative decoder/model caching that reverses
intentional memory bounds; playback ownership inside the SDK; merging the old
Companion branch; automatic model redownload or prepared-cache purge for a
behavior-preserving refactor.

## Review evidence

Fresh checks: model-independent `swift test` and `swift test -c release` both
returned exit 0 on Apple Swift 6.4.2. Model-dependent tests were skipped. Public
symbol extraction and target inventory succeeded. The focused text-planning
probe and receipt are in [`architecture-07`](architecture-07/README.md).

No runtime source, dependency, model asset, version, tag or remote branch was
changed. These documents and review artifacts are local proposals, not a shipped
0.7 implementation. No fresh synthesis, listening, physical-device or energy
qualification was performed in this review.
