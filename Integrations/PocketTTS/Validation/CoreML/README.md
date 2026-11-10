# Max Core ML measurements — 2026-11-10

The iPhone completed CPU-only generation while locked and playing real narration
in the background. Twenty passages produced **446.4 seconds of audio in 121.25
seconds of generation**. Warm median throughput was **3.72× real time** (slowest
3.07×); the app remained backgrounded, playback advanced continuously, and all
thermal samples were nominal. The device was still locked at completion.

All twenty background WAV hashes are identical at seed 42. Their waveform also
matches the iPhone foreground Core ML result byte for byte. The test uses the
same original weights, Caro Davy / Calm voice state, four sampler steps,
temperature 0.3, careful-reading chunker and continuation policy as Max.

| Hardware / execution | MLX GPU | Core ML CPU | Core ML CPU/GPU allowed |
| --- | ---: | ---: | ---: |
| M3 Ultra, foreground | 10.91× | 5.89× | 5.78× |
| iPhone 17 Pro Max, foreground | 5.73× | 4.59× | Not measured |
| iPhone 17 Pro Max, locked background audio | Not measured | 3.72× | Not attempted without a GPU grant |

These are warmed medians, excluding model loading. The Mac twenty-passage CPU
run had a warm median of 6.02×. Spanish (Lola / original voice state) was
11.03× on Mac MLX and 6.11× on Core ML CPU. Spanish delivery-style assets were
not used; they were unavailable in the local verified installation.

The first iPhone MLX generation paid a large shader-initialization cost; warmed
first audio arrived in about 25 ms. Core ML CPU warmed first audio was about
46 ms in the foreground and 49 ms in the background. Each stream chunk is 80 ms
of audio. These are generator callbacks, not measured speaker-output latency.

## Quality and validation

- Recursive Core ML transformer checks passed against unmodified Kyutai at
  varied token lengths. Explicit position inputs are required: deriving the
  position solely from dynamic cache shape caused recurrent divergence.
- Seventy Mimi frames passed independent comparison, including two ring wraps.
  Worst decoded PCM error was below `2e-6` in the tested English/Spanish traces.
- Swift MLX/Core ML frame comparisons passed, along with strided-output and
  malformed-shape tests. The existing 45 Pocket tests also passed.
- Whole English temperature-zero PCM had cosine similarity `0.999999917`;
  the actual temperature-0.3 / seed-42 profile had `0.999997379`. Both comparisons
  had identical sample counts and chunk boundaries.
- English and Spanish ASR screens reproduced the expected word sequences.
  This does not replace human listening acceptance.
- Release macOS build and signed physical iPhone build/install/run succeeded.
  Foreground probe and background probe used separate app data from Librox.

## Limits and next integration work

This is a CPU-oriented float32 baseline, not an ANE optimization or a released
app change. It is slower than foreground MLX GPU, but the tested iPhone CPU
path has headroom to generate speech during background audio playback without
a background GPU entitlement.

The phone was connected by USB. Battery consumption, unplugged/longer endurance,
other phones and silent background chapter preparation remain unmeasured.
Normal thermal state over this test does not establish an energy advantage.

The Mac application footprint grew from roughly 0.52 GB to 0.97 GB during its
twenty-passage repeat test. This retention needs investigation before adopting
the backend for long-lived production sessions. The locked iPhone's sampled
application footprint settled around 0.10 GB, but that excludes Core ML system
services and does not represent total model memory.

The source includes a final safeguard that prefills long continuation histories
in blocks of at most 512 frames. The measured passages fit a single call, so
their computation is unchanged. The final Swift contract tests pass; the probe
binary predates this safeguard.

Full receipts, requests, waveform hashes and limitations: [2026-11-10.json](2026-11-10.json).
Converted model hashes and independent parity: [model-provenance.json](model-provenance.json).
Reproduction and API notes: [COREML.md](../../COREML.md).

Local WAVs and raw device receipts remain under `.coreml-results/`; compiled
models remain under `.coreml-tools/models/`. Both are intentionally untracked.

Follow-up: [platform routing and separate assets](ASSET-SEPARATION.md).
