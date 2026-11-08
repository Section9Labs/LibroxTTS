# Max beta.6 resource and regression evidence

Baseline: `8e4645bf4d6000b48d92803b430127b2e7e3580d` (published beta.5).
Machine: Apple M3 Ultra, 256 GiB RAM. Apple Swift 6.4, optimized Release builds.
These are Mac SDK measurements, not iPhone or production-reader acceptance.

## Measured tradeoff

The final runtime consumes/converts checkpoint tensors individually, clears
finished/failed decoder state, evaluates prefill in groups of three transformer
layers, and recycles allocator cache at checkpoints above 256 MiB. It retains
FP32 model arithmetic, all requested sampling steps, temperature, voices, chunking
and continuation. The 256 MiB threshold is soft, not a hard allocation limit.

[Raw comparison data and PCM hashes](comparison.json) cover English and Spanish
at 1/2/4/8 steps. Long GPU passages use continuation and produce roughly 36–41
seconds of audio per case. Short CPU cases run three repetitions per setting.

| Measurement | Beta.5 | Candidate |
| --- | ---: | ---: |
| Largest sampled long-GPU process footprint | 4.607 GB | 1.983 GB |
| Largest sampled long-GPU allocator cache | 3.093 GB | Below 0.269 GB |
| First English GPU load: peak active MLX allocation | 598 MB | 400 MB |
| English long GPU render at eight steps | 3.663 s | 3.856 s |
| Spanish long GPU render at eight steps | 4.305 s | 4.459 s |
| English short CPU render at eight steps, median | 6.395 s | 6.410 s |
| Spanish short CPU render at eight steps, median | 7.342 s | 7.348 s |

Footprint fell about 57% in this matrix. Eight-step GPU rendering cost about
4–5% more time; lower-step GPU cases cost about 5–16% more. CPU medians stayed
within 2%. These are limited trials, not throughput confidence intervals. The
baseline CPU run overlapped compilation during part of its run; its values are
supporting regression evidence, not a controlled hardware performance claim.

All eight continued GPU outputs and all 24 short CPU outputs matched beta.5
PCM byte for byte. A separate eight-step check matched all seven languages
(English, Spanish, German, French, Italian, Portuguese and Dutch). Those two
processes ran concurrently and are used only for audio equality. Different backends are compared to their own baseline, not
claimed to be identical to each other. Frame-boundary footprint sampling can miss
intrakernel peaks. MLX peak counters exclude allocator cache; this distinction
revealed the dominant retention that active-tensor measurements alone missed.

## Reproduction

Use the unchanged, verified v2 language packs. Run baseline and candidate in
separate processes/checkouts with this same comparison test. Set `POCKET_ASSETS`
to the pack root and `POCKET_METALLIB` to that build's MLX default.metallib.

```sh
# Continued GPU comparison, including cache and process-footprint sampling.
POCKET_COMPARISON_OUTPUT=/tmp/max-comparison \
POCKET_COMPARISON_LONG=1 POCKET_COMPARISON_TRACE=1 \
swift test -c release --filter releaseMemorySpeedAndPCMComparison

# CPU: omit LONG/TRACE and set POCKET_COMPARISON_BACKEND=cpu.
# Seven languages: set POCKET_COMPARISON_ALL_LANGUAGES=1 (eight steps).
```

Run these tests alone for meaningful process-wide allocator measurements. The
comparison output contains raw 24 kHz mono Float32 PCM for direct comparison.
Cache hits, different voices or settings are not substituted for generation.

## Boundaries

The affected iPhone 17 Pro Max was unavailable. No reproduction or fix of its
reported memory event/seek stall is claimed. Physical iPhone narration, actual
older-OS execution, lock/unlock, background grant expiration, interruption,
thermal/endurance, host buffering/position and listening acceptance remain open.
The SDK adds no calibrated initial-step recommendation from these Mac results.
Compact BF16 weight-storage variants stayed experimental because of their larger
rendering penalty. The published weights and acoustic runtime identity remain
unchanged.

## Validation completed before publication

- Full `swift test` and `swift test -c release`: PASS.
- Real-v2-assets Pocket suite: PASS (runner reports 37 tests; comparison/storage
  experiments are opt-in and run separately).
- Final resource suite: 7 tests PASS, including cancellation at tensor load,
  prefill, flow and codec checkpoints, same-engine reuse, and the SAME facade
  rendering replacement text that matches a fresh deterministic reference.
- Generic iOS SDK build and Release KokoroDemo iOS example build: PASS, unsigned
  compile-only validation. No app installed or uploaded.
- Benchmark Python script compilation and `git diff --check`: PASS.
- 39 final PCM regression comparisons: 8 continued GPU, 24 short CPU, and all
  seven languages at eight steps. All matched their beta.5 baseline exactly.

An exploratory `swift build --build-tests` invocation failed to resolve a cached
KokoroAudio module under its different build settings; the supported `swift test`
path rebuilt and both complete configurations passed. This was not suppressed.
GitHub CI/publication are recorded by the immutable release receipt.

The first GitHub CI attempt exposed a test-runner prerequisite: even the tiny CPU
residual-reset fixture initializes MLX, whose compiled Metal library is absent
from the default SwiftPM CI runner. That runtime fixture now explicitly requires
`POCKET_METALLIB`, like the opt-in model tests. It is verified locally with the
compiled library; pure admission/cancellation-policy tests remain unconditional.
No production code or benchmarked runtime changed for this harness correction.
