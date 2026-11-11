# LibroxTTS 0.8 implementation

Base: local 0.7 candidate `dee2b49`; no release or integration is implied.
Branch: `codex/0.8-reliability-performance`, separate from both 0.7 and Companion.

Authorized order: controlled lifecycle tests and repeatable baselines; cancellable
admission and session ownership; interrupted preparation recovery; planning;
profile-driven inference experiments. Public contracts, model assets, sampling,
audio identities, source boundaries and exact within-backend PCM remain gates.

## Baseline

The original renderer lease has been extracted into an internal synchronized
admission object without changing its queue behavior. Tests control the lease
without model assets: FIFO exclusion, cancelled nonthrowing unload joining its
predecessor, and release after a render error. These pass before introducing
cancellable admission. Log: `/tmp/libroxtts-08-admission-baseline.log`.

`Scripts/benchmark-08-plus.py` builds 0.6.2 and 0.7 CT modules with identical
compiler flags and unchanged catalog objects, then runs two ABBA blocks. Each
process performs two warmups and four timed renders per language with saved
noise, checking exact PCM on every call. All 96 renders match. Median process
timings show English 0.7 about 4.4% slower and Spanish about 2.9% faster. The
English delta is predominantly inside the unchanged vector-estimator graph;
non-graph overhead is approximately 0.9 ms in both revisions. This does not
reproduce the earlier 17% English slowdown or demonstrate a general speedup.
Shared-host/device/thermal uncertainty remains. Raw per-graph observations:
[`plus-062-vs-07.json`](architecture-08/plus-062-vs-07.json).

## Admission

Throwing load/render requests now cancel while queued, without waiting for an
active render. Nonthrowing settings/unload and existing uninstall semantics still
join the queue. Stable waiter IDs and doubly linked entries permit constant-time
removal without retained cancellation tombstones. Admission/cancellation races
return an acquired lease before throwing; each continuation is completed once.
Seven focused tests pass, including 200 cancellation-versus-release races and an
actual queued `NarrationRenderer.render` cancelled before its predecessor exits.
Log: `/tmp/libroxtts-08-admission.log`.

The renderer now publishes a single `NarrationSession` pairing identity with one
engine. An internal Max backend seam has production Core ML/MLX adapters and a
controllable test actor. Shared dispatch preserves sampling validation and error
mapping; no synthesis code or frame delivery is moved onto a new queue. Four
additional lifecycle tests cover held frames versus retirement, receiver errors,
memory/thermal mapping, cancellation during configuration, failed replacement,
identity reuse and persistent observer/CPU settings. Combined lifecycle/admission
tests pass (11 tests). Log: `/tmp/libroxtts-08-lifecycle.log`.

## Interrupted preparation

Core ML preparation now validates and recovers the existing `compiled`,
`previous-UUID` and completed `compile-UUID` generations before recompiling.
The canonical verified generation wins; otherwise a verified previous generation
is preferred to staging. Receipt/source/OS checks and full compiled-file hashes
remain required. Cancellation is never interpreted as corrupt data. Publication
and rollback remain recoverable across rename failures, and cleanup never removes
unrecognized directories or turns a committed installation into an error.

Seven tests pass: same-size corruption, stale OS, partial staging, cancellation,
faults before/after both renames, failed rollback/cleanup, and real English asset
recovery. The real test moved `compiled` to a legacy `previous-UUID`, reopened
preparation, validated the files and verified the original receipt inode: no
recompilation. Assets are a task-owned APFS clone at `/private/tmp/libroxtts-08-assets`.
Log: `/tmp/libroxtts-08-recovery-real.log`. Tests simulate interrupted filesystem
states/failures; no power-loss durability or device-kill qualification is claimed.

Plus compiler coordination now uses per-generation exclusive locks and a shared
legacy lock. Different keys may compile concurrently; the shared legacy lock
still excludes older SDK processes using the original global exclusive lock.
Nonblocking lock attempts check task cancellation while waiting. Tests observe
actual lock contention before cancelling, verify same-key exclusion and legacy
compatibility, and prove two different keys can own locks simultaneously. All
three tests pass in the same recovery log. Existing compiler receipt/cache keys
and atomic publication remain unchanged.

## Planning

`PlainNarrationBudget` computes NFC/NFKD scalar prefix sums once per oversized
plain-text plan. It indexes the original UTF-16 grapheme boundaries and preserves
the sequential first-failing-prefix algorithm, exact source ranges and final
full normalization. It is never used for a nonempty custom lexicon, unsupported
scripts/languages, numeric or Roman contexts, ellipses/abbreviation rewrites,
or whitespace requiring rewriting. English, Spanish, French and Portuguese
plain prose including ordinary sentence punctuation can qualify. Short units
that already fit do not construct the additional index.

The frozen 0.7 planner is a test oracle. Differential checks cover complete plans
across four languages and two models, all supported grapheme prefixes/interior
slices of an accented sample, and Latin compatibility/combining forms at the
exact Plus budget. The separate frozen 0.6.2 contracts continue to cover settings,
normalization, identities, source ranges, chunk fields and error boundaries.
The identical Release probe runs in ABBA order against the 0.7 and 0.8 objects,
with three observations per case per process. All eight fingerprints match.
At 16,000 scalars, Plus falls from 5.003 s to 0.0618 s (81x), and Max from
8.156 s to 0.0651 s (125x). At 8,192 scalars the gains are 75.6x and 118.6x.
These are synthetic repeated-clause source-planning workloads, not audio
generation or a representative book corpus. Raw process observations:
[`planning-abba.json`](architecture-08/planning-abba.json).

The mixed workload reported a small absolute regression for already-fitting Max
units (about 1–2 ms). The separate warmed control (`PlanningShort.swift`, ten
warmups plus fifty observations per case, ABBA) does not reproduce it: Max
512/2,048-scalar medians are 1.077/2.943 ms in 0.7 and 1.082/2.954 ms in 0.8.
Plus 128/256-scalar medians are 0.636/0.845 ms and 0.636/0.875 ms. All fingerprints
match. The long benchmark's preceding workload differs dramatically in duration
between revisions, so short timings need this independent control. No universal
planning speedup is claimed. Raw control:
[`planning-short-abba.json`](architecture-08/planning-short-abba.json).

## Audio contracts

The unchanged 0.6.2 recordings match all 32 current Plus/Core ML Max cases:
2,047,104 Float32 samples and every completed chunk event. Cases cover English
and Spanish, sampler counts 1–8, graph revisits, original/calm voices, multi-chunk
continuation, cancellation/reload and Plus trace/no-trace output with saved noise.
[`audio-comparison.json`](architecture-08/audio-comparison.json) retains per-case
hashes and timings. Its one-off timing ratios are not attributed to 0.8: the
controlled Plus ABBA comparison above shows why separate runtime observations
on this shared host are insufficient to establish an inference speedup.

`NarrationBackendParityTests` additionally compares the real renderer's complete
and streamed Core ML output with the old recordings and checks recovery after
receiver cancellation. The Mac MLX test compares direct-engine and renderer
output on GPU/CPU with matching residency: existing MLX model initialization
consumes RNG, so a cold render must not be compared to a reseeded warm render.
No RNG initialization or inference code was changed to make these tests agree.

## Inference experiment — not adopted

`Release08InferenceExperiment.swift` is opt-in test code, never a runtime path.
It profiles one multi-chunk English passage on the unchanged MLX model, with one
cold generation and two warm repetitions on each backend. All repeated seeded
PCM matches within each backend (224,640 samples per render). Warm wall times
were 35.66/38.70 s on GPU and 16.27/16.31 s on CPU on this shared Mac. The
checkpoint interval before codec completion dominates, but it also evaluates
deferred flow sampling: it is not a pure codec attribution. MLX tracked peaks
were about 490 MiB GPU / 436 MiB CPU, not total process/system memory.

A capacity-cache prototype runs ABBA against concatenation for six flow layers,
128 prompt frames plus 128/512/1,500 appends, evaluating all six layers once per
frame. Exact output values and retained snapshot isolation pass. CPU append-only
medians improve 9.4x/17.1x/12.7x; GPU ratios are 1.15x/0.95x/1.23x. The prototype
sometimes uses more tracked memory (at 1,500 CPU appends, about 165 vs 153 MiB).
These omit attention, codec and continuation/trim behavior. They do not prove
an end-to-end model speedup or replacement-cache compatibility. Production
`KVCacheSimple`, attention history, weights, sampler, tensor math and platform
routing remain unchanged. A future candidate must pass full per-frame/trim/reset
and seeded audio comparisons before an end-to-end paired benchmark can justify
adoption. Raw profile and cache observations:
[`inference-experiment.json`](architecture-08/inference-experiment.json).

An earlier experiment with per-layer materialization was stopped after sampling
showed frequent GPU synchronization. Its incomplete timings were discarded; only
the completed per-frame experiment above is used. Log:
`/tmp/libroxtts-08-inference-final.log` (256.1 s, test passed).

## Final validation and delivery

- Full Debug suite: passed.
- Full Release suite with the explicit real-asset gates: passed. Both renderer
  parity tests pass, including matched cold/warm MLX CPU/GPU renders and streamed
  output, plus Core ML receiver-cancellation/recovery.
- Frozen public inventory: 2,802 entries before and after, zero missing, added or
  changed declarations. This includes public engine products and reexports.
- Generic iOS and Mac Catalyst Release demo builds: passed, signing disabled.
- Exact audio comparison, long and short paired planning probes, and isolated
  inference/cache experiment: passed as scoped above.

[`validation.json`](architecture-08/validation.json) records source commit,
commands, runner summaries, log paths/hashes and artifact hashes. Reproduction:
[`architecture-08/README.md`](architecture-08/README.md).

The final runtime/test source is committed at `3f53a39`; subsequent changes only
record documentation/evidence. Commits are unsigned because the configured
1Password signer failed; signing configuration was not changed. Work remains on
the isolated `codex/0.8-reliability-performance` branch. The 0.7 worktree is clean,
the original Companion checkout was not modified by this task, and no branch
was merged, tagged, pushed or published.

Qualification still required before a release claim: physical devices,
minimum Swift 6.3 toolchain, sustained thermal/energy behavior and broader
listening/language coverage. Basic/Qwen real-model suites were not enabled;
their inference implementations are unchanged. Symbol checks establish the
recorded macOS public declarations, not binary ABI, and generic client builds
do not establish device runtime behavior. Installation recovery retains the
existing host-serialization contract and does not claim power-loss durability.
