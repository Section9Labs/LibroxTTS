# Max background execution — physical M4 iPad

Device: iPad Pro 11-inch M4, approximately 8 GB RAM, iPadOS 27.0.1 (24A446).
Isolated `com.section9labs.MaxDeviceProbe`; production Librox was not replaced.
All trials use the shared planner and renderer with temperature 0.3 and actual
spoken audio playing through an AVQueuePlayer/AVAudioSession playback session.
The app was backgrounded by opening Settings. These are Home/app-switch tests,
not lock-screen tests. No iPhone or iOS 18–25 physical device was available.

| Trial | Steps | Actual backend | New audio | Render time | Result |
| --- | ---: | --- | ---: | ---: | --- |
| `gpu-authorized-final.json` | 8 | GPU with scoped authorization | 27.60 s | 14.06 s | Complete; rejected unowned GPU flag, then accepted actual grant |
| `cpu-paced-long.json` | 1 | CPU with process-time pacing | 72.96 s | 213.97 s | Complete; three passages, all states 2, playback rate 1 |
| `gpu-clean.json` | 8 | GPU, granted by iOS | 27.92 s | 13.88 s | Complete; playback advanced; all render start/end states 2 |
| `controlled-grant-retirement.json` | 8 | GPU cancelled, CPU retry | 27.36 s | 35.48 s | Complete; following units stayed CPU |
| `cpu-four-steps.json` | 4 | CPU, no grant | 26.72 s | 33.09 s | Complete, slower than real time |
| `cpu-initial.json` | 8 | CPU, no grant | 28.48 s | 36.84 s | Complete, slower than real time |

`gpu-clean.json` regenerated a 75-second foreground narration buffer in the same
process before background execution. Temporary C++/Swift device diagnostics were
removed before this build; the MLX dependency checkout was restored unchanged.
The clean GPU run's post-unit footprint snapshots ranged from 774 MB to 1.00 GB;
these are not continuously sampled peaks. Thermal state remained nominal.

The controlled-retirement run calls the public `finish(success: false)` during
the first render. The helper cancels/awaits that render before ending the grant;
the reader discards partial output and retries the unfinished passage on CPU.
This tests the shared retirement/cancellation path. It does not establish actual
system-triggered expiration or user cancellation through the system Live Activity.

`gpu-initial.json` and `cpu-initial.json` are earlier diagnostic runs. They used
optional device tracing to locate an MLX 0.32.3 CPU LayerNorm fallback submitting
one multiply to GPU. The SDK implements that normalization on the scoped CPU;
the physical CPU run then succeeded without GPU operations. Clean later runs
retested both GPU and CPU after removing diagnostics.

No sampler-step reduction alone is claimed to guarantee real-time CPU playback.
The short trials switch languages and include loading/conditioning overhead.
Hosts must measure buffer replenishment, preserve requested quality when possible,
and buffer or prepare passages if the device cannot sustain the chosen speed.

Local validation also passed the full release Swift suite, CPU/GPU reference
latent/decoder comparisons (maximum absolute error threshold 1e-4), CPU→GPU→CPU
backend checks, cancellation/recovery, preserved sampling/cache identities,
verified automatic cast metadata and realtime-budget policy tests. Optional
unrelated model-fixture tests remain skipped when their assets are absent.

Numerical completion is not listening-quality acceptance. The current tests do
not certify full-book thermals, older iPhones, cold downloads, lock/unlock,
interruption handling or the production app's reader lifecycle. The app owner
must integrate and verify the [beta.5 contract](../../../../docs/UPGRADE-0.4.0-beta.5.md).

## Sustained CPU failure found before release

An initial unpaced one-step CPU run was terminated by iOS after 55 seconds:
48 seconds of process CPU time (88% average), exceeding an 80% / 60-second
background CPU allowance. It had completed one 23.84-second passage in 31.78
seconds. This failure disproves sustained safety of the short unpaced trials.
The SDK now paces iOS CPU work at frame boundaries using process CPU time, with
a conservative 50% target. Lower sampler steps alone did not prevent this limit.

The paced rerun completed all three passages after **214 seconds** of background
CPU rendering (beyond the previous 55-second fatal run). All start/end states
were background, playback remained at rate 1, and thermal state stayed nominal.
The harness queued four real narrated buffer passages in advance so playback
would not starve during this resource-budget test. It is approximately 3× slower
than real time; **this does not qualify uninterrupted live CPU generation**. The
short CPU rows above predate pacing and are not final-runtime throughput claims.

The final GPU trial also checks `rejectedUnownedGPU == true`: merely selecting
`.backgroundGPU` fails outside a grant-owned operation. A real grant then
successfully loads and renders all three passages through the task-local scope.
The scope is revoked on expiration and operation completion.
