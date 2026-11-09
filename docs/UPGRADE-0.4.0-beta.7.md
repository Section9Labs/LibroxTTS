# LibroxTTS 0.4.0-beta.7: Max delivery previews

Keep Max, Plus and Basic separate. This update adds optional reference-based
preview styles for Bill Boerst, Caro Davy, Peter Yearsley and Stuart Bell in the
seven existing Max languages. The original 23 voices and base asset pack stay
unchanged. For new Max books, the default narrator is **Caro Davy / Calm**, with
**Careful reading**, temperature **0.3** and **4 sampler steps**, matching the
English book scene accepted by Matt. Preserve all saved book/voice/settings
choices. Other performances and non-English delivery remain listening previews;
these are reference performances, not native emotion-intensity controls.

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
   quality-first sampler settings, measured fallback policy and beta.5/beta.6
   background GPU authorization, CPU fallback and resource recovery.
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
