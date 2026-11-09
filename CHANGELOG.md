# Changelog

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
