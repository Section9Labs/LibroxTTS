# Max background execution — physical M4 iPad

Device: iPad Pro 11-inch M4, approximately 8 GB RAM, iPadOS 27.0.1 (24A446).
Isolated `com.section9labs.MaxDeviceProbe`; production Librox was not replaced.
All trials use the shared planner and renderer with temperature 0.3 and actual
spoken audio playing through an AVQueuePlayer/AVAudioSession playback session.
The app was backgrounded by opening Settings. These are Home/app-switch tests,
not lock-screen tests. No iPhone or iOS 18–25 physical device was available.

| Trial | Steps | Actual backend | New audio | Render time | Result |
| --- | ---: | --- | ---: | ---: | --- |
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
latent/decoder comparisons (maximum absolute error threshold 1e-4), GPU→CPU→GPU
backend checks, cancellation/recovery, preserved sampling/cache identities,
verified automatic cast metadata and realtime-budget policy tests. Optional
unrelated model-fixture tests remain skipped when their assets are absent.

Numerical completion is not listening-quality acceptance. The current tests do
not certify full-book thermals, older iPhones, cold downloads, lock/unlock,
interruption handling or the production app's reader lifecycle. The app owner
must integrate and verify the [beta.5 contract](../../../../docs/UPGRADE-0.4.0-beta.5.md).
