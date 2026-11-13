# 1.0 execution redesign — implementation and measurement record

**Historical first candidate:** synthesis regressions below are superseded by the
[speed repair and default Max level report](implementation-10-speed.md). Keep this
record to compare the original targets and rejected experiments.

Baseline: v0.9.0, `07fcf437004027f58ad8bb16de7877d0ee74a9a8`.
Isolated worktree: `librox-tts-10-review`. This is not a published release.
The [design](1.0-execution-redesign.md) and [targets](architecture-10/targets.json)
define goals, not promised improvements. Production implementation is committed at
`f1d31fa`; later commits contain qualification tools, evidence and this report.

The candidate delivers large preparation gains and bounds repeated-render memory.
It does **not** meet the 2x steady-synthesis or 50% full fresh-start goals. Mac and
iPad warmed synthesis regressed on the nominated workload. The exact-audio gate
was retained; no precision, model-pack, sampling or API change was used to improve
scores. This is a measured implementation candidate, not a published 1.0 release.

## Measured goals against 0.9

Mac: M3 Ultra, macOS 27.0.1, Release, Xcode 27.2 / Swift 6.4.2. ABBA process order,
identical requests/assets, two process trials per revision; descriptive medians.
The 270-character Caro/Calm passage produces 22.16 seconds of audio with four
sampler steps and continuation. Results apply to the named workloads only.

| Goal / workload | 0.9 | Candidate | Result |
|---|---:|---:|---|
| Cold US English dictionary; >=5x faster | 751.7 ms | 37.7 ms | 19.9x; met |
| Cold GB English dictionary; >=5x faster | 630.8 ms | 24.4 ms | 25.8x; met |
| Contextual long planning; >=10x faster | See four cases below | See below | 27.0–89.3x; met |
| Fixed Mac Core ML warm passage; >=2x throughput | 4.156 s | 4.377 s | 5.3% longer; missed |
| Fixed Mac sampled peak footprint; >=30% lower | 177.35 MiB | 116.57 MiB | 34.3% lower; met |
| Fresh iPad setup + first audio; >=50% lower | 3.890 s | 3.845 s | 1.2% lower; missed |
| Supplemental Mac prepared-install first audio | 1.075 s | 0.435 s | 59.6% lower |
| Supplemental iPad warm passage | 3.713 s | 4.472 s | 20.5% longer |

The original cold goal includes **all preparation**. The much larger Mac startup
gain is for already installed/prepared packs and must not substitute for that
goal. Fresh iPad setup copies original source assets into a new directory and
runs SDK preparation; OS/compiler global caches are not purged. The iPad's warm
ABBA rows reported nominal thermal state. These regressions remain visible in
[the machine-readable scorecard](architecture-10/scorecard.json).

| Contextual planning case | 0.9 | Candidate | Speedup |
|---|---:|---:|---:|
| Plus English | 975.4 ms | 36.1 ms | 27.0x |
| Plus Spanish | 7.528 s | 184.4 ms | 40.8x |
| Max English | 1.363 s | 36.2 ms | 37.6x |
| Max Spanish | 20.099 s | 225.1 ms | 89.3x |

Short controls used 101 repetitions and were effectively unchanged (~1.00x).
Plain long controls used 21 repetitions: Plus 0.979x and Max 1.011x. Warm English
pronunciation was 12.95 ms -> 13.51 ms, **4.3% slower** (~0.56 ms). Indexed resources
add **32,000,763 bytes (30.5 MiB)** before compression. These costs accompany the
cold-load gains; no package-size reduction is claimed.

Mac MLX whole-engine timing remains close on CPU and highly variable on GPU. The
full case p50/p95 frame-service, total wall, first-frame and sampled-footprint
receipts are in [backend-abba.json](architecture-10/backend-abba.json). The final
Core ML-only refresh is [backend-coreml-final.json](architecture-10/backend-coreml-final.json).
The fixed-passage profile is [profile-abba.json](architecture-10/profile-abba.json).
Do not multiply the preparation, startup and component speedups.

## Preparation

`PreparedNarrationText` retains original UTF-16 boundaries and prepares stable
clauses independently of their changing final prefix. Commas followed by a space
and strong punctuation delimit admitted dependencies. Contextual tails still use
the original normalizer; cross-boundary custom readings, newlines, other languages
and unproven inputs fall back. The planner preserves its first-failing-prefix
algorithm. Final synthesis text still comes from the original complete normalizer.
This is not full-sentence normalization followed by slicing.

English dictionaries have generated indexed resources. Their full bytes and the
original JSON bytes are checked before use. Missing/changed/corrupt derived data
falls back to the old parser and validation. Weak ownership, source error order,
original precedence, variant-null behavior and Swift canonical key equivalence
are retained. A single exhaustive test compares all compiled entries with the
original loaders and phoneme validation. The original JSON and licenses stay in
the package. Added indexed resources cost about 30.5 MiB before distribution
compression; no application binary-size reduction is claimed.

All 826,960 dictionary entries are compared exhaustively. Prepared-text tests
compare every eligible prefix and restart with the original normalizer, plus
50 seeded mixed-Unicode full-plan cases across five languages. These preparation
gains do not represent inference gains.

## Execution ownership and tensors

`PocketCoreMLExecutionPlan` owns resident graphs, immutable text-asset leases and
bounded scalar/noise/sampler workspaces. Invocation state remains separate:
transformer/codec caches, RNG, continuation, counters and callbacks. Flow latents
stay in Core ML storage through their next transformer and codec uses. Shape views
retain the source array; non-contiguous tensors retain the legacy copy fallback.
Only continuation assembly and caller-owned PCM materialize host arrays.

Native voice preparation copies Float32 bit patterns from published safetensors.
Only catalog-pinned bytes are admitted; a changed original voice file falls back
to the legacy MLX reader, including its validation of unused records and errors.
This matters because original voice files can be observed again after an engine
has loaded. No new acoustic representation, RNG, precision or sampler expression
is introduced. All 48 installed English/Spanish voice archives are compared with
the old MLX transposition path.

Text-asset leases share immutable configuration/tokenizer state, re-reading and
hashing current source bytes on acquisition. A bounded weak registry releases its
last owner's data. Mutable public models, weights exposed as MLXArray references,
RNG and prediction state are not pooled. Public direct-model construction retains
its original initialization and random draws.

Full asset validation uses at most four read workers. Every byte is still checked
on each load. Results are consumed in manifest order, each caller's size policy is
unchanged, and cancellation/failure joins all workers before returning.

## Sustained memory and reliability

The physical iPad loop found a problem that short fixtures missed: repeated
synchronous styled renders retained temporary objects until the caller's task
finished. The unchanged 0.9 build reproduced it. The candidate now owns a Core ML
render autorelease scope, and delivery-state validation drains each file-read
block. The two fixes are separate: adding only the render scope still left the
voice-validation reads accumulating. Rejected intermediate receipts are retained
in `architecture-10/device-memory-investigation.json`.

An isolated 24-render Mac regression verifies stable repeated PCM and reports
5.84 MiB maximum growth after warm-up, below its 64 MiB regression ceiling. The physical harness independently records every repeated hash,
chunk event, sampled footprint and thermal state. A completion marker is required;
interrupted probes are not counted as passes. The foreground workload deliberately
runs faster than playback and does not establish background behavior or battery
energy use.

The final guarded iPad build completed its 1,800-second foreground wall-clock
soak: **393 renders**, 1,799.09 seconds spent inside rendering, and a **89.55 MiB**
maximum sampled footprint. All repeated PCM hashes and chunk events matched the
unchanged 0.9 passage. The separate completed 0.9 baseline produced 53 renders in
181.43 render seconds and reached **1,480.71 MiB**. At the same first 53 renders,
the candidate peaked at 88.53 MiB (**94.0% lower**). The final half of the candidate
soak sampled 78.94–89.55 MiB. This is a repeated fixed-passage test, not continuous
book playback. Thermal state reached serious in both runs; unequal duration and
thermal histories are not used to claim throughput gains. The separate warm ABBA
comparison above supplies the speed result.

The final twelve-case physical matrix also matches 0.9 byte for byte (1,006,080
samples), covering steps 1–8, graph revisits, original/styled voices and continuation.
[Final device evidence](architecture-10/device-final.json) and
[the memory comparison](architecture-10/device-qualification.json) retain all rows,
completion status, environment and binary identities. Both task-owned qualification
apps were removed after collecting the completed evidence; the host app and its
models/data were not touched.

Process-exit helpers qualify four compiled-generation rename boundaries and three
downloaded-file publication boundaries. Reopening/retry preserves complete old or
new bytes. Existing admission, cancellation, retirement, backpressure, source-range,
cache-identity, manifest and mutable-reference tests remain in place.

## Experiments and limits

The private MLX capacity experiment preserves public constructors and passed exact
PCM. It is evaluated separately from private rotary-term reuse; the archived patch
is not part of the production runtime. CPU results favored removal; GPU medians
favored capacity but had substantial run-to-run variation. The tradeoff did not
justify production admission. Private rotary reuse is retained: isolated component
time fell 24.3% on CPU and 22.0% on GPU, with exact bits; whole-engine speedups of
that size are not established. [Runtime decisions](architecture-10/runtime-decisions.md)
record the ablation, attribution and rejected experiments.

Pinned-runtime flow compilation preserved all 32 values in each of 16 CPU/GPU
probes. It remains out of production: this is not full-engine parity, and first
CPU execution spent 156.3 seconds compiling in the recorded run. Stateful Core ML
would require a different model representation and receipts; it is not admitted
as a transparent replacement of the pinned packs. Native exact RNG replacement is
also deferred: the measured warm-stage attribution does not justify duplicating
MLX's random stream and floating-point implementation for the small residual.
The Core ML product still links MLX; no lean-binary or model-size claim is made.

## Qualification boundaries

Mac comparisons use the same M3 Ultra, macOS 27.0.1, Xcode 27.2 / Swift 6.4.2,
Release flags, pinned assets, seeds and request sequences. Public declaration
inventory remains 2,802 entries, with zero additions, removals or changes. Debug
and Release suites, full unsigned iOS and Catalyst example builds, and seven
real-model MLX resource/cancellation/retirement tests pass. Each full configuration
reports 139 XCTest cases (28 opt-in skips) and 559 Swift Testing cases; focused
actual-model runs supplement those suites. CI gains the public
inventory and Catalyst checks; remote CI and the Swift 6.3 toolchain were not run
in this task.

The actual model matrix covers English/Spanish Max on Core ML CPU, MLX CPU and MLX
GPU: sampler counts 1–8, shared/specialized graph revisits, voice/style switches,
continuation, receiver cancellation, recovery and unload. Plus uses frozen initial
noise for English/Spanish traced and ordinary Core ML CPU output. Basic's eight
preferred-language samples (English, Spanish, French, Hindi, Italian, Japanese,
Chinese and Portuguese) match PCM and WAV format. In total, **92 Mac recordings,
5,901,744 samples** match 0.9 exactly. Max event delivery also matches. Exactness is
within each backend/OS; it is not a cross-backend or cross-device claim.

The iPad is an M4 iPad Pro running iOS 27.0.1. Qualification uses two isolated apps,
not the host Librox container. iPhone, real Qwen model audio, background/lock
playback, energy and broader human listening are not certified here. The exhaustive
English dictionary and complete-plan oracles protect their changed preparation
paths. Builds and hashes do not establish all possible inputs or perceptual
acceptance.

## Remaining goals and release decisions

The next measurable thresholds are **<=2.078 seconds** for the fixed Mac passage
(2x the frozen 0.9 throughput) and **<=1.945 seconds** for fresh iPad setup plus
first audio (50% of the paired 0.9 result). Candidate observations are 4.377 and
3.845 seconds respectively. Also track recovery of the iPad warm-passage control
to **<=3.713 seconds** while preserving its bounded-memory behavior. These are
hardware/workload-specific engineering goals, not forecasts.

- Keep the original 2x sustained-synthesis and 50% complete cold-start targets.
  This implementation misses both; relaxing exact PCM is not a remedy. Any next
  inference experiment needs a separate exact qualification of the numerical
  runtime/model representation and the pinned asset contract.
- Evaluate the measured warm-speed and resource-size costs before promoting this
  candidate. Memory stability is a substantive improvement, but it does not erase
  the 5.3% Mac and 20.5% iPad warm-passage regressions.
- Complete physical iPhone, host-app background/lock playback and energy checks,
  supported-toolchain CI, real Qwen audio if included in the release support claim,
  and human listening before claiming those dimensions are qualified.

[Reproduction instructions and evidence index](architecture-10/README.md) include
baseline harness construction, commands, binary hashes, exact-audio fixtures,
physical-app isolation and score generation. The original dirty Companion checkout
and host app data remain untouched. No package version, tag or remote release was
published by this task.
