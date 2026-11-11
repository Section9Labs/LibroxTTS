# LibroxTTS 0.7 implementation evidence

Baseline: release 0.6.2, `f75bacfbdc86c0c6dd81f0fb11cb9bcd160e49dd`.
Work is isolated on `codex/0.7-architecture-review`; the Companion checkout is
untouched. These are local implementation and validation results, not a release.

## Contract gates

Before runtime edits, `Release07ContractTests` recorded 128 normalization results
across eight languages and 15 plans (41 units) with full fields for multilingual, numeric, paragraph,
combining-character, CJK, unbroken-text and expanding/shrinking dictionary inputs.
The suite also freezes serialization, defaults, cache identities and limit errors.
Concurrent callers compare against the same frozen normalization fixture.

`Scripts/check-public-api.py` compares public declarations against 2,802 baseline
macOS module-symbol entries. Reexports count separately; this is not ABI proof.
`Release07AudioTests` captures exact PCM and completed chunk events with verified
English/Spanish Core ML assets before and after changes. Max visits all sampler
counts, repeated graph selection, two voices, Calm/original style, continuation,
receiver cancellation, recovery and unload. Plus replays captured initial noise
and compares traced versus ordinary synthesis. PCM assets remain local.

## Text preparation

`CompiledTextRules` owns a bounded, thread-safe cache of immutable regexes. No
source text or mutable formatter is cached globally. Numeric-only productions
are skipped when no numeric scalar is present, preserving Italian's unconditional
`alle una` correction. The source planner's first-failing-prefix algorithm and
all normalization ordering are unchanged; no monotonic-length assumption is made.

The frozen contract suite passes. Final Release measurements on the original
Spanish repeated-clause probe, after this task's builds finished:

| Model | Input scalars | 0.6.2 median | 0.7 median | Speedup |
|---|---:|---:|---:|---:|
| Plus | 8,192 | 14.828 s | 2.350 s | 6.31× |
| Plus | 16,000 | 28.910 s | 4.690 s | 6.16× |
| Max | 8,192 | 14.795 s | 3.883 s | 3.81× |
| Max | 16,000 | 29.609 s | 7.663 s | 3.86× |

All eight plan fingerprints match. Each measurement is a three-run median.
A sequential rerun of the unchanged baseline executable and candidate at
512/2,048 scalars confirmed 6.86×/6.84× Plus and 3.64×/2.19× Max improvements.
These are synthetic source-planning timings, not speech generation speedups or
a representative audiobook corpus. The original long baseline partly overlapped
review activity; the paired short confirmation and final candidate ran after this
task's build/test jobs finished. Other workstation activity was not controlled.

Raw evidence: [original baseline](architecture-07/planning-release.json),
[initial candidate](architecture-07/planning-candidate-release.json),
[final comparison](architecture-07/planning-comparison.json),
[paired short comparison](architecture-07/planning-paired-comparison.json).

## Model residency

`PocketFlowModels` keys by compiled graph name inside a loaded-language owner.
Counts 1, 2, 3, 5, 6 and 7 reuse `flowstep`; 4 and 8 retain specialized graphs.
All eight counts therefore load at most three flow objects instead of eight,
eliminating five redundant loads when a session visits every sampler count.
These are exact loader/object counts, not an inferred RSS percentage. Placement,
asset validation and language retirement remain owned by the existing engine.

Loader tests verify graph identity, retries after failure, reuse after sampler
switches and release on retirement. The exact-audio gate exercises the actual
models across the same settings. Text-only preview separation and voice prompt
caching remain deferred: both have additional warming/ownership semantics that
this change intentionally preserves.

## Tensor transport

Max's contiguous `[1,1,1024]` transformer output now becomes a retained, read-only
`[1,1024]` view for flow. Already-compatible arrays pass through directly;
strided outputs still copy in logical order. No attention cache, decoder state,
RNG draw, sampler operation or caller-owned PCM is modified or pooled.

The ordinary path avoids two 4,096-byte payload copies per flow invocation.
This is an exact payload calculation, not a peak-memory measurement. Tests cover
backing-storage identity, ownership across autorelease-pool drainage, release,
negative zero, two padded/strided layouts and malformed type/count rejection.
All 32 initial real-model PCM/event comparisons matched the baseline exactly.
The first lifetime test checked release before the Objective-C autorelease pool
drained; it was corrected to exercise and assert ownership across pool boundaries.

`FlowConditionTests.testTransportMicrobenchmark` compares the former round trip
with the new bridge, with alternating order over five warmed 20,000-call runs.
It is opt-in and has no timing threshold; it measures host transport only.
The Release median was 27.79 ms for the former copies versus 27.30 ms for views
over 20,000 calls (1.02×). Treat timing as effectively neutral; the verified gain
is the eliminated payload copying, with no measured RSS claim.
[Microbenchmark receipt](architecture-07/tensor-transport-release.json).

Plus now checks `captureTrace` before constructing its waveform `CTTensor`.
Trace-enabled output remains present and byte-equal to returned PCM. Ordinary
synthesis avoids a copy of `samples.count * 4` bytes (up to 5,296,128 payload bytes
at the existing 431-latent limit). This does not change the graph or vocoder.

## Audio and end-to-end timing

Both the initial candidate run and a final run after builds finished matched
all 32 baseline PCM recordings and chunk-event sequences exactly: 2,047,104
Float32 samples per run. The final run also verified trace waveform bytes and
the corrected ownership test. Baseline and candidate use the same verified
assets, Max seeds and captured Plus initial noise.

Final aggregate render times for the warm workload groups:

| Group | Trials | Baseline | Candidate | Baseline/candidate |
|---|---:|---:|---:|---:|
| Max English | 11 | 10.059 s | 8.054 s | 1.25× |
| Max Spanish | 11 | 9.906 s | 9.833 s | 1.01× |
| Plus English | 3 | 1.681 s | 1.970 s | 0.85× |
| Plus Spanish | 3 | 2.322 s | 2.518 s | 0.92× |

These mixed results do **not** demonstrate a general synthesis throughput gain.
Plus totals were slower by about 17%/8% in this run; the earlier candidate's
Plus totals were slower by about 7%/4%. There is one baseline observation per
request, changing sampler/voice workloads for Max, uncontrolled system load and
no confidence interval. Investigate this timing delta with repeated paired
device measurements before claiming a render-speed improvement or regression.
The default four-step-only path does not benefit from deduplicating six generic
sampler selections. Cold loads and cancellation/reload are excluded from group
totals but retained in the raw receipts.

Receipts: [initial](architecture-07/audio-candidate-initial.json),
[final](architecture-07/audio-confirmation.json). PCM and saved noise are local
under `/private/tmp/libroxtts-07-audio-{baseline,candidate,confirmation}`.

## Validation and limits

- Full `swift test` and `swift test -c release`: passed.
- Frozen planning/default/error tests and concurrent normalization: passed.
- Model residency, buffer ownership, strided fallback and exact-audio gates: passed.
- Public symbol comparison: 2,802 entries, zero added, removed or changed.
- Generic iOS and Mac Catalyst Release example builds: passed, signing disabled.
- Comparison-script syntax checks and `git diff --check`: passed.

[Validation receipt](architecture-07/implementation-validation.json) records
commands, local log paths and hashes. Environment: Apple Swift 6.4.2, Mac15,14,
macOS 27.0.1. Only Xcode.app is installed; minimum Swift 6.3 is not qualified.
Physical devices, thermal/energy/RSS measurements, other model languages and
broader listening remain open. MLX acoustic code and Basic/Qwen engines were
not changed; their opt-in real-model suites were not enabled. The API snapshot
is macOS-only; iOS/Catalyst builds provide source-client compile checks, not ABI
certification. This work is committed locally, not merged, tagged or published.

The existing prefix-selection algorithm, preview warming, prompt reloads and
mutable sampler buffers remain in place. More aggressive scanning, prompt
caching and scalar pooling require separate ownership/equivalence evidence.

## Reproduce

Run package tests and the symbol comparison:

```sh
swift test
swift test -c release
swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members
python3 Scripts/check-public-api.py
```

Record baseline audio in a separate checkout at `94d8eaa` (the harness with
unchanged 0.6.2 runtime), setting `LIBROX_07_POCKET_ASSETS`, `LIBROX_07_CT_ASSETS`
and `LIBROX_07_AUDIO_OUTPUT` to verified local pack roots and a fresh output
directory. Run `swift test -c release --filter Release07AudioTests`.
In the candidate checkout, additionally set `LIBROX_07_AUDIO_BASELINE` to that
baseline output and use another output directory. For the microbenchmark, set
`LIBROX_07_TENSOR_BENCHMARK` to a JSON output path and include `FlowConditionTests`
in the filter. Compile first, then use `--skip-build` for measurement runs.

```sh
python3 Scripts/compare-07-audio.py "$BASELINE_AUDIO" "$CANDIDATE_AUDIO" --output audio-comparison.json
python3 Scripts/compare-07-planning.py baseline-planning.json candidate-planning.json --output planning-comparison.json
```

The planning probe and its build command are documented in
[the evidence README](architecture-07/README.md). Record golden fixtures only
with the unchanged baseline runtime. The normal test path always reads them.
