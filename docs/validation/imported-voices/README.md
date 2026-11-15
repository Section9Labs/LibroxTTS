# Imported Max voices

Implementation is isolated on `codex/max-imported-voices`, based on v1.1.0. No released tag, hosted asset, built-in catalog, or app is modified by this work.

A `.libroxvoice` file is a safetensors file with a `librox.voice` JSON metadata entry. `PocketTTSImportedVoice.package(state:metadata:)` wraps an upstream model-specific voice state without altering its tensor payload. The metadata declares version, display name, language, model identity, model SHA-256, and attribution. Import does not generate a clone from audio.

`PocketTTSVoiceStore` validates and atomically copies packages into an app-owned directory. Validation bounds file/header/frame sizes, verifies all six F32 attention-cache pairs and I64 offsets, transposes frame-major states into backend cache order, rejects nonfinite numbers, overlapping/trailing ranges, extra tensors, mismatched offsets and model contracts. Raw archives are not handed to either inference backend. Stable IDs use URL-safe base64 of the full package SHA-256 to fit the existing 64-byte cast contract; stored filenames use its hexadecimal form. Removing or changing a selected file causes an error at rendering; no preset substitution is permitted.

Both native engines and the unified narration renderer accept an immutable descriptor snapshot. Planning, narrator selection, character catalogs/casts and Original-delivery resolution use that same explicit snapshot. Existing calls default to an empty custom catalog. New imports require rebuilding the host's renderer with the updated snapshot.

## Reproduce

Build `swift build -c release --product pocket-voice-probe`.

Create a package with:

```
pocket-voice-probe package STATE.safetensors Victoria es Victoria.libroxvoice ATTRIBUTION
```

Render with `pocket-voice-probe render request.json`. Request fields: `package`, `store`, `assets`, `output`, `text`, `backend` (`renderer`, `renderer-stream`, `mlx`, or `coreml`), optional `models` directory, `seed`, and `chunking` (`PocketTTSChunkingOptions`). Set `POCKET_METALLIB` to the build's `default.metallib` when needed. The tool imports, reopens the store, plans with the persisted ID, renders, and writes a WAV plus JSON receipt. `renderer` uses production platform routing and does not expose deterministic seed control.

Private test material and Victoria's `.libroxvoice` remain outside git in `/Users/matt/Documents/Codex/2026-11-15/llevara-pocket-voice/victoria`. The source is the user's accepted Libro.fm reference clone (Spanish Neus Sendra narration, 26.38–35.13 seconds of the preview), locally renamed Victoria. This is synthesized speech, not a new recording by the original narrator.

See `docs/IMPORTED-VOICES-LIBROX-HANDOFF.md` for the app implementation prompt. App UI integration and physical-device end-to-end acceptance remain separate work.

## Automated checks

`swift test -c release --filter 'Pocket|TextNative|NarrationPipeline|BookVoiceCast'` passed: XCTest reported 59 tests, including 22 opt-in skips, and Swift Testing reported a successful 64-test run (19 opt-in skips). All six new imported-voice tests ran and passed. They cover import/reopen/deduplication/removal, exact cache transposition, corruption and repair, bounded malformed inputs, narrator and character planning, cast persistence, duplicate catalog entries, incompatible languages, missing selection, and both backends' unsupported-style errors.

The final implementation also clears cached Foundation URL resource values before checking an imported file: reusing the same import URL after replacing a file must inspect its current size.

## Native smoke evidence

The supplied Victoria package is 5,458,152 bytes, with 111 reference frames. Its tensor payload exactly matches the accepted source clone. Package SHA-256: `d07f4c620a0732a9e16155e53baa3c03ecd4938a4a04cb06869e1efa03fcc7fa`.

After import, a fresh store instance reloaded the descriptor, the public narration pipeline planned the passage using its stable ID, and each native path rendered it:

| macOS path | Audio duration | Independent ASR content check |
| --- | ---: | --- |
| MLX GPU | 29.68 s | All intended words matched |
| Core ML CPU | 28.32 s | All intended words matched |
| NarrationRenderer streaming (MLX) | 29.36 s | All intended words matched |

All samples are finite 24 kHz mono audio with peaks below 1. No denoising, post hoc sentence splicing, or substituted stock voice was used. See `native-smoke.json`. Automated transcript comparison normalizes accents/case/punctuation; it does not establish perceived voice similarity, prosody, or naturalness.

The initial default 48-token grouping omitted a sentence on both native engines. These passing auditions explicitly use narration/dialogue targets 32, maximum 32, and short-sentence grouping 0, with temperature 0.3 and four steps. The engine demonstrations use seed 42; the facade uses its normal random seed. This profile is included in the app handoff for the initial Victoria preview/test book. No global SDK phrasing settings were changed. Initial outputs/checks remain in the private `default-phrasing` subdirectory for comparison.

The SDK, package and local audio are ready for app integration. No Librox UI, physical iPhone run, App Store/TestFlight build, SDK release tag, or remote publication was performed.
