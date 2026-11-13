# Librox app handoff — LibroxTTS 1.0.0

Migrate Librox to exact **LibroxTTS 1.0.0**. Preserve concurrent app work and user
books, positions, downloads, casts, dictionaries, selected voices, styles and
sampling. This handoff authorizes SDK integration, not a TestFlight/App Store upload.

```swift
.package(url: "https://github.com/Section9Labs/LibroxTTS.git", exact: "1.0.0")
```

[Release](https://github.com/Section9Labs/LibroxTTS/releases/tag/v1.0.0).
Resolve the published tag to its full commit and verify every dependency graph
against that revision. Do not substitute a branch or a development commit.

## Dependency and runtime integration

1. Inspect the app's current checkout, ownership instructions and dependency pins.
   Preserve unrelated work; use an isolated worktree if needed. Audit every
   applicable `Package.swift`, `Package.resolved`, XcodeGen input and CI pin.
   Known locations include `LibrosKit/Package.swift`, `Libros/project.yml`,
   `LibrosKit/Package.resolved`, `Validation/CT/Package.resolved`, and the app's
   workspace `Package.resolved`; verify current paths rather than assuming them.
   Update applicable pins to exact 1.0.0, regenerate XcodeGen projects when needed,
   and resolve each graph without unrelated dependency upgrades.
2. Read this document, `docs/implementation-10-speed.md`, and
   `docs/loudness-review/README.md`. For pins older than 0.9, also apply the relevant
   requirements in `docs/UPGRADE-0.9.0.md` and its earlier linked handoffs.
3. Keep Max Core ML CPU on iPhone/iPad and MLX on Mac/Catalyst. Keep model metadata,
   routing, installation, planning, delivery policy, cache identity and error
   interpretation SDK-owned. Preserve Basic and Plus behavior and identities.
4. Audit every Max book-rendering path: buffered, streaming, prefetch, offline
   chapter preparation and any background/companion worker. Book narration should
   use `NarrationRenderer.render` / `renderPocketFrames`. Direct `PocketTTSEngine`
   and `PocketTTSCoreMLEngine` APIs deliberately still return raw samples and do
   **not** apply the new default balancing. Do not silently mix raw and calibrated
   producers under the same prepared-audio identity.

## New default Max loudness

`NarrationRenderer` now automatically applies a frozen gain for the selected
voice, language and reference style, to **both narrator and character units**.
Buffered and streaming paths use the same treatment. There is no opt-in flag or
new app setting required. Do not copy the calibration table into Librox, add a
second normalizer, or multiply in another compensating gain. Preserve ordinary
user volume and playback-rate controls; do not silently reset saved settings.
Audit any existing automatic Max gain/normalization stage for double processing.

There are 525 profiles: 23 Original voices in seven languages, plus 13 reference
styles for four speakers in each language. Gains are constant through ordinary
speech. Style offsets relative to Neutral are bounded to ±3 LU, retaining native
within-utterance expression without sentence-by-sentence gain riding. A boost-only
emergency soft knee protects unexpected high transients. It affected 27 samples
in two German holdouts; the zero-activation target was not met. Listening remains
necessary. No acoustic weights, voice/style IDs, text, sampling, sample counts,
chunk timing or public declarations changed. **Default facade PCM intentionally
changes in level; raw engine PCM and Basic/Plus audio remain unchanged.**

The new-book Max preset remains Caro Davy / Calm, Careful reading, temperature 0.3,
four sampler steps. Preserve existing saved choices and supported steps 1–8.

## Prepared-audio cache migration

The new level revision is `pocket-level-v1-41466443134c33e7`. It is included in
`NarrationModel.pocket.deliveryIdentity` and therefore in
`NarrationModel.pocket.renderIdentity(for: unit)`.

- Use the **SDK-returned full render identity** as one part of the complete cache
  key and receipt. Retain existing text, voice, language, model/assets, unit and
  other audible-input keys; the render identity alone is not a complete cache key.
  Do not hardcode the level revision or use the raw engine's runtime identity as
  a substitute. Keep backend/platform separation.
- Audit all reads and writes: memory/disk caches, chapter manifests, prefetch,
  interrupted jobs, companion/cloud prepared narration, and any imported prepared
  segments. A lookup must validate the actual producer identity, not merely a
  new filename or the consuming app version.
- Old or missing Max delivery identity is a cache miss for **new default book
  narration**. Regenerate those prepared segments lazily under the current SDK
  identity. Do not relabel old bytes as new, silently fall back to old raw audio,
  or mix old/new level revisions within a resumed prepared chapter. Cancel/retire
  stale in-flight generation and reject late writes before adopting new output.
- Keep old complete artifacts only where needed for already-started playback or
  explicit user exports, under their original identity. Choose a safe playback
  boundary for switching; preserve audible position and never hot-swap queued
  samples mid-unit. Exported audiobooks are user content, not disposable caches.
- **Do not delete or redownload model/style packs.** Model manifests, repository
  identities and asset bytes are unchanged. Keep normal SDK validation and compiler
  receipt handling. Do not purge Basic/Plus caches, saved preferences, books,
  positions, user recordings or unrelated app data. A blanket application-data
  reset is not a migration strategy.

Add meaningful migration tests: a 0.9/missing-identity Max artifact cannot satisfy a
1.0 render; correctly keyed 1.0 audio is reusable; Basic/Plus entries and installed
assets remain reusable; stale jobs cannot publish into the new identity; resumed
chapters cannot mix revisions; counts/progress and stream/buffer output agree.

## Streaming and playback contracts

Preserve synchronous throwing callbacks, bounded backpressure and cancellation.
Cancel and await generation before unload/replacement; incomplete streams must not
be committed as complete cache entries. Reject stale audio/events after seeks,
voice/language/book/account changes. The host still serializes asset installation
and removal against generation.

`onTextChunk` reports completed prepared-text chunks as half-open cumulative
**24 kHz source-sample ranges per render call**, after frame acceptance. It is not
word alignment or a source UTF-16 range. Drive text/highlights from audio actually
played, accounting for queued-unit offsets, seeks, rate changes and resampling.
Preserve the explicit cached-audio fallback when chunk metadata is absent. Never
drop words or alter sampling/quality to catch up with visual timing.

## Validate and report

Build/test supported iPhone, iPad and Mac/Catalyst configurations. Use
`swift test --build-system swiftbuild` and `-c release` for SDK command-line tests
so MLX Metal resources are included. Run app narration, cache migration, persistence,
downloads, cancellation, seek/resume and playback tests. Preserve the established UI.

Compare the existing app pin and 1.0 on the same device, OS, build configuration,
assets, text, voice/style, language, sampling and seed where available. Separate
fresh setup, warm synthesis, first accepted frame and **first audible output**.
Record sustained throughput, underruns, sampled peak memory, thermal state and
CPU budget. Include multi-character English/Spanish narration, Original/Calm and
expressive references, voice/language/chapter switches, slow/failing receivers,
lock/background, route interruptions and normal/custom playback rates. Confirm
positions and settings survive relaunch. Human listening must assess balanced
voices, preserved expression, intelligibility, clicks, gaps and missing/repeated
words. Report unsupported hardware and tests that could not run explicitly.

SDK evidence against 0.9 is scoped: Mac warm synthesis is near parity (1.5% faster
in a longer follow-up); iPad is 3.4% faster. Matched Mac sampled memory is 36.7%
lower; the physical iPad soak peaks at 83 MiB over 411 renders, 94.4% below the old
matched-count peak. The original 2x synthesis goal is not met. Held-out neutral
voice spread is 15.7 → 2.55 LU in English and 4.75 → 2.35 LU in Spanish. These are
SDK probes, not proof of host-app speed, playback or perceptual quality. The iPad
probe tested raw Core ML; physical iPhone and host-app listening remain unqualified.

Commit the migration and return the exact app commit, resolved SDK SHA in every
graph, cache/producer changes, checks and measurements, listening findings and
remaining gaps. Prepare a release-manager handoff without sending messages or
uploading app builds unless separately instructed.
