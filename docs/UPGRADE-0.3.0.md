# Upgrade Librox to LibroxTTS 0.3.0

Pin `.package(url: "https://github.com/Section9Labs/LibroxTTS.git", exact: "0.3.0")`. Import `LibroxTTS`; keep the app's existing `KokoroNarration`, `KokoroCatalog` and other product imports where used. Resolve every package graph, including the app, LibrosKit and Validation/CT, to the release revision. Update the dependency-pin checker too.

## Runtime release versus model download

This release updates planning, delivery and inference. It does **not** change the accepted CT F1 weights or model asset bytes. The model identity stays `librox-plus-ct-f1-coremlgpu-v2`, the public asset release stays `plus-coreml-v2-2026-11-06`, and the SDK manifest describes 23 files / 439,248,281 bytes. Existing verified v2 installations need no network redownload. New installations and migrations from ONNX/v1 use `NarrationAssets.manifest(.plus)` and its pinned public URLs. No GitHub credentials are required. Model licensing and required notices remain unchanged.

Treat SDK version, model-asset identity and prepared-audio identity separately:

- If the installed identity and pinned file hashes match, keep the weights. Validate off the main actor. Prepare local compiler/specialization caches with `NarrationAssets.prepare(directory, model: .plus)` when needed, while no renderer uses the directory. Serialize this with playback and do not repeat it on every Play. A one-time app preparation receipt can track the runtime preparation revision independently of downloaded weights; retain lazy engine preparation if this optional warm-up has not run.
- If the pinned model identity/revision changes in a future SDK, show an Update action and actual manifest download size. Keep the old working installation until the new version finishes staging, hash validation, local preparation and atomic receipt publication. Preserve progress, voice and language settings. Switch active renderers only at a safe stop/session boundary. Failed or cancelled updates must not destroy the working version. This is integration guidance, not a claim that an out-of-band model catalog/update UI already exists.
- If no compatible model exists, show Download. Use the existing process-surviving URLSession downloader, per-attempt staging, verified retry and corruption repair. Keep asset bytes out of the app bundle and source Git history. Do not fetch a mutable latest manifest as trusted executable-model metadata; the app SDK pins the trusted manifest.
- Regenerate prepared PCM when pipeline/model/voice/language/delivery/source identity changes. Preserve library data, reading positions and user settings. Do not wipe or re-download model assets to invalidate audio caches.

## Required app behavior

Use the single `NarrationPipeline` for playback, book preparation and voice previews. Pass the same resolved `NarrationDeliveryOptions` to preparation and playback. Plus does not support character voices, so a retained Basic cast setting must not suppress its book preparation. Keep bounded opening/resume disk reserves and play cached PCM while later units render.

**Plus output is mono Float32 at 44,100 Hz in this release**, not the 24,000 Hz in the original 0.2.x app handoff. Use `model.outputSampleRate`; Kokoro remains 24,000 Hz. Preserve paragraph context, fixed F1 gain and time-pitch bypass at 1x. Do not apply independent per-passage peak normalization. Foreground heavy graphs use GPU; cancel/retire foreground inference before switching to CPU background inference. No Neural Engine placement is promised.

Automatic language selection and all 31 Plus languages come from the SDK catalog/planner; retain explicitly saved expression settings. Shared written-to-spoken readings apply across adapters; Kokoro's full phoneme dictionaries are not passed to CT as IPA. Preserve the app's shared voice-card/list/waveform flow and short model-terms link.

## App commits and integration

App PR: https://github.com/mrbrutti/Libros/pull/162, branch `codex/unified-narration-app`, reviewed head `d2bc088eeb9ec1628e49e17180ba68deb9b12b1b`, base `eed4724f8984cb1a58d1101994bc3e0792dc4d2e`.

Production changes are `c0dc609e8` (shared pipeline, Automatic/catalog language UI, native rate and cache identities), `5798fb781` (paragraph-safe SDK pin/checks), and `f1f64adda` (bounded-runtime pin, preparation delivery/cache fix and retained-cast guard). Remaining commits document listening/device results. Prefer reconciling the complete PR; these commit IDs identify the functional changes, not a substitute for checking dependencies. Replace its tested SDK revision pin `1846e343dc271fc8bd1912a96a1bd54da62ce675` with exact 0.3.0 and resolve all graphs. The release adds documentation to the tested runtime source.

The T3 integration branch has separate UI work `149c4514`. Preserve its shared voice card, voice list, waveform previews, Librox Plus naming and short terms link when resolving overlap in ListeningSettingsView/ListeningVoicePreview. Do not overwrite those with an older screen. The release owner reserves the combined distribution build; local 242.7 is only a review identifier.

## Validation and remaining scope

409 SDK tests, ten CPU/GPU window comparisons (sample-identical), both-device fixed-noise full-engine comparisons, 372 Reader tests and the exact-SDK iOS Release build passed. Separate signed full-app tests passed download, cache startup, dormancy, seek/rate/chapter/stop, Automatic Spanish, installer recovery and SIGKILL/silent relaunch. Prepared start measured 0.470 s iPhone / 0.556 s iPad. Native sampled peak footprint reduced from about 1.56 GB to 670 / 772 MB; these are distinct from resident memory. Initial sustained runs included over ten minutes of background samples with no recorded underruns and nominal thermal state; their chapter transitions preceded backgrounding.

Matt accepted the improved Electric Dreams excerpt and native iPhone comparison and reported physical controls worked on both devices. On 6 November 2026 he authorized library release and deferred the remaining dedicated device checks to TestFlight. This is not a fabricated pass for the stricter locked chapter transition or individual AirPods/call checks. Native menu/accessibility and broader language listening remain feedback items. Review-host StoreKit/CloudKit/app-group/extensions were isolated, so the app owner still validates the combined release. App GitHub checks were prevented from starting by account billing limits; local checks passed. No app archive/upload is performed by this SDK release.
