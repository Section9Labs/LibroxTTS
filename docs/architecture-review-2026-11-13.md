# LibroxTTS 1.2 proposal: faster exact synthesis

Status: proposal, not implementation or a measured 1.2 speedup. Deferred after
the user reserved 1.1 for compressed downloads; 1.1 leaves the inference baseline unchanged. Reviewed against
published 1.0.0, `a6932878316bfc979f6c8fcc3d4f2fe84330661f`. No runtime changes.

## Baseline and limits

Recomputed from the candidate warm rows in
`architecture-10-speed/profile-stability.json`: median stage shares are latent
transformer 55.44%, Mimi 24.76%, flow 16.20%, text 1.88%. Stage timers include their
host bridge. These are one Core ML CPU passage on the M3 Ultra, not MLX or iPhone
profiles. The shorter ABBA receipt gives 57.22%, 22.98%, 16.23%, 1.76% respectively.
The long-run candidate median is 4.7017 seconds for 22.16 seconds of audio.
These historical runs measured the release's runtime code; fresh comparisons must
build the exact release tag with the same compiler as the candidate.

At the longer-run shares, doubling only transformer speed gives about 1.38x total
throughput; doubling transformer, Mimi and flow together gives about 1.93x.
These are Amdahl estimates, not forecasts. The existing loudness pass costs about
0.57 ms for this amount of audio and is not a useful optimization target.

1.0's small warm speed differences were near parity. Do not present its cold-load
and planning gains as synthesis gains, or carry its original 2x ambition forward
as an achieved result.

## Frozen behavior

- Public declarations and direct engine/model/cache semantics, including mutable
  references, errors, source replacement validation and lifecycle behavior.
- Exact raw Float32 PCM per backend, RNG consumption, weights, precision, sampler
  steps, temperature, EOS, continuation, chunking, sample counts and text ranges.
- Exact facade PCM, including Max's 525 frozen profiles, gain rounding and peak
  guard. Keep `pocket-level-v1-41466443134c33e7`, delivery/render identities and
  existing 1.0 prepared-audio compatibility. Basic and Plus remain unchanged.
- Synchronous throwing callbacks, backpressure, ordering, cancellation, FIFO
  admission, background resource budget and asset verification/recovery.
- Bounded residency, autorelease scopes and final 32-Float32 latent detachment.
  No model replication or larger caches accepted merely to buy speed.

If an optimization changes audio, reject it for this release; do not conceal the
change under the old identity or silently loosen the numerical tolerance.

## 1. Execution cost accounting and exact replay [Strong]

Files: `Sources/PocketBackendBenchmark/Benchmark.swift`,
`Scripts/benchmark-10-profile.py`, `PocketCoreMLExecutionPlan.swift`,
`PocketTTSModel.swift`, existing API/audio/contract test suites.

Signal: existing measurements cannot separate kernel compute, cache movement,
graph construction, synchronization and deliberate CPU-budget waits. MLX lacks
the same stage decomposition used for Core ML.

Proposal: a private instrumentation seam with production execution and benchmark
recording adapters. Record cache lengths/bytes, stage execution, evaluations,
first callback, inter-frame gaps, CPU seconds/audio second, footprint and thermal
state. Retain uninstrumented runs to measure probe overhead. Capture boundary
tensors in a separate bounded diagnostic run for exact replay and localization.

Benefits: select work by measured cost and diagnose the first divergent tensor;
avoid treating a faster component as a faster engine.

Proof: recorder on/off leaves PCM/events unchanged; replay matches release output;
no instrumentation in normal execution. Compare within backend, never require
Core ML and MLX to match each other unless already guaranteed.

Plan: baseline and frozen invariants; instrumentation; release/candidate runner
with per-process statistics and machine-readable goals. No new public API needed.

## 2. Engine-owned attention storage and decode specialization [Worth exploring]

Files: `Runtime/KVCache.swift`, `Runtime/PocketTTSTransformer.swift`,
`PocketCoreMLExecutionPlan.swift`, `Scripts/PocketTTS/CoreML/convert.py`.

Signal: MLX concatenates growing K/V arrays at every update; Core ML graphs accept
and return 12 growing K/V arrays and concatenate inside the graph. Decode uses
one token while prefill uses a variable sequence. Logical cache storage is 48 KiB
per position across the six layers: allocating all 4096 positions would consume
192 MiB for K/V alone, incompatible with the measured small-device footprint.
Logical size is not proof of a physical copy on every invocation; profile first.

Proposal: keep the public mutable cache reference implementation. Prototype a
private engine-owned append path with bounded growth and used-prefix attention;
specialize decode separately from prefill without changing attention reduction
order, masks or position arithmetic. Select per backend only with repeatable gains.

Benefits: less allocation and cache movement at the largest measured stage;
cache ownership and invalidation live in one module rather than public callers.

Proof: exact cache/hidden/EOS bits, snapshot/mutation tests, continuation and
position-boundary cases, then full PCM and repeated-render memory tests.

Plan: measure traffic; implement private MLX alternative; run CPU/GPU ablations;
admit only winning cases. The 1.0 capacity patch is evidence, not a ready solution:
CPU regressed and GPU gains were noisy. A changed design must outperform it.

Core ML stateful/decode-specific graphs are a separate research branch. Apple's
state mechanism can avoid explicit state I/O, but requires a different model
representation. Current pack hashes and receipts are contractual. Do not overwrite
packs, silently change required downloads or admit a replacement under an old
receipt. Shipping needs an independently reviewed compatible artifact strategy,
exact PCM and no memory regression; otherwise keep the existing Core ML graphs.
This is the largest structural opportunity, not an unconditional drop-in promise.

## 3. Fixed-shape MLX flow and codec execution [Worth exploring]

Files: `Runtime/PocketTTSFlowLM.swift`, `Runtime/PocketTTSMLP.swift`,
`Runtime/PocketTTSMimiAdapter.swift`, `FlowCompilation10Tests.swift`.

Signal: flow builds repeated subgraphs; codec runs every 80 ms frame. Together
they account for about 41% in the Core ML reference profile; measure MLX's own
share before estimating its benefit. Core ML already has unrolled four/eight-step
flow graphs, so unrolling those is not new work.

Proposal: private bounded compiled functions for the existing fixed-shape flow
operations, then codec subgraphs whose state can be explicit. Preserve original
expressions and RNG outside the compiled region. Retain eager execution for
unsupported shapes/devices and exposed mutable model instances.

Benefits: fewer graph allocations and dispatches without changing the sampler.

Proof: component bit equality is only the first gate; require full seeded raw and
facade PCM, cancellation, cold start and long-run residency. Compile variant count
must be bounded. Fallback selection must happen before emitting affected audio.

Plan: extend the 1.0 probe to full four-step execution; qualify complete engine;
measure startup amortization; try codec separately; integrate only qualified paths.
The 1.0 probe's 16 matching outputs did not qualify an engine. First CPU compile
took 156.3 s and GPU 2.10 s; hiding that in startup or in a background task is not
a free optimization. A default path must solve compilation cost without increasing
memory, latency or violating execution-context restrictions. No global compile
switch or dependency update bundled into this experiment.

## 4. Frame synchronization and bounded stage overlap [Worth exploring]

Files: `Runtime/PocketTTSModel.swift`, `PocketTTSCoreMLEngine.swift`,
`PocketCoreMLExecutionPlan.swift`, `Runtime/CPUWorkBudget.swift`.

Signal: MLX reads EOS on the host before evaluating PCM; Core ML serially runs
transformer, flow and Mimi. Once a latent exists, its codec work and the next
transformer computation have a potential independence boundary.

Proposal: first eliminate proven redundant evaluations/materializations within
the current frame. Separately prototype at most one frame of internal overlap,
with isolated ownership of transformer and codec state and deterministic RNG.

Benefits: reduce dispatch/synchronization stalls; overlap can reduce elapsed time
without changing equations. Fully hiding the current ~25% codec share would cap
the ideal benefit near 1.33x before contention; that is an upper bound, not a goal.

Proof: callback sequence, throwing callback cleanup, cancellation checkpoints,
EOS behavior, resource observations and backpressure all remain compatible.
Never run unbounded work ahead of a stalled callback. If even bounded speculation
changes observable state or error ordering, reject that path. No removed CPU
budget waits, parallel renderer calls or additional resident model instances.

Plan: dependency/synchronization trace; within-frame changes; isolated overlap
prototype; foreground/background/device qualification. Retain serial path where
CPU contention, energy, memory or contracts make overlap unsuitable.

## Measurement goals and release decisions

Goals are hypotheses until measured against freshly built 1.0.0:

| Measure | 1.2 objective |
|---|---|
| Warm end-to-end synthesis | 1.5x throughput target; 2x stretch, reported separately per shipping backend/device |
| Fixed 22.16 s Mac Core ML passage | Illustrative 4.7017 s -> <=3.1345 s target; <=2.3509 s stretch; rebaseline first |
| First audio | No regression including load/compile; seek at least 20% reduction where profiling supports it |
| Streaming gaps | No p95/p99 regression or new long stalls; report host callback cost separately |
| Memory | No repeatable peak/steady increase vs matched 1.0; no upward soak trend |
| CPU/energy | No hidden CPU-budget bypass; measure CPU/audio second and sustained device thermal behavior |
| Output/contracts | Zero differing PCM samples and event changes in the expanded qualification matrix |

Use paired ABBA blocks, at least three blocks with ten warmed renders per process
for finalists; retain pooled and process-level results, uncertainty and outliers.
Stratify by language, voice/style, passage length, continuation and execution
context. Expand the 78-case matrix with long cache growth, resets, arbitrary
supported sampler settings, zero temperature, slow/throwing receivers, cancellation
and source replacement. Exercise all loudness profiles with exact transform
fixtures, and real facade renders across supported backends.

Test M3 Ultra MLX CPU/GPU and Core ML separately, M4 iPad Core ML, and an actual
iPhone. Run matched 30-minute/count memory qualification and background playback
integration before claiming sustained device gains. The prior iPad's ~83 MiB is a
reference for that exact workload, not a universal process limit. Instrumented
device probes do not establish app playback, lock-screen or perceptual acceptance.

## Recommended order

Freeze 1.0 and improve cost accounting first. Then attention storage/decode,
fixed-shape flow, codec, synchronization and bounded overlap, one ablation at a
time. Run the Core ML representation feasibility study early, but keep it outside
the shipping path until its compatibility problem is resolved. Combine winners
only after individual qualification; benefits cannot simply be added together.

Top recommendation: approve the exact-execution speed program in this order,
with 1.5x as a target and 2x as a stretch, and allow experiments to fail. Do not
promise a large gain under unchanged contracts before the measured bottleneck
can actually be removed.

Considered, not recommended: fewer sampler steps, quantization/FP16, changed
voices/chunking/EOS, shorter continuation, loudness recalibration, removing memory
scopes, universal maximum-size caches, unbounded chapter parallelism, generic
response caching as a claim of faster fresh synthesis, or automatic ANE/GPU
placement changes without per-backend exactness qualification.

## External mechanism references

- [Apple: stateful Core ML](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)
  describes state read/write without explicit output/input copying. It does not
  establish parity or gains for our models.
- [MLX: compilation](https://github.com/ml-explore/mlx/blob/main/docs/src/usage/compile.rst)
  describes graph simplification/fusion and first-call cost; it promises agreement
  up to numerical precision, which is weaker than this release's bit-exact gate.
  Mechanism research does not authorize upgrading our pinned MLX runtime.
