# Bounded Max playback — 2026-11-10

The full SDK path (`NarrationPipeline` → `NarrationRenderer`) generated faster
than playback on Tachikoma, an iPhone 17 Pro Max running iOS 27.2, in foreground
and during ten minutes of locked background spoken audio. No debugger was
attached. The phone was connected by USB and playback was 1×.

| Measurement | Result |
| --- | ---: |
| Warm foreground throughput (two passes) | 3.64–4.27× |
| Foreground first generation, including model loading | 3.49× |
| Background generation median / minimum | 4.82× / 3.33× |
| Newly generated background audio | 600.8 seconds |
| Time actively generating that audio | 127.62 seconds |
| Background wall time / playback advancement | 600.06 / 600.07 seconds |
| Buffer underruns | 0 |
| Observed remaining audio buffer | 6.45–47.86 seconds |
| Average process CPU time / elapsed time | 0.563 cores |
| Thermal states | Nominal throughout |
| Observations with protected data unavailable (locked) | 592 of 601 |

The engine retained the original model, Caro Davy / Calm, temperature 0.3,
four sampler steps, Careful reading, continuation and 24 kHz output. It used
Core ML CPU, not ANE/GPU. The producer rendered without artificial CPU sleeps,
paused between units once the queue reached 30 seconds, and resumed at 12 seconds.
Whole-unit completion explains the target overshoot. All 27 background renders
were faster than playback. The initial audible buffer was generated in the
foreground; the background run generated new audio, not just replayed a cache.

The earlier 0.6.0 candidate's 0.5 CPU budget made its short routing fixture run
at 0.47×. That cap was half of one core's process CPU time, not half the phone.
The 0.6.1 Core ML default removes this pacing. Explicit CPU-budget controls
remain available, and Mac MLX routing/defaults are unchanged. No acoustic assets
were altered or republished for this scheduling change.

The SDK now supplies `NarrationPlaybackBufferPolicy` for the same hysteresis,
including playback-rate, pause/end-of-book and invalid-measurement handling.
`renderPocketFrames` exposes the existing engine stream through the public
facade so long paragraphs can feed the player progressively and be bounded
between frames without changing phrasing or continuation. The host must apply
cancellable backpressure and lifecycle handling. The device test used complete
units and explicit nil pacing; it did not exercise the later facade stream or
refactored policy. Their contract tests passed separately: deterministic streamed
PCM equals whole-unit PCM, cancellation recovers, and five buffer-policy tests
pass. The final facade compiled in the signed iOS build.

The complete Release suite passed with real Core ML/MLX assets before the
streaming addition; targeted streaming and policy tests passed afterward. A
filtered test initially failed because MLX's metallib was not found; rerunning
with the explicit built `POCKET_METALLIB` resource passed. This was a test
resource setup issue, not an audio mismatch.

This is a repeated English passage in a separate probe, not the complete Librox
reader. It does not qualify all phones, all languages/styles, faster playback,
battery life, hour-long sessions, or silent background preparation. App-level
integration must verify long paragraphs with progressive playback, interruptions,
seeking and sustained playback at supported speeds. Process CPU time excludes
other processes and is not total-device energy. iOS resource policies still apply.

- [Full device trace](buffered-playback-device-2026-11-10.json)
- [Summary and provenance](buffered-playback-summary-2026-11-10.json)
- [App implementation prompt](../../../../docs/UPGRADE-0.6.1.md)
