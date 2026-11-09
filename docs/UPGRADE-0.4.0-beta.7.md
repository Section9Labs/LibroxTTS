# LibroxTTS 0.4.0-beta.7: Max delivery previews

Keep Max, Plus and Basic separate. This update adds optional reference-based
preview styles for Bill Boerst, Caro Davy, Peter Yearsley and Stuart Bell in the
seven existing Max languages. The original 23 voices and base asset pack stay
unchanged. Original is the default; previews are not listening-qualified
recommendations or native emotion-intensity controls.

Use the [complete delivery integration](MAX-DELIVERY-STYLES.md). Required app work:

1. Show **Delivery** beside a compatible Max voice. Obtain choices from
   `PocketTTSDeliveryCatalog.publishedStyles(voiceID:)`; label `isPreview` choices
   Preview. Do not enumerate all enum cases as available downloads.
2. Download just the selected style with
   `NarrationAssets.downloadPocketDeliveryStyle(_:voiceID:to:)`. Show its
   `PocketTTSDeliveryCatalog.manifest(voiceID:style:).downloadSize` and retain the
   supplied credits. Use the same model directory as the base language pack.
3. Persist `PocketTTSBookDelivery` with the book. Its narrator style applies to
   prose; optional `characterStyles` are keyed by stable cast speaker IDs.
   Unassigned dialogue stays Original. Validate styles again after a voice change.
4. Pass `pocketDelivery` to `NarrationPipeline.plan`. Use this plan for live
   reading, chapter preparation, export and audition. Preserve source ranges.
5. Include `PocketTTSBookDelivery.cacheIdentity` in chapter-plan identity and
   `NarrationModel.pocket.renderIdentity(for:)` in unit audio keys. Retire pending
   generation when settings change. Never reuse Original audio for a preview.
6. Keep temperature labeled Variation, separate from the reference style. Retain
   quality-first sampler settings, measured fallback policy and beta.5/beta.6
   background GPU authorization, CPU fallback and resource recovery.
7. Surface unsupported/missing-style errors. Do not silently substitute a voice,
   language, style or model. Do not automatically guess emotions sentence by sentence.

Hosts can override `unit.pocketDeliveryStyle` for a complete planned passage.
Style changes start from the selected reference; continuation within a unit
retains the same reference. This update does not add cross-unit acoustic memory,
state blending, or emotion intensity sliders.

See the integration document for settings attribution text and audition guidance.
No Librox app build or TestFlight upload is included in this SDK release.
