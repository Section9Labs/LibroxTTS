# Changelog

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
