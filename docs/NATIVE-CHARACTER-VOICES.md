# Native Plus character voices

The DK preview uses the same `BookVoiceCast`, `SpeakerAttributor` and
`StoryNarrator` as Kokoro, followed by native text preparation. Assigned dialogue
actually changes `unit.voiceID`, which `NarrationRenderer` passes to the pinned
F1–F5/M1–M5 styles in `CTEngine`. Switching styles does not reload the synthesis graphs.
No model weights, voice tables, generator, vocoder or delivery processing changed.

## Host integration

Use model-owned catalog APIs for character menus and new casts:

```swift
let voices = model.characterVoiceCatalog(language: language)
let supportsAttribution = model.supportsAutomaticCharacterAttribution(language: language)
let cast = try model.makeVoiceCast(bookID: bookID, language: language,
                                  narratorVoiceID: narratorVoiceID)
let plan = try await pipeline.plan(text, model: model, bookID: bookID,
    chapterID: chapterID, narratorVoiceID: narratorVoiceID, language: language,
    cast: cast, characterVoices: true, lexicon: lexicon)
```

Persist `plan.cast` atomically before playing newly assigned voices. Reuse it in
later chapters; do not create a fresh cast per excerpt. Explicit edits continue
to use `setVoice(_:for:)`, `addAlias(_:to:)` and `replacingNarrator(with:)`.
Manual nil assignments remain narrator fallback. The saved cast's narrator is
authoritative until explicitly changed. Foreign model, wrong-book and
wrong-language casts are rejected, including when character playback is off.
For an older saved catalog, call `model.expandingVoiceCatalog(in:)` before
showing the current menus. It adds available voices without recasting characters
or removing manual narrator fallback. Persist the expanded cast on the next edit
or successful plan. Hosts with intentionally restricted palettes can keep them.

Model or catalog scope must be part of saved voice assignments. Keep existing
Kokoro files and manual choices; do not overwrite them with Plus voices or pass
Kokoro IDs into a native cast. Character identity migration, if offered by the
host, must be explicit and keep old model assignments recoverable. The app's
old `Voice.all` pools, `Voice.named` validators and Kokoro-only character menus
must use these model APIs before enabling the feature.

Playback, preparation and previews must use the same cast and character setting.
The returned `bookPlan` includes attribution decisions and unchanged source
ranges. Cache keys must include pipeline revision, model/asset identity, selected
unit voice, source and spoken text, delivery settings and cast changes. Changing
a character voice must not play earlier cached PCM. The pipeline revision is now
`narration-pipeline-2:native-characters-1:` plus the native text planner revision.
Keep the existing no-speculative-prewarm guard when character voices are enabled
until the host can persist and reuse the identical plan.

## Behavior and limits

- Native automatic attribution currently covers English and Spanish, matching
  Kokoro's existing attributor. Native synthesis still supports 31 languages.
  Query `supportsAutomaticCharacterAttribution` rather than treating synthesis
  language support as speaker-understanding support. The legacy cast schema
  itself accepts only `PronunciationLanguage` languages.
- F1–F5 and M1–M5 are available; F1/M1 baseline quality has listening acceptance.
  The pool can reuse a
  compatible style for several characters. This is not a unique voice for every
  character, and source gender is never guessed from a name alone.
- Named English quotations and Spanish quotations/dash dialogue reuse existing
  conservative attribution. Unresolved/ambiguous turns stay with the narrator;
  untagged alternating dialogue is not automatically assigned alternating voices.
- Reporting clauses use the narrator. Original UTF-16 book ranges survive voice
  segmentation and dictionary substitutions. Native token budgets remain enforced.
- Turning character voices off retains the cast but uses the original native
  single-narrator grouping. Character mode necessarily creates voice boundaries;
  those multi-voice transitions require listening review.
- Character casting is not emotion control or DL pacing. This change does not
  claim complete parity with every Kokoro delivery gesture or structured script
  heuristic, nor app/device qualification.

## Verification

`NativeCharacterPlanningTests` covers bilingual assignment, F1/M1/F1 switching,
persisted corrections/aliases/manual fallback, source offsets and dictionary
expansion, bounded long dialogue, narrator changes, Spanish reporting clauses,
single-narrator preservation, invalid casts and unsupported attribution.

The native probe can render a real multi-voice plan with the same renderer:

```sh
swift build -c release --product narration-pipeline-probe
.build/release/narration-pipeline-probe --native-cast ASSETS OUTPUT en plus-f1-en-v1 PASSAGE.txt
```

It persists `cast.json` before rendering and writes `native.wav` plus a receipt
with each unit's source range, speaker, actual native voice and role. Use a new
output directory. No additional audition processing is applied. These SDK
results do not mean the app character UI has been integrated or shipped.
