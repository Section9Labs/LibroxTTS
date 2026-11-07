# Narration across the full language catalog

The shared platform features now cover every Plus synthesis language: Arabic,
Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French,
German, Greek, Hindi, Hungarian, Indonesian, Italian, Japanese, Korean, Latvian,
Lithuanian, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish,
Swedish, Turkish, Ukrainian and Vietnamese. Basic uses the same machinery for
its eight synthesis languages, including Chinese; the current Plus model still
cannot synthesize Chinese.

The previous English/Spanish restriction was imposed by platform code, not by
native voice selection. `BookVoiceCast.Language` now stores a validated code
independently of `PronunciationLanguage`. Schema-1 JSON continues to encode the
same language string, so existing cast files, assignments, aliases and explicit
narrator fallbacks remain readable. The existing initializer accepting
`PronunciationLanguage` remains; new languages use `languageCode:`. Callers that
need phonemes must unwrap `cast.language.pronunciationLanguage` instead of
assuming every book language has a phoneme frontend.

Every language has localized literal reporting verbs, excluded pronouns and
conjunctions, and explicit stage-direction cues. The shared attributor accepts
named speech tags and labelled quotations. Japanese, Korean, Hindi and Chinese
have dedicated word-order/particle patterns; Arabic uses its literal reporting
forms and punctuation. German low quotes and Japanese brackets are recognized
without rewriting source offsets. Speaker selection is transactional and bounded;
ambiguous or untagged turns never imply alternating speakers. Existing EN/ES
local pronoun/action continuations and gender evidence remain more extensive:
this change does not claim equal coreference accuracy or infer gender from names.

Basic and Plus share the bounded stage parser. Registered speaker labels retain
assigned voices; explicit localized parenthetical directions use the narrator.
Ordinary parentheticals remain dialogue. Native single-narrator mode retains its
existing grouping. Public dictionary readings are applied before native token
budgeting in every language. Languages outside the existing eight frontends now
receive locale-backed cardinal/decimal readings, preserving identifiers,
unsupported formats, and ambiguous tokens instead of falling back to English.
Dates, times, abbreviation expansion and grammatical number agreement still have
richer reviewed rules in the existing frontends; broad locale coverage is not
proof of equal linguistic quality.

The app no longer rejects cast persistence outside the phoneme enum, and its
existing capability checks expose character selection for all supported Plus
languages. Manual voice edits, reopen, narrator fallback and the character-mode
prewarming guard use the same flow for all languages.

## Verification

`AllLanguageNarrationTests` inventories all 31 languages independently of the
rule table and covers actual localized reporting fixtures, persisted manual
voice selection/fallback, source ranges, real tokenizer bounds, localized stage
cues, untagged/pronoun abstention, dictionary overrides and numeric preparation.
Additional suffix-tag fixtures cover seven languages across Latin, Cyrillic,
Arabic, Devanagari, Japanese and Korean scripts. The app's
`testAllNativeLanguagesPersistAndRestoreManualCharacterVoices` exercises its
actual store for all 31 languages.

Both cache revisions advance: `native-characters-3` and `spoken-text-3`. Existing
app PCM keys include the combined pipeline revision; model assets do not change.
Full SDK release tests pass, with the existing opt-in real-model skips retained.
Native render receipts and app/build checks are recorded separately in the release
handoff. Fixture and render success do not certify fluency, pronunciation,
expression or natural character transitions in every language. No new physical
iPhone/iPad acceptance, model publication or TestFlight upload is implied.

Native expressive controls, blending and historical DL pacing remain separate
implementation/quality work across the whole catalog. The optional context
research is not enabled by this multilingual casting change.
