# Shared delivery integration

This SDK successor adds native style blending and a common model-aware timing
adapter, and makes spoken-reading dictionaries persistable and reusable across
all supported languages. Model graph/style assets are unchanged.

- `SpokenTextLexicon` is Codable, exposes normalized `entries` and a deterministic
  `cacheIdentity`. Put book entries before global entries; the first duplicate
  wins. Matchers compile once per language. Canonically equivalent accents match;
  Japanese/Chinese literal corrections can match inside continuous script. Source
  offsets remain original. This is written-to-spoken guidance, not an IPA-to-text
  converter or proof of equal pronunciation quality.
- Pass the same lexicon to `NarrationPipeline.plan` for playback, preparation,
  previews and exports. Include `lexicon.cacheIdentity` in preparation identity;
  prepared unit `synthesisText` already participates in PCM identity.
- `NarrationDeliveryOptions(blendedVoice: true)` now consumes a native style pair:
  80% primary plus 20% next preset in the same F/M group, wrapping at five. All ten
  presets support the same mapping in all31 languages. Both style tables blend;
  no additional graph or mixed PCM. Off restores the original table. This is an
  optional voice choice, not an expression improvement or approved new default.
- `NarrationPlaybackCadence(model:nativeTiming:)` works for both adapters. Native
  timing defaults false pending listening review. With true, it reuses semantic
  participant/paragraph/chapter timing and credits existing quiet edges. Apply
  after raw PCM cache lookup and reset on seek/book/playback-generation changes.
  Do not store paced samples. Existing Basic profile initialization still works.
- `NarrationModel.renderIdentity(for:)` includes the optional native context's
  renderCacheKey. Production context attachment remains OFF. Newer listening
  feedback says it is in the right direction but not a meaningful improvement.
  Style blending and the diagnostic context path do not combine: context is
  omitted while a blend is active rather than misidentifying its conditioning.

Cache changes: `spoken-text-4`, `delivery-options-2`, `dialogue-timing-3`, and the
context-aware native render identity. All application dependency graphs must use
the same eventual SDK release. Public0.3.0 does not provide these changes.

Technical source/unit tests are not listening acceptance. Native render receipts,
app validation and release availability are recorded separately. Chinese remains
Basic-only; Plus must report unsupported language rather than silently switching
engines. Native regional dialects, IPA/stress equivalence and meaningful expression
improvement still need a model-appropriate implementation and qualification.
