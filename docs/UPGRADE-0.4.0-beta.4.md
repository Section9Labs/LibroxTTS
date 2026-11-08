# Upgrade to LibroxTTS 0.4.0-beta.4 — Max

Pin exact `0.4.0-beta.4` throughout the app, LibrosKit and resolved package graphs.
The SDK now presents Pocket TTS as **Max**, the additional narration tier above
Plus, and offers it on supported iPhones, iPads and Apple silicon Macs. Matt will
perform physical-device acceptance through TestFlight. Availability is no longer
blocked by the temporary desktop qualification gate.

## What changes

- `NarrationModel.pocket.name` is `Max`; model enumeration places it after Plus.
- Max has no tested-device/model-number or physical-memory allowlist. The existing
  Apple silicon requirement remains; this change does not add Intel execution.
- `NarrationAssets.supportedNativeStyles(repositoryID:)` recognizes the Max pack
  and returns all 23 retained presets, fixing Plus-style host filters that would
  otherwise hide them. Previous Plus F1 and current Plus banks are preserved.
- User-facing renderer/runtime errors use the Max name.

## Stable compatibility

The enum case remains `.pocket`, persisted raw value `pocketTTSV1`. Plus remains
`.plus` / `ctPlusV1`. Voice IDs, model weights, language manifests, runtime and
prepared-audio identities are unchanged. Existing valid v2 downloads and compatible
cached audio remain reusable; the rename alone requires no redownload or render.
This adds no billing product and retains `requiresPlusAccess` for Max.

Requirements remain Swift 6.3+, MLX Swift 0.32.3, iOS/Catalyst 18+ and macOS 15+.
The seven language packs remain hosted in the
[v2 asset release](https://github.com/Section9Labs/LibroxTTS/releases/tag/pocket-tts-mlx-2026-11-07-v2).
Use the language parameter consistently for manifest, download, prepare and
isPrepared; omitting it addresses all seven packs.

## App integration still required

Keep the quality/model → compatible voice → options/download flow. Show Max in
addition to Plus; never rewrite an existing user's model selection.

Forward the same `PocketTTSSamplingOptions` and `PocketTTSChunkingOptions` from
saved profiles through previews, preparation, playback and exports. The SDK's
sampling default remains four steps; explicitly use
`PocketTTSSamplingOptions(temperature: 0.3, samplerSteps: 8)` for the app's new
higher-compute Max profile. Keep four/eight comparisons available and make any
one/two-step device fallback explicit. More computation is not a universal
listening-quality guarantee. Retain the existing 48/32 narration/dialogue token
targets unless the user selects another phrasing profile.

Include `model.renderIdentity(for: unit)` in cache identity. Persist casts under
separate model catalog scopes: an app that currently maps all text-native models
to `voice-catalog:plus` must give Max a separate namespace while preserving old
Plus casts. Persist per-language install receipts without deleting other packs.

Max produces 24 kHz mono PCM. Use `model.outputSampleRate` in playback/export.
Use spoken dictionary readings and source/character planning. Do not apply
Kokoro phonemization/dialect controls, Kokoro expressive DSP, Plus/DK native
expression tensors, voice blending, SSML or emotion prompts. Optional natural
pauses belong to the shared playback cadence, applied once and reset on seeks.
The [full integration guide](../Integrations/PocketTTS/README.md) describes the
planning, chunking and sampling contracts.

## Foreground generation remains required

`NarrationRenderer.load` defaults to `.background`; callers must explicitly pass
`.foreground` for Max. The SDK still rejects background GPU generation. Removing
a device eligibility gate does not change OS GPU lifecycle permissions.

The host must observe lifecycle changes after loading, cancel/retire in-flight
and queued generation when necessary, discard incomplete units, and continue
playing already prepared audio where available. It must not apply Plus's CPU
background retry to Max. Preserve pause, seek, account/book-switch and position
semantics. Actual load, memory or generation failures must produce clear recovery
without silently changing the selected model or quality.

## Credits and acceptance

Display: “Max uses Pocket TTS by Kyutai. Model and voice credits.” Link to an
acknowledgements screen using `KokoroAttribution.text` and the installed
`VOICE-CREDITS.json`. Preserve the full notices. Upstream code is MIT; weights
are CC BY 4.0; retained recording sources are CC BY 4.0 or CC0. See the
[voice inventory](../Integrations/PocketTTS/VOICE-LICENSES.md).

This SDK release enables the app integration; it does not publish the app or
certify sustained narration on every device. TestFlight checks should cover cold
download/first render, eight-step long reading, alternate languages, character
turns, settings/cache changes, pause/seek/resume, lock/unlock, prepared background
playback, memory and thermal behavior. Existing Mac listening/parity evidence
remains applicable to the unchanged acoustic runtime, but is not iPhone evidence.
