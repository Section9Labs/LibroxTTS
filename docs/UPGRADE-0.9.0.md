# Librox app handoff — LibroxTTS 0.9.0

Migrate Librox to **LibroxTTS 0.9.0**, including the previously unpublished 0.7 and
0.8 work. Preserve concurrent app changes and saved books, reading positions,
voices, styles, sampling, casts, dictionaries, downloads and prepared audio.
This is an SDK integration handoff, not authorization to upload the app.

```swift
.package(url: "https://github.com/Section9Labs/LibroxTTS.git", exact: "0.9.0")
```

Release: https://github.com/Section9Labs/LibroxTTS/releases/tag/v0.9.0

## Integration work

1. Inspect the app's current branch, dependency pins and integration state. Use an
   isolated worktree if needed to preserve concurrent work, and follow its release
   manager/contribution instructions. Find every applicable Package.swift,
   Package.resolved, Xcode project, XcodeGen input and CI dependency declaration.
   Replace applicable older SDK/commit pins with exact 0.9.0, resolve the graphs,
   and verify each resolved revision against the published tag. Avoid unrelated
   dependency upgrades and generated project churn.
2. Read this handoff and the SDK's `docs/UPGRADE-0.6.2.md`. If the app predates
   0.6.2, apply the relevant 0.6.0/0.6.1/0.6.2 integration requirements as well;
   do not assume earlier migration work is present. Audit the existing renderer,
   downloads, playback queue, text progress and cancellation wiring before editing.
3. Treat 0.9 as a contract-preserving upgrade from 0.6.2. No caller API rewrite,
   new model download, new audio-cache revision or saved-setting migration is
   required solely by this update. Retain the actual approved app behavior and
   make only integration changes supported by a demonstrated mismatch.
4. Build/test the app's supported iPhone/iPad and Mac/Catalyst configurations.
   Run its narration, persistence, downloads and playback tests. Use available
   physical devices for the acceptance checks below; report unavailable checks
   explicitly rather than substituting simulator success for device evidence.
5. Commit the integration and provide the release manager with the commit, exact
   SDK revision, changed dependency graphs, test/build results, device observations,
   before/after measurements and remaining gaps. Do not upload TestFlight/App Store
   builds or change unrelated product UI as part of this handoff.

## Contracts to retain

- iPhone/iPad Max uses Core ML CPU; Mac/Catalyst Max retains MLX. One acoustic
  backend pack per device/language; preserve Basic/Plus and their selection rules.
- Model bytes, manifests, voice/style IDs, sampling and render-cache identities
  are unchanged from 0.6.2. Keep existing verified downloads and prepared audio;
  allow normal manifest/OS/receipt validation. Do not force redownload, recompile
  or clear caches merely because the SDK version changed. Upgrading from an older
  release must still respect its documented identity changes, particularly the
  0.6.2 `pocket-continuous-clauses-2` correction.
- Preserve saved choices. The documented new-book Max default remains Caro Davy /
  Calm, Careful reading, temperature 0.3 and four sampler steps. Preserve supported
  steps 1–8 and the app's approved full-speed generation/bounded-buffer policy.
- `onTextChunk` reports completed prepared-text chunks in cumulative 24 kHz source
  samples per render call, after frame acceptance. It is not a source UTF-16 range,
  a transcript or word alignment. Drive visible text from **played source samples**,
  accounting for queued-unit offsets, seeks, rate changes and resampling. Retain
  the explicit fallback for cached audio without chunk metadata.
- Keep synchronous throwing frame/event callbacks and bounded backpressure. Do not
  create an unbounded task per frame. Reject stale audio/events after seek, book,
  voice, language or account changes. Cancel and await active generation before
  unloading; an incomplete stream must never become a complete cached artifact.
- The host still serializes asset installation/removal against generation. SDK
  replacement/recovery improvements do not authorize concurrent installers or
  promise a multi-file transaction or power-loss durability.

## App acceptance and measurements

Compare the current app pin and 0.9 with the same device, OS, build settings,
verified assets, text, voice, language, sampling and seed where available. Separate
fresh engine load, preview-warmed generation and repeated warm generation. Record
first accepted frame, first audible output, sustained throughput, frame-service
p50/p95, buffer underruns, sampled memory and thermal state. Include short text,
long quoted/mixed-context paragraphs and custom dictionary readings.

Exercise original/calm delivery, English/Spanish and the app's other supported
languages, voice/language and chapter/book switches, rapid cancel/seek/resume,
slow/failing receivers, interrupted installation and reuse of existing downloads
and prepared audio. On physical devices, check lock/background, routes/calls,
normal/custom playback rates, text-follow behavior and sustained narration.
Listen for continuity, missing/repeated words, gaps, clicks and changed pacing.
Retain saved positions and settings across relaunch and upgrade.

Report actual results separately from checks that could not run. SDK evidence:

- 2,802 public declarations unchanged from 0.6.2; Debug/Release tests and unsigned
  generic iOS/Catalyst client builds pass locally.
- 32 frozen English/Spanish Plus/Core ML Max recordings match exactly: 2,047,104
  samples and completed-chunk events. Real renderer parity and cancellation/reload
  pass, and 24 new backend cases pass exact PCM/events in paired ABBA runs.
- Relative to the local 0.8 candidate, targeted previously ineligible long-sentence
  planning improves 59–170x; this is not a typical-book or inference-throughput
  claim. Four additional live English dictionaries fall from 2.2–2.4 s to a few
  microseconds. Cold decoding is not eliminated. General inference throughput
  remains essentially unchanged in those measurements.
- DSP reuse, verified prompt caching and a capacity-cache replacement were not
  adopted. The cache experiment preserves tested model audio but changes a public
  mutable-reference behavior. Production retains the compatible cache.

Detailed evidence and limitations: `docs/implementation-07.md`,
`docs/implementation-08.md`, `docs/implementation-09.md` and
`docs/architecture-09/validation.json`. SDK checks do not establish combined-app
physical-device, sustained thermal/energy or broad listening acceptance. Basic/Qwen
real-model qualification remains separate; their inference is unchanged.
