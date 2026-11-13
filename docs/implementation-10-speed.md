# 1.0 follow-up — synthesis speed and Max voice levels

**Historical pre-release qualification record.** The user authorized v1.0.0
publication on 2026-11-13 with the remaining gaps disclosed. See the
[release record](validation/release-1.0.0.json) and [app migration](UPGRADE-1.0.0.md).
Statements below about an unpublished candidate describe the measured checkpoint.

Baseline: published 0.9.0, `07fcf437004027f58ad8bb16de7877d0ee74a9a8`.
Worktree: `/Users/matt/Code/swift/librox-tts-10-review`.
The candidate is **unpublished**. This report supersedes the raw synthesis
regressions in [the initial 1.0 record](implementation-10.md); the preparation,
planning and experiment evidence there remains applicable.

## Scope and preservation

The speed fix detaches the final 32-value Core ML flow latent before retaining it
in continuation history. The execution plan still reuses its inputs and keeps
intermediate tensors in Core ML; autorelease boundaries remain. The copy changes
ownership without changing values, model assets, random sampling or token order.
This is committed separately at `44c25af`.

The user subsequently authorized changing **default Max / Pocket narration
loudness**. Consequently, raw engine PCM stays exact while `NarrationRenderer`
output gets calibrated levels by default. Basic and Plus remain unchanged.
Sample counts, timing, progress, error mapping, cancellation and public declarations
remain covered by their contracts. This authorized delivery change must not be
misrepresented as identical facade PCM.

## Physical iPad measurements

M4 iPad Pro 11-inch, iOS 27.0.1, foreground CPU Core ML, four sampler steps,
fixed English Caro/Calm passage. Fresh and warm comparisons use ABBA order.
All warm timing rows reported nominal thermal state.

| Measurement | 0.9 | Repaired candidate |
|---|---:|---:|
| Warm passage median | 3.3667 s | 3.2570 s |
| Setup plus first produced audio | 5.4009 s | 4.9441 s |
| Sustained sampled peak footprint | 1,480.71 MiB | 83.03 MiB |

Warm throughput is **3.4% higher**, reversing the original 20.5% time regression.
Setup plus first audio is 8.5% shorter. Fresh preparation itself is nearly unchanged
(3.516 s versus 3.542 s); OS/compiler caches are not purged.

The candidate completed **411 renders / 1,801 seconds of rendering**. Compared
at the baseline's 53 renders, sampled peak footprint is 94.4% lower, and the same
candidate peak holds over the full soak. Baseline and candidate soaks have different
lengths and thermal histories; this is memory/continuation evidence, not paired
soak-throughput evidence. Both reached serious thermal state. No energy, background,
locked-device playback or physical iPhone claim is made.

Twelve qualification recordings (1,006,080 samples) and progress events match
0.9 exactly; raw files were also compared byte-for-byte. The isolated probe apps
were removed after collection. This device probe exercises raw engines, predating
the facade loudness change. See [device timing](architecture-10-speed/device-final.json)
and [sustained qualification](architecture-10-speed/device-qualification.json).

## Mac measurement and delivery qualification

The M3 Ultra Mac comparison repeats three ABBA blocks (12 processes, 18 warm
observations per revision), with identical WAV bytes throughout. Our seven
calibration workers were paused for the measurement. Other work on this shared
Mac produced visible timing variation; all observations are retained.

| Fixed Core ML passage | 0.9 | Repaired candidate |
|---|---:|---:|
| Warm median | 4.3993 s | 4.3781 s |
| Sampled peak footprint, median across processes | 176.38 MiB | 111.56 MiB |

The pooled render medians indicate **near parity** (0.5% higher measured throughput),
with **36.7% lower memory**. Aggregating the median of each process instead gives
4.384 versus 4.507 seconds (2.8% longer), so the small timing difference is sensitive
to aggregation. A ten-warm-render follow-up is retained alongside this run. The
earlier 5.3% time regression is no longer present in the pooled comparison.
The original 2x synthesis goal remains unmet; the change should not
be sold as a large inference speedup. Prepared-install first audio is 0.189 versus
0.134 seconds in this run; it excludes fresh asset installation/compilation.
See [all process/stage receipts](architecture-10-speed/profile-abba.json).

The shorter Core ML sidecar also retains exact PCM/events: warm cases are 3.5–3.6%
faster, book/voice switch approximately 1.6% faster, and slow-receiver wall time
approximately 1% faster. Cold and language-switch paths improve more (2.16x and
1.66x), reflecting setup work. These eight-case results complement, rather than
replace, the longer fixed-passage comparison. The isolated 24-render Mac ownership
test passes with exact repeated PCM.

The follow-up [ABBA with ten warm renders per process](architecture-10-speed/profile-stability.json)
also preserves exact WAVs. Pooled warm medians are **4.774 → 4.702 seconds** (1.5%
higher throughput); median process medians are 4.778 → 4.699 seconds (1.7% higher).
This supports restored speed rather than a substantial speedup. Sampled footprint
in this longer repeated-render workload is 368.17 → 113.16 MiB (69.3% lower): the
baseline grows with more repetitions while the candidate remains bounded. This
longer workload must not replace the like-for-like three-repetition memory figure.

Voice-level results are collected separately in
[`loudness-review`](loudness-review/README.md). The raw timing binaries predate
that facade-only transform; its measured processing overhead is reported separately.

## Default Max loudness results

The default-level implementation is committed at `b3b055b`. The SDK now uses **525 frozen voice/language/style profiles**, measured across
**3,375 recordings / 283,286,400 samples**. On withheld neutral passages, English
median voice spread falls **15.7 → 2.55 LU**, and Spanish **4.75 → 2.35 LU**.
Across all seven languages the largest remaining median spread is **4.35 LU**;
the largest same-passage spread is **5.7 LU**. All nominated neutral spread goals
pass. Reference styles retain measured offsets from each voice's Neutral profile,
bounded to ±3 LU; no sentence-based gain riding is introduced.

The production Swift transform costs about **0.57 ms per 22.16 seconds of audio**
on this Mac. Buffered/streaming partition tests and actual Core ML / MLX CPU/GPU
facade tests pass, including progress and cancellation recovery. Raw engines still
match frozen samples; facade comparisons expect exactly the calibrated raw audio.

Peak safety activates on **27 samples in two German holdouts**; consequently the
zero-activation goal is explicitly **not met**. No other measured samples needed
the safety knee, and no delivered recording measured at or above 0 dBTP. These
two cases remain in the listening set; they are not silently removed or used to
refit gains. Full per-language results, policy, profiles and limits are in the
[calibration report](loudness-review/README.md).

## Validation

Debug and Release each pass **148 XCTest cases (34 expected skips)** and
**559 Swift Testing cases**. Opt-in real-model facade tests pass separately:
Core ML English/Spanish frozen raw PCM plus calibrated buffered/streaming/events
and cancellation recovery; MLX CPU/GPU cold/warm buffered and streaming parity.
The production level audit passes over all 3,375 recordings. All **2,802 public
declarations** remain unchanged. Generic unsigned iOS and Catalyst example builds
pass. The generated profile Swift and JSON reproduce byte-for-byte from the
recorded meter reports. See [validation receipts](architecture-10-speed/validation.json).

This is local Xcode 27.2 / Swift 6.4.2 validation. Remote Swift 6.3 CI, physical
iPhone, host-app playback integration and human listening remain unqualified.

## Integration boundary

Hosts should continue using `NarrationModel.pocket.renderIdentity(for:)` as part
of their prepared-audio cache key. The level revision is included automatically;
old Max prepared audio must not be reused under the new identity. No base-model or
style-pack redownload is required. Hosts that call raw Pocket engines directly
continue receiving raw audio and should route book narration through the facade
when adopting the default calibration. Avoid stacking a second host normalizer.

The direct WAV comparisons and human listening verdict are separate from numeric
qualification. Publishing 1.0 remains pending listening and any outstanding
hardware/application acceptance; this task does not publish a tag or release.
