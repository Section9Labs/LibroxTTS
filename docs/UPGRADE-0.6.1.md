# Librox app implementation prompt — LibroxTTS 0.6.1

Integrate LibroxTTS **0.6.1** SDK into the existing Librox app.
Preserve concurrent app work and all saved books, reading positions, voice/cast
choices, delivery styles, sampling and phrasing settings. Implement and verify
the app changes; do not treat a package-version edit as completed integration.
This prompt authorizes implementation and local/device validation, not a
TestFlight/App Store upload.

```swift
.package(url: "https://github.com/Section9Labs/LibroxTTS.git", exact: "0.6.1")
```

Update every package declaration and resolved dependency, including app, shared
libraries, extensions and XcodeGen inputs. Continue importing `LibroxTTS`.
Requirements remain Swift 6.3+, iOS/Mac Catalyst 18+, macOS 15+.
The release preserves the 0.4.1 CPU-budget, 0.4.2 language-uninstall and 0.5.0
style APIs; do not regress them when replacing an older SDK pin.

## Required platform routing

Use `NarrationRenderer` for app Max generation. It now selects:

- iPhone/iPad: **Core ML CPU**, in foreground and background contexts.
- Native Mac and Mac Catalyst: **MLX**, retaining existing CPU/GPU routing.

The SDK owns this decision through `PocketTTSBackend.platform`. Remove any app
path that directly creates `PocketTTSEngine` on iPhone/iPad. Do not offer a
second backend/model download on iOS, add an MLX fallback, or switch backend
according to screen lock state. Keep System, Basic, Plus and Max distinct;
Max remains `.pocket` / `pocketTTSV1`.

Core ML still links MLX code for the unchanged tokenizer/configuration, CPU
noise and safetensors voice-state reading. That does **not** require the MLX
acoustic checkpoint. Do not mistake a linked framework or voice-state file for
a requirement to download `model.safetensors`.

## Exact Max quality

This is the same pinned Kyutai model, converted to a different execution format.
There is no retraining, new quantization, model substitution or quality upgrade.
For new Max books, use and persist all fields from
`PocketTTSNarratorPreset.defaultNarrator(language:)`:

- Caro Davy / Calm;
- temperature 0.3;
- four sampler steps;
- `PocketTTSChunkingOptions.carefulReading`.

Preserve saved choices. Sampler steps 1–8 remain supported. Do not introduce
automatic step reduction, new variation/temperature defaults, changed voice
states, DSP, resampling, phonemization or delivery heuristics for this migration.
Retain 24 kHz mono output and the SDK's chunk continuation, warm-up and EOS rules.
Keep audition, live playback, chapter preparation and export on the same planned
unit/settings path. Scheduling/CPU pacing must not change synthesis settings.

Retain the 0.5.0 style behavior: use `offersStyles(voiceID:)`,
`publishedStyles(voiceID:)` and `resolvedStyle(_:voiceID:)`. The four styled
narrators are Bill Boerst, Caro Davy, Peter Yearsley and Stuart Bell; the other
19 voices are Original-only. Keep saved style preferences, while the SDK resolves
an Original-only speaker to Original. Explicit unsupported-style APIs still
fail. Do not restore the removed `isPreview` APIs or preview badges.

## One backend per language and device

Use SDK manifest APIs, never a hard-coded model filename, old release URL, size,
or repository ID:

- `NarrationAssets.repositoryID(.pocket)`;
- `NarrationAssets.manifest(.pocket, language:)` for a base-only pack;
- `NarrationAssets.manifestPocketNarratorPreset(language:)` for a new-book default;
- `PocketTTSDeliveryCatalog.narratorManifest(voiceID:style:)` for a selected
  existing narrator plus its resolved style;
- `PocketTTSDeliveryCatalog.manifest(voiceID:style:)` for optional individual
  style downloads after the base is installed.

The identities are intentionally different:

| Device | Acoustic assets |
| --- | --- |
| iPhone/iPad | `pocket-tts-coreml-2026-11-10-v1` |
| Mac/Catalyst | `pocket-tts-mlx-2026-11-07-v2` |
| Shared delivery states | `pocket-delivery-voicezero-490cfbee-v1` |

Offer English, French, German, Portuguese, Italian, Spanish and Dutch
independently. Do not download all languages/styles by default. Each language
retains 23 original voices and 52 optional styled states (13 styles × 4 voices).
Their tokenizers, original/delivery voice states and credits retain the exact
existing hashes and hosted URLs. Only the acoustic model format changes on iOS.

Core ML source packages are about 779 MB per language plus about 141 MB of
shared assets; the English base download is approximately 919 MB decimal, before
an optional Calm state. The existing MLX pack is about 360 MB. Derive displayed
sizes from the selected manifest. Account for compilation and staging storage;
never imply that one backend guarantees a smaller download.

For foreground installs, use the SDK download helpers. For background URLSession
transfers, download the selected manifest's files into private staging, validate
all hashes, then call the matching SDK preparation API off the main actor:
`preparePocketNarratorPreset(in:language:)`, `preparePocketDeliveryStyle`, or
`prepare(_:model:repositoryID:language:)` as appropriate.

Core ML `.mlpackage` files must compile **on the destination device**. Use SDK
preparation; do not distribute a Mac's `.mlmodelc` cache, skip compilation, delete
source packages, or mark an installation ready merely because downloads ended.
`isPrepared` requires the compiled receipt. The receipt is tied to the manifest
and OS, so an OS update may require preparation again. Preparation also applies
the file protection needed for narration after the screen locks.

## Migrate existing iPhone downloads safely

1. Use the new SDK repository identity to select a separate destination. Treat
   the old MLX identity from `previousRepositoryIDs(.pocket)` only as a reuse
   source, never as a compatible Core ML playback installation.
2. Keep old receipts, files and active playback intact while creating private
   staging. Call `reuseVerifiedFiles(manifest:from:into:)` with the new complete
   manifest. It reuses only bytes with matching hashes, including eligible shared
   voice/tokenizer/style files; it never copies the old acoustic checkpoint.
3. Download only missing files, compile/prepare, and verify readiness for that
   language and the requested style. An unavailable/missing selected style needs
   a repair/download action, not a replacement with Calm or another voice.
4. Cancel and await affected generation, unload the old renderer, then atomically
   adopt the new installation and persist its new repository/preparation receipt.
   Retain book settings and reading position.
5. Retire the old language's MLX files only after successful adoption and after
   verifying the required voice/style states were retained. Preserve other
   languages still awaiting migration; do not delete an entire shared old root
   when only one language has migrated. A failed download/compile must leave the
   prior installation recoverable and must not trigger automatic destructive retry.

Mac installs keep their existing MLX acoustic files. Do not force a Mac model
redownload because the SDK version changed. Preserve the per-language storage
UI and `installedPocketLanguages`, `installedPocketBytes` and serialized
`NarrationRenderer.uninstallPocketLanguage(_:in:)`; Core ML preparation artifacts
live under the same language folder and must be removed with that language.

## Prepared audio and lifecycle

Use `NarrationAssets.preparationIdentity` for installation preparation and
`NarrationModel.pocket.renderIdentity(for:)` for generated-audio cache keys.
Core ML and MLX output must not share an implicit cache identity. Include voice,
language, source/spoken text, resolved style, actual sampler settings, chunking
and backend runtime identity. Invalidate incompatible pending/prepared work
without deleting user exports, books or positions. Synchronizing settings across
devices does not mean copying prepared model caches between backends.

For iOS Max, use `.foreground` while active and `.background` during an existing
permitted background job. Do not require a GPU grant or entitlement for Max's
CPU path, or gate Max playback on iOS 26 background-GPU availability. Do not
remove grants/entitlements still needed by Plus or other features.

Preserve the real spoken-audio session, queued audio, remote commands, reading
position, pause/seek/cancel/account-switch handling and interruption recovery.
Core ML does not grant unlimited background runtime. Do not use silent audio
keepalive or present silent whole-book preparation as proven unlimited work.
Scheduled/background processing remains a separate host lifecycle contract.

For live Max playback, use **full-speed generation with a bounded playback
buffer** in both foreground and background. iOS Core ML now defaults to no
library-inserted CPU delays; MLX retains its existing behavior. Remove a host's
inherited unconditional `setCPUBudget(fraction: 0.5)` for iOS Max live playback:
that cap made the earlier candidate slower than consumption. If a renderer has
an old explicit budget, call `await renderer.setCPUBudget(fraction: nil)` once
when entering this live playback policy. This does not change model settings.

Use `NarrationRenderer.renderPocketFrames(_:receive:)` for live Max audio.
It emits the existing 24 kHz mono frames without splitting/replanning the unit
or resetting its continuation state. Queue frames progressively so a long
paragraph can start playing before its entire render completes. Keep `render`
for complete-unit preparation/export where progressive playback is unnecessary.

The frame consumer is synchronous, throwing and runs on the engine actor. Apply
**bounded, cancellable backpressure** in the app-owned audio queue: when it is
full, wait for playback to consume audio before accepting more. Wake a waiting
producer on progress, pause, seek, interruption, cancellation and account/book
changes. Check task cancellation at least every 50 ms while waiting. Never block
the main actor or audio render callback; do not spawn an unbounded Task per frame
or use a dropping AsyncStream buffer. Account for accepted frames before returning
from the callback. A partial/cancelled stream is not a complete prepared unit.

Use `NarrationPlaybackBufferPolicy` under the same synchronization as the queue
to decide when the producer fills or waits. For whole-unit producers, check it
before each unit; for streaming, check between frames:

```swift
var bufferPolicy = NarrationPlaybackBufferPolicy()
// Read the actual queue state under the producer/consumer synchronization:
let needsAudio = bufferPolicy.shouldGenerate(
    bufferedAudioSeconds: queuedAudioSeconds,
    playbackRate: selectedPlaybackRate,
    playbackRequested: wantsPlayback,
    hasPendingUnits: hasMoreUnits || isRenderingUnit)
// Accept/generate audio only when needsAudio is true.
// Otherwise wait for player progress/state changes, without a busy loop.
```

The policy fills to approximately 30 seconds of listening time, then waits until
12 seconds remain before refilling. With streaming, overshoot is limited to in-flight frames. A whole unit may
overshoot the target substantially and take longer than the reserve to render;
do not shorten chunks, trim speech or lower sampling steps to hit it exactly.
Measure only audio still queued ahead of the playhead, not total generated or
cached audio. Playback rate is accounted for, but faster rates require higher
sustained throughput and must be measured on the actual device.

Do not rely on whole-unit buffering for arbitrarily long paragraphs. Keep only
one generation task active. Use this same scheduling rule while the
app is foreground or background. Cancel and await in-flight generation when
playback is paused/cancelled or the user seeks, changes books, voices or accounts;
reject stale completions before enqueueing. Call `bufferPolicy.reset()` after
replacing the queue. A false decision does not itself cancel a render. Initial
buffering counts as playback requested even before the player starts audibly.
Do not keep generating a whole book after the playback queue is full.

Explicit `setCPUBudget(fraction:)` remains available for separately managed
preparation jobs. A number limits process CPU time as a fraction of one core,
not the whole device; `nil` removes only the SDK's delays. Neither mode exempts
the app from iOS resource limits or grants background time. Whole-book preparation
must retain its own permitted lifecycle; never run it indefinitely behind a
spoken-audio session. Don't apply the live buffer policy to an export that has no
player; retain cancellation and the proper foreground/processing-task context.

Retain fixed quality if throughput falls behind. Record actual render duration,
audio duration, remaining buffer, playback rate and thermal state. Surface an
honest buffering state if needed; never conceal a performance deficit with fewer
sampler steps. This policy is separate from `PocketTTSRealtimeBudget`, which can
reduce sampler steps and must not be introduced for the exact-Max migration.

On memory/thermal errors, preserve position, stop/unload and offer a later resume.
Cancellation stays cancellation. Do not immediately restart an expensive failed
operation, delete its downloads, switch tier/backend or reduce quality.

## Verify before declaring app integration complete

- Build iPhone, iPad, native Mac/Catalyst targets and relevant extensions; confirm
  exact 0.6.1 resolution in every graph.
- Verify real public downloads and repair, selected styles, per-language receipts,
  compilation, disk-space errors and interrupted installation recovery.
- Migrate an existing iPhone MLX installation; prove the adopted pack has no
  acoustic `model.safetensors`, and only retire that old language after adoption.
  Verify Mac retains MLX and its existing download.
- Exercise per-language uninstall/reinstall with Core ML loaded; preserve other
  languages and host receipts.
- Confirm default Caro/Calm/.3/four-step/Careful-reading and saved custom settings
  remain identical across audition, reader playback, preparation and export.
- Check all seven language choices and the four styled narrators; Original-only
  voices must retain the existing 0.5.0 behavior.
- On a physical iPhone, test Play → Home → lock/unlock, long narration with the
  app's bounded playback buffer, pause/seek/resume, interruptions, model/book
  switches and cancellation. Verify memory and thermal recovery. Do not infer
  production endurance or battery life from a short probe.
- Check prepared-audio cache migration and cross-device settings synchronization.
- Retain Kyutai/voice-source attribution, `VOICE-CREDITS.json`, delivery credits
  and licenses. Basic/Plus behavior is outside this backend change.

Report changed app files, package pins, checks actually run, device outcomes and
remaining blockers. Do not claim TestFlight/App Store shipment without an
explicit app release task.

The SDK's physical iPhone 17 Pro Max probe completed ten minutes of locked
1× playback with no underruns, 4.82× median / 3.33× minimum generation throughput
and normal thermals. Warm foreground runs were 3.64–4.27×. The probe used complete
units and explicit nil pacing; the new progressive facade and reusable policy
were tested separately. This is evidence for the engine/scheduling choice, not
acceptance of the Librox reader on every device or playback speed.

SDK receipts and implementation details:
[bounded playback evidence](../Integrations/PocketTTS/Validation/CoreML/BUFFERED-PLAYBACK.md),
[Core ML validation](../Integrations/PocketTTS/Validation/CoreML/README.md),
[asset separation](../Integrations/PocketTTS/Validation/CoreML/ASSET-SEPARATION.md),
[physical installation](../Integrations/PocketTTS/Validation/CoreML/installation-device-2026-11-10.json).
