# LibroxTTS 0.9 implementation

Authorized sequence: measurement/contracts; bounded preparation reuse; Max request
handling; broader planning; verified file installation; full-model cache experiment.
Base: 0.8 `e72a0cd`. Work is isolated on `codex/0.9-preparation-refactor`.

## Review and commit plan

1. **Measurement [Strong].** Existing preview-based benchmark excludes model load
   from its first generation. Add separate cold, preview-warmed, repeated, switched
   and backpressured cases without changing existing report fields. Capture PCM,
   events, first accepted frame, frame service percentiles and sampled footprint.
2. **Preparation ownership [Strong].** Share immutable English dictionary data
   only while owners remain alive; reuse actor-owned DSP setup with per-unit reset.
   Explore one verified voice prompt per loaded language, preserving current file
   validation/errors and exact tensor snapshots. Measure before adoption.
3. **Max requests [Strong].** Consolidate duplicated complete/streamed MLX execution
   and pure request preparation, retaining backend-specific validation precedence,
   resource retirement and RNG initialization. Keep public types in their modules.
4. **Broader planning [Worth exploring].** Extend the proven prefix domain and
   localize it to safe source spans, retaining full normalization for contextual
   text and exact first-failure split decisions. Differential-test against 0.8.
5. **Verified publication [Strong].** Share streaming hashes and download handling
   behind internal adapters. Stage replacement on the destination filesystem and
   atomically rename only verified files. Preserve public errors/progress order.
6. **Capacity cache [Experiment].** Run actual model inference with the candidate;
   check offsets, snapshots, trim/reset and exact seeded PCM before performance.
   A failed equivalence or inconclusive gain means production keeps concatenation.

Top recommendation: complete measurement and ownership changes first. Public type
moves, MLX-free iOS, altered acoustic models and altered RNG streams are excluded.
Qwen concurrency remains a separately scoped maintenance track, not a new model
selection or an excuse to alter existing streaming behavior.

## Preparation decisions

English dictionaries now share immutable decoded resources through a synchronized
weak cache, keyed by US/UK dialect. A live Lexicon owns the resources; the cache
alone never extends their lifetime. Construction failures are not retained.
Concurrent owner, dialect separation, failed load and last-owner release tests
exercise the ownership rules.

On this Mac, constructing four additional live owners fell from 2.41 s (US) /
2.16 s (UK) to a few microseconds; cold decoding remains about 0.55–0.64 s. These
are constructor measurements, not end-to-end synthesis gains. Raw observations:
`architecture-09/preparation-{baseline,candidate}.json`.

Two candidates were measured and rejected:

- Resetting/reusing a voice enhancer produced exact PCM but was effectively neutral
  in the ABBA 30-render probe. Production keeps per-unit DSP construction.
- Verified voice-prompt reuse retained 6,242,304 bytes and took 3.35 ms per warm
  call, versus 2.61–2.66 ms decoding. Full-file hashing is required to preserve
  detection of changed/corrupt assets. Skipping verification is not an acceptable
  shortcut. Production voice preparation remains unchanged.

## Request ownership

MLX complete and streamed rendering now use one private validation/loading
boundary. Validation precedence, cold model initialization/RNG consumption,
backend resource retirement and delivery-specific budget/callback order remain
unchanged. Core ML already has a common rendering path and does not gain a second
abstraction. Invalid-request precedence tests cover both MLX entry points.

## Planning

The prefix proof is now local to an oversized sentence. Numeric/contextual text
in neighboring sentences no longer disqualifies a plain sentence. Nonmatching
custom dictionary readings are safe only when no relevant literal occurs in the
canonical sentence; possible matches fall back to full normalization. The proof
domain includes conservative quote combinations and Italian, excluding its
lexical hour rewrite. Cross-sentence ranges and unsupported text still fall back.

The paired ABBA long-sentence probe preserves all ten plan fingerprints. For the
five quoted/mixed/dictionary/Italian cases, Plus planning falls from 666–702 ms to
8–11 ms (59–80x); Max falls from 1.17–1.32 s to 7–10 ms (126–170x). This deliberately
stresses previously ineligible long sentences; it is not a typical book-wide or
inference speedup. Full-plan differential tests compare source/synthesis text,
UTF-16 ranges, boundary/prosody and render identities against the frozen planner.

## Verified publication

Basic and narration asset downloads now share chunked hashing and transfer logic
behind internal adapters. Existing public size/error policies, HTTP requirements
and per-file progress remain at the callers. Downloads are copied beside their
destination, verified again, then adopted using Foundation file replacement.
Installed bytes survive injected partial-copy/disk-full, corruption, cancellation
and adoption failures. Temporary files are cleaned on normal success/failure.

The host must still serialize installation against rendering. This does not
promise multi-file transactions, crash-time orphan cleanup, power-loss durability
or safe simultaneous installers. An interrupted process may leave an unreferenced
unique staging file; it does not need to remove the old destination to stage it.

## Backend measurements

The sidecar ran eight cases on each of Core ML, MLX CPU and MLX GPU in independent
ABBA processes. Every PCM byte and completed-chunk event matches across the four
runs within each backend: 24 distinct cases, 96 case executions. Cold means a
fresh engine without preview; preview time is separate; frame-service percentiles
exclude first-frame/setup and synchronous receiver time. The excerpt/switch tests
are short workloads, not long-book or thermal qualification.

Median sums of the eight generation times were 6.90 → 6.35 s (Core ML),
34.85 → 35.04 s (MLX CPU), and 63.70 → 63.93 s (MLX GPU). CPU/GPU throughput is
essentially unchanged. The Core ML difference is dominated by process/file-cache
load variability (baseline process totals 7.48 and 6.33 s, candidate 6.35 and
6.35 s); this change does not optimize Core ML inference and no general throughput
gain is claimed. First-frame latency, p50/p95 frame service, sampled footprints,
thermal states and hashes are retained in `architecture-09/backend-abba.json`.
No task-owned builds or other benchmarks ran alongside these paired measurements;
this remains a shared Mac, not a controlled dedicated device.

## Capacity-cache decision

The capacity prototype was applied to the actual runtime `KVCacheSimple` and
built into model inference. Ordinary CPU/GPU prefill, append, retained snapshot,
restore, trim/reset and manual-offset tests pass. A separate public-reference
contract fails: mutating an MLXArray returned by `state` affects the next append
in the existing cache, while the capacity prototype appends from its separate
backing array. Passing snapshot-isolation tests alone does not establish public
compatibility. Production keeps concatenation; the experiment is archived as
`architecture-09/capacity-cache.patch`, and the new contract stays in the suite.

The failed public contract is already sufficient to reject this candidate.
Full-model CPU/GPU audio checks are recorded separately; timings from a rejected
candidate must not be advertised as an adopted performance improvement. Future
work could isolate a private model-only cache, but that is a separate design with
its own numerical/performance gates, not a reason to change this public class.

All sixteen actual-model capacity CPU/GPU cases preserve exact PCM and chunk
events, including cold/warm, book excerpt, voice/language switch and backpressure.
This does not override the failed public reference contract. No paired speedup
claim is made for that rejected implementation.

The existing 0.8 planning controls also preserve every fingerprint. Already-fitting
units remain about 0.65–3.04 ms (ratios 0.94–1.00x; the largest absolute difference
is 56 microseconds). Existing plain long units remain about 1–37 ms (0.98–1.11x).
The large 0.9 gain is specific to the newly eligible domain.

## Final validation and delivery

- Full Debug and Release package suites pass. The Release invocation enables the
  existing real Core ML/MLX renderer parity, preparation recovery and frozen
  0.6.2 audio suites. New cache reference tests pass with the retained production
  implementation, as do planning, dictionary ownership and transfer failures.
- All 32 frozen recordings and completed chunk events are exact: 2,047,104 Float32
  samples. This includes English/Spanish Plus and Core ML Max, sampler counts
  1–8, original/calm delivery, multi-chunk continuation and cancellation/reload.
- The new backend sidecar passes 24 distinct cases in 96 ABBA case executions.
- Public inventory: 2,802 declarations, zero missing/added/changed entries.
- Generic iOS and Mac Catalyst Release client builds pass, signing disabled.

`architecture-09/validation.json` records commands, logs/hashes, runner summaries,
source identity and artifact hashes. `architecture-09/audio-parity.json` records
only compatibility results: simultaneous client builds make the full-suite
recording timings unsuitable for performance claims. Paired benchmarks were run
separately without task-owned builds. Reproduction is in `architecture-09/README.md`.

Runtime/test/benchmark source is committed at `d5c83c2`; subsequent changes only
record evidence/documentation. The isolated `codex/0.9-preparation-refactor` branch
contains separate commits for measurements, dictionary ownership, Max request
handling, planning, transfer/publication, the rejected cache experiment and final
evidence. Commits remain unsigned under the established local workflow; signing
configuration was not changed. The 0.7/0.8 worktrees remain clean and the original
Companion checkout was not modified. Nothing was merged, pushed, tagged or shipped.

Release qualification still requires physical devices, the minimum Swift 6.3
toolchain, longer thermal/energy runs and broader language/listening coverage.
Basic/Qwen real-model suites were not enabled; their inference remains unchanged.
Qwen concurrency was identified as a separately scoped maintenance track and is
not included in this candidate. macOS symbol inventory is not binary-ABI proof;
generic iOS/Catalyst builds are compile checks, not device-runtime acceptance.
