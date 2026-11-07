# CT runtime optimization, 6 November 2026

The accepted narration planner, CT weights, ten generator steps, noise distribution, F1 calibration, and 44.1 kHz delivery are unchanged. The pinned vocoder is now evaluated in windows: 64 emitted latent positions with 24 positions of context at each internal edge. Its temporal receptive field is bounded by 117 unpacked decoder frames; one latent position contains six frames. Normalization is per frame. The window centre retains all dependencies; there is no crossfade, punctuation edit, shortening of text context, or audio effect.

Whole-passage vocoding remains selectable through `CTEngine.VocoderMode.wholePassage` for equivalence checks. Window bounds and strided slicing have tests. The real-model regression compared CPU and GPU Core ML at lengths 77, 113, 129, 265 and 431: every output sample was identical. The same fixed-noise full-engine comparison on the accepted two-unit excerpt was sample-identical on both iPhone 17 Pro Max and iPad Pro M4 (77 and 265 latent positions, 23.824 seconds total). The original user's perceptual acceptance remains scoped to that excerpt; numerical equivalence does not establish new language quality.

The app-facing installer now loads and retires the four common generator functions after compilation, allowing Core ML to persist hardware specialization before Play. It does not predict audio or retain an engine. Each function loads inside an autorelease pool and retires before the next. Very short lengths 1–15 remain lazy. Asset validation, compiler-cache identity, cancellation between loads and atomic installation remain intact.

## Measurements

See `CT-RUNTIME-OPTIMIZATION.json` for device receipts. These are short, separate Release probes; full-app and sustained qualification are separate.

| Device | Previous sampled peak footprint | Windowed sampled peak footprint | Previous peak resident | Windowed peak resident |
| --- | ---: | ---: | ---: | ---: |
| iPhone 17 Pro Max | 1,559 MB | 670 MB | 2,174 MB | 1,449 MB |
| iPad Pro M4 | 1,567 MB | 772 MB | 1,961 MB | 1,429 MB |

An additional iPhone process-relaunch baseline reached 1,467 MB sampled peak footprint and 2,122 MB peak resident. These are different memory measures. Footprint was sampled every 20 ms and can miss short peaks. OS specialization caches and temperature can affect timing; this is not a statistical device benchmark.

On a fresh SDK compiler-cache path, pre-specialization took 21.869 s on iPhone and 17.433 s on iPad. Subsequent first load plus full excerpt rendering took 3.006 s and 2.799 s respectively, with warm excerpt rendering 1.893 s and 1.482 s. Preparation moves one-time work into installation; it does not remove that work. The existing app opening/resume PCM reserve is still the path to immediate playback.

No model assets, manifests, release tags or output cache identities change. Physical full-app download/repair, cold/cached startup, dormancy, seek, chapter transitions, background CPU handoff, interruptions, and sustained thermal/memory validation remain in progress.
