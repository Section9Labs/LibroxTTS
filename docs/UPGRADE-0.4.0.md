# Upgrade to LibroxTTS 0.4.0 — stable SDK and Max narration

Keep Max, Plus and Basic separate. This update adds optional reference-based
preview styles for Bill Boerst, Caro Davy, Peter Yearsley and Stuart Bell in the
seven existing Max languages. The original 23 voices and base asset pack stay
unchanged. For new Max books, the default narrator is **Caro Davy / Calm**, with
**Careful reading**, temperature **0.3** and **4 sampler steps**, matching the
English book scene accepted by Matt. Preserve all saved book/voice/settings
choices. Other performances and non-English delivery remain listening previews;
these are reference performances, not native emotion-intensity controls.

Use this as the app-session implementation prompt. Update every package graph and
resolved dependency to exact **0.4.0**, retain `import LibroxTTS`, and preserve
concurrent app work. Swift 6.3+, iOS/Catalyst 18+ and macOS 15+ are required.
Keep System, Basic, Plus and Max separate; Max is `.pocket` / `pocketTTSV1`.
This is the SDK release; the app session owns app integration and TestFlight.

```swift
.package(url: "https://github.com/Section9Labs/LibroxTTS.git", exact: "0.4.0")
```

Use the [complete delivery integration](MAX-DELIVERY-STYLES.md). Required app work:

1. Initialize new books with `PocketTTSNarratorPreset.defaultNarrator(language:)`
   and persist its `voiceID`, `delivery`, `chunking` and `sampling`. A pipeline call
   with no narrator or cast uses this default; a supplied voice/cast preserves
   legacy settings unless you explicitly pass the preset fields. Install with
   `NarrationAssets.downloadPocketNarratorPreset(to:language:)`. For background
   downloads use `manifestPocketNarratorPreset(language:)` and
   `preparePocketNarratorPreset(in:language:)`. This includes the base model,
   Calm reference and credits. Do not silently fall back to Original.
2. Show **Delivery** beside a compatible Max voice. Obtain choices from
   `PocketTTSDeliveryCatalog.publishedStyles(voiceID:)`; use `PocketTTSDeliveryCatalog.isPreview(voiceID:style:)` to label
   previews. English Caro/Calm is the accepted default; style-only `isPreview`
   deliberately remains conservative. Do not enumerate all enum cases as available downloads.
3. Download just the selected style with
   `NarrationAssets.downloadPocketDeliveryStyle(_:voiceID:to:)`. Show its
   `PocketTTSDeliveryCatalog.manifest(voiceID:style:).downloadSize` and retain the
   supplied credits. Use the same model directory as the base language pack.
4. Persist `PocketTTSBookDelivery` with the book. Its narrator style applies to
   prose; optional `characterStyles` are keyed by stable cast speaker IDs.
   Unassigned dialogue stays Original. Validate styles again after a voice change.
5. Pass `pocketDelivery` to `NarrationPipeline.plan`. Use this plan for live
   reading, chapter preparation, export and audition. Preserve source ranges.
6. Include `PocketTTSBookDelivery.cacheIdentity` in chapter-plan identity and
   `NarrationModel.pocket.renderIdentity(for:)` in unit audio keys. Retire pending
   generation when settings change. Never reuse Original audio for a preview.
7. Keep temperature labeled Variation, separate from the reference style. Retain
   quality-first sampler settings, measured fallback policy and the
   background GPU authorization, CPU fallback and resource recovery below.
   Use `PocketTTSChunkingOptions.carefulReading` for new books and offer it as
   **Careful reading** in Phrasing; preserve existing saved chunk settings.
8. Surface unsupported/missing-style errors. Do not silently substitute a voice,
   language, style or model. Do not automatically guess emotions sentence by sentence.

Hosts can override `unit.pocketDeliveryStyle` for a complete planned passage.
Style changes start from the selected reference; continuation within a unit
retains the same reference. This update does not add cross-unit acoustic memory,
state blending, or emotion intensity sliders.

See the integration document for settings attribution text and audition guidance.
No Librox app build or TestFlight upload is included in this SDK release.


## Downloads and cache migration

The SDK and model packs have separate identities. Keep the immutable hosted
`pocket-tts-mlx-2026-11-07-v2` base packs and
`pocket-delivery-voicezero-490cfbee-v1` delivery pack. Do not rewrite their URLs,
rename weights or force a model redownload solely for this SDK version. Both
are hosted by Section9Labs/LibroxTTS on GitHub, with per-file SHA-256 checks.
The stable release includes `librox-tts-0.4.0-downloads.json`, mapping every Max
language to its base, default-narrator and optional-delivery manifests. Use SDK
manifest APIs as the application contract; that index is an integration receipt.

Offer English, French, German, Portuguese, Italian, Spanish and Dutch separately.
Pass the same language to manifest/download/prepare/isPrepared and maintain
independent receipts. Base packs keep all 23 Original voices. Only the selected
reference performance is needed in addition to the base pack. Background
URLSession downloads must run the matching SDK preparation method afterwards.
A base-only receipt does not establish that Calm is installed. Missing or corrupt
states must produce a download/repair action, never a silent voice substitution.

Preserve saved sampling, phrasing, voices and casts. For a new book, persist the
resolved default preset before playback. Keep a separate Max cast namespace and
use `NarrationModel.pocket.expandingVoiceCatalog(in:)` for verified metadata;
unknown-gender voices remain manually selectable. Preserve explicit assignments.
Store settings on each unit before cache lookup. Cache identity includes model,
voice, language, source/spoken text, delivery, actual sampling and chunking.
Invalidate affected pending/prepared audio after a setting change; do not reuse
Original audio for Calm or four-step audio for an eight-step request.

## Background playback and preparation

Keep iOS 18 support. Use GPU in the foreground and prefer a real iOS 26+
continued-processing GPU grant in the background. Otherwise select `.background`
for CPU during the existing active spoken-audio session. Mac window focus is not
an iOS background restriction. Remove Max-only foreground gates and mandatory
whole-chapter preparation: Max supports streaming and background generation.

For iOS 26+, enable Background GPU Access on the explicit App ID, regenerate
profiles and verify the signed app. Set
`com.apple.developer.background-tasks.continued-processing.gpu` to true. Add a
bundle-prefixed wildcard to `BGTaskSchedulerPermittedIdentifiers` and enable
Background Modes audio/processing. Request `NarrationBackgroundGPUGrant` from a
foreground Play/Prepare action using a fresh matching UUID task identifier. A
supported device or successful submission is not a grant: wait for launch.

Retain the grant with its serial user-started job. Wrap both `.backgroundGPU`
load and render in `grant.withGPUWork`; update completed-unit progress and await
`finish(success:)` on every exit path. On expiration or loss of foreground without
a valid grant, cancel and await GPU work before switching to CPU. Discard partial
output and retry only the unfinished unit, and only if playback is still wanted.
Never catch `CancellationError` as an instruction to restart. Cancel and await
work on pause, seek, book/account switch and interruption. Cancelling standalone
Prepare stops it; it must not recreate itself or continue as a CPU job.

Retain the real audio buffer/session, remote commands and reading-position
handling. CPU is not unlimited execution time and may generate slower than real
time. Preserve position and expose buffering/resume if execution time or audio
runs out. Do not use silent audio keepalive. Grants are bounded jobs, not permanent
GPU access; subsequent background work uses CPU without another valid grant.

The [grant example and lifecycle contract](UPGRADE-0.4.0-beta.5.md#rendering-with-a-grant)
remain applicable. Its historical eight-step new-profile recommendation is
superseded by this release's **accepted four-step Caro/Calm preset**. Keep eight
available as an advanced comparison and preserve users who already selected it.

## Advanced settings and resource recovery

Expose voice, Delivery, Phrasing and Variation separately. Variation maps to
`PocketTTSSamplingOptions.temperature`; default is 0.3. Sampler steps default to
four for the approved preset; supported range is 1–8. Do not describe higher
values as guaranteed better audio. Careful reading uses 24/16 soft token targets,
a hard cap of 96 and no short-sentence grouping. Preserve complete sentences
where possible, paragraph/source ranges and speaker turns. Advanced controls may
edit narration/dialogue targets, hard cap and grouping through validated
`PocketTTSChunkingOptions`; keep settings identical across audition, live reading,
chapter preparation and export.

Use `PocketTTSRealtimeBudget` only for an explicit automatic live-quality mode.
Reduce effective steps only after measured throughput threatens the audio buffer;
show effective quality when it differs from the saved request. Reset on backend,
voice, language or playback-rate changes. Cache the actual settings rendered.
Fixed-quality/offline preparation retains requested settings. Do not change
voice, temperature, weight precision or speaker boundaries to save computation.

Handle `.memory` and `.thermal` errors by preserving position, stopping and
unloading; allow a later user resume. Do not immediately repeat expensive work,
delete model downloads or silently change tiers. Failed/cancelled SDK operations
retire decoder/model state; cancellation stays cancellation. The optional
`setMaxResourceObserver` provides bounded diagnostics without book text.
See [resource recovery](UPGRADE-0.4.0-beta.6.md) for the runtime contract.

## Supported behavior, credits and acceptance

Use the shared NarrationPipeline and NarrationRenderer for all Max audio, spoken
lexicon readings, source mappings and character assignments. Max uses native text
and outputs 24 kHz mono. Do not add Kokoro phonemization/dialect/expressive DSP,
Plus expression tensors, voice blending, SSML or acting instructions in book text.
The SDK does not infer emotion automatically, blend delivery states or carry
acoustic state between independent narration units. Unrecognized dialogue may
remain narrator-owned; review cast assignments where character identity matters.

Show this small settings notice and link to full installed credits:

> Max uses Pocket TTS by Kyutai. Some delivery styles use synthetic reference
> performances from Voice-Zero, based on LibriVox recordings. Model and voice credits.

Use `KokoroAttribution.text`, `VOICE-CREDITS.json`, `DELIVERY-CREDITS.json` and the
installed license files. Pocket model/exported states retain CC BY 4.0 attribution;
source recordings have CC BY 4.0 or CC0 terms. Voice-Zero emotional references are
CC0. Do not describe all model/voice assets as MIT. Full suggested attribution
is in [delivery integration](MAX-DELIVERY-STYLES.md).

Before app distribution, verify downloads/repair, saved-book migration, settings,
characters, live/prepared/export cache consistency, long chapters, Play→Home,
lock/unlock, GPU denial/expiration, CPU fallback, pause/seek/resume, interruptions,
memory/thermal recovery and credits on actual iPhone/iPad. The SDK's stable
version does not replace app acceptance. The English Caro/Calm scene is listening
accepted; other styles/languages remain previews. No app/TestFlight upload is
part of this SDK release.
