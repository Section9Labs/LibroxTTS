# Changelog

## 0.6.2 — 2026-11-11

- Integrate approved commit `56393f12bcb33a51b78327a2d4b8ece75d2f4ea8` without runtime changes.
- Preserve clause punctuation and continuation case in adaptive Max synthesis;
  choose natural clause boundaries near the target without creating tiny fragments.
- Add optional `onTextChunk` callbacks to Core ML, MLX and the public renderer.
  Completed chunks report prepared input text and cumulative 24 kHz PCM ranges.
  Progress is tied to played samples, not generation time; this is not word alignment.
- Change prepared-audio chunking identity to `pocket-continuous-clauses-2`.
  Model assets, platform routing, voices/styles and sampling settings are unchanged.
- Matt accepted the tested Spanish recording. Physical-device, sustained throughput
  and broader listening coverage remain documented gaps, not inferred passes.
- [App integration handoff](docs/UPGRADE-0.6.2.md). SDK release only.

## 0.6.1 — 2026-11-10

- Replace the held 0.6.0 candidate's default iOS Max CPU pacing with full-speed
  generation and a reusable bounded playback-buffer policy. Retain explicit budgets.
- Expose progressive Max frames through `NarrationRenderer.renderPocketFrames`.
- Ten-minute locked playback passed on one iPhone 17 Pro Max under the tested
  settings. This is historical qualification of 0.6.1, not every later revision.
- [App implementation prompt](docs/UPGRADE-0.6.1.md); Mac MLX and model assets unchanged.

## 0.6.0 candidate — 2026-11-10 (superseded by 0.6.1)

- Max uses Core ML CPU on iPhone/iPad and retains MLX on Mac/Catalyst.
- Seven separately downloadable Core ML language packs; no MLX acoustic
  checkpoint in iOS downloads. Existing tokenizer, voices, styles and credits
  retain their hashes and immutable URLs. Original model and quality unchanged.
- Device compilation, backend-specific install/audio identities and verified
  reuse from old iPhone MLX installs. Mac model downloads remain unchanged.
- Preserve 0.4.1–0.5.0 CPU-budget, language-uninstall and style APIs; Core ML
  participates in background pacing and serialized language unload/uninstall.
- Fix iOS receipt paths and bound asset-verification memory; physical iPhone
  installation/routing and Core ML numerical checks passed.
- [App implementation prompt](docs/UPGRADE-0.6.0.md), model provenance and
  validation receipts included. SDK/assets release only; no app shipment.

## 0.5.0 — 2026-11-09

- **Original-only voices read Original instead of failing.** Only Bill Boerst,
  Caro Davy, Peter Yearsley and Stuart Bell have delivery styles; the other 19
  Max voices are Original only. `PocketTTSBookDelivery.style(for:)` and
  `applying(to:)` now resolve each unit's style against the voice that speaks
  it, so a book saved with Calm (narrator or character) on an Original-only
  voice plans and renders in Original rather than throwing `unsupportedVoice`.
  New `PocketTTSDeliveryCatalog.offersStyles(voiceID:)` and
  `resolvedStyle(_:voiceID:)`. Explicit single-style APIs
  (`manifest(voiceID:style:)`, engine `deliveryStyle:`) still reject them.
- **Breaking:** the preview status is removed —
  `PocketTTSDeliveryStyle.isPreview` and
  `PocketTTSDeliveryCatalog.isPreview(voiceID:style:)` no longer exist. Every
  published style is a regular choice.
- Model bytes, manifests and cache identities are unchanged.

## 0.4.2 — 2026-11-09

- Per-language Max uninstall. `NarrationAssets.uninstallPocketLanguage(_:in:)`
  removes one language's base pack, voices and delivery styles (`<language>/`)
  and returns the bytes freed; other languages and host receipts are untouched,
  and a second call frees 0. `NarrationRenderer.uninstallPocketLanguage(_:in:)`
  does the same serialized with rendering and releases that language's model
  first if it is loaded. Also `installedPocketBytes(language:in:)`,
  `installedPocketLanguages(in:)`, `NarrationRenderer.loadedPocketLanguage` and
  `PocketTTSEngine.loadedLanguage`. Model bytes and cache identities are unchanged.

## 0.4.1 — 2026-11-09

- Host-selectable CPU budget for background Max renders:
  `NarrationRenderer.setCPUBudget(fraction:)` /
  `PocketTTSEngine.setCPUBudgetFraction(_:)`. `nil` is unmetered (for a
  charging `BGProcessingTask`, where iOS lifts CPU limits); other values are a
  fraction of one core clamped to 0.1…0.8. The default stays 0.5 for every
  caller that doesn't opt in. Model bytes, sampling and cache identities are
  unchanged.

## 0.4.0 — 2026-11-08

- Stable Max tier using native Swift MLX Pocket TTS alongside Basic and Plus.
- Seven optional language packs, 23 Original voices, verified hosted assets.
- New-book default: accepted English Caro Davy / Calm configuration, Careful
  reading, temperature 0.3, four sampler steps; saved choices remain unchanged.
- 364 optional delivery states with per-book narrator/per-character routing,
  individual downloads, credits and style-aware cache identities. Other
  performances and languages remain listening previews.
- Foreground GPU, granted iOS 26+ background GPU, iOS 18+ CPU fallback, measured
  realtime quality policy and resource/cancellation recovery.
- Full [app integration prompt](docs/UPGRADE-0.4.0.md), download manifest index
  and 117 audition clips. SDK release only; app/device acceptance is separate.

## 0.2.1 — 2026-11-06

- Add the Spanish regional selection API used by the app: explicit Argentina
  profile, BCP-47 region parsing, and stable language tags. Existing Spain and
  Latin America defaults are unchanged; this does not import the separate
  multilingual lexicon experiment.
- Core ML model bytes, download revision and cache identities are unchanged.

## 0.2.0 — 2026-11-06

- Promote CT F1 Core ML v2 to the official Plus runtime, with English/Spanish
  text-native planning, GPU foreground execution and explicit CPU fallback policy.
- Publish separately downloadable, pinned model assets with SHA-256 verification,
  retry/repair, installation compilation, provenance and full model license notices.
- Expose `NarrationAssets`, `NarrationRenderer`, `NarrationModel`, and the native
  `LibroxCTNative` product; preserve existing Kokoro defaults and persisted selections.
- Add bounded narration profiles/delivery APIs needed by the reader integration.
- Require iOS/Catalyst 18 and macOS 15. The v0.1.0 module was `KokoroKit`;
  consumers of this release import `LibroxTTS`.
- Keep model weights out of Git and retain zero remote Swift dependencies.

This is an SDK/model release. It does not release the Librox app or certify
full-reader cached startup, sustained thermal behavior or lock-screen playback.
