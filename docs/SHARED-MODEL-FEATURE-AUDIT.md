# Shared model features and ten native voices

The native Plus catalog now exposes every preset in the frozen source bundle:
F1–F5 and M1–M5. Each style is available in all 31 native synthesis languages.
F1/M1 IDs are unchanged. This is ten styles, not 310 independently trained voices.

The new local asset identity is `librox-plus-dk-coreml-v2`, with 32 pinned files
and 442,398,406 bytes. All five synthesis graphs and F1/M1 style files are
byte-identical to the accepted two-voice DK candidate. The eight added style
files require about 2.3 MB. Every style table has the expected dimensions and
finite values and matches the frozen source manifest's SHA256.

## Audit and implementation

Requirement: Basic's user features are the minimum target for Plus. A different
input representation explains an implementation difference; it does not close a
parity gap. Capability flags prevent ineffective controls, but are not evidence
that an equivalent feature exists. The register below separates shared source,
tested fixes and remaining work.

| Feature | Shared implementation / result | Model-specific boundary |
| --- | --- | --- |
| Playback, preparation and previews | `NarrationPipeline` and `NarrationRenderer` remain the shared entry points. | Adapters prepare phonemes for Kokoro and normalized text for Plus. |
| Voice selection and Automatic language | App now uses SDK `resolvedVoiceID`; F1–F5/M1–M5 survive all 31 language resolutions. Voice picker lists ten styles for the effective language and preserves Automatic when selecting a style. | Kokoro retains its own language-specific catalog. |
| Character casting and saved assignments | Same `BookVoiceCast`, attributor and source ranges; old native pools expand without changing characters, aliases, manual assignments or manual narrator fallback. Direct Kokoro pipeline calls now create a usable cast too. | Localized explicit speech tags/labels now cover every supported model language. Existing EN/ES coreference/gender heuristics remain richer; see ALL-LANGUAGE-NARRATION.md. |
| Multilingual play structure | Basic and Plus now share `StageDialogueStructure.parseBook`. With character mode on, known printed labels resolve saved voices, directions/labels use the narrator, and unknown labels do not allocate guessed voices. | Plus single-narrator mode retains its accepted grouping. Parser bounds and unsupported languages fall back to the existing plan. |
| Dictionary readings and normalization | `SpokenTextLexicon` shares reviewed spoken readings and source offsets across both adapters. Native uses common text normalization and English number expansion. | The large Kokoro phoneme dictionary cannot be fed verbatim into a grapheme-input model. Native pronunciation is not certified identical to Kokoro's G2P. |
| Expressive controls and blending | SDK exposes actual capabilities and resolves supported delivery options. Unsupported retained preferences no longer create different native cache requests for identical audio. | Kokoro's phone-level gestures/blends are not native emotion controls. Native context response is a separate, default-off candidate. |
| Pronunciation dialect | Capability belongs to SDK; app only offers it where consumed. | Native does not consume Kokoro regional phone substitutions. |
| Source highlighting and seek | Original UTF-16 ranges survive dialogue segmentation and spoken-reading substitution. | Token budgets differ; neither renderer receives unsupported input representation. |
| Audio format, rate and level | App playback/previews use runtime sample rate; existing 1x bypass and fixed native dynamics remain. | Plus is 44.1 kHz; Kokoro is 24 kHz. No audition normalization or new waveform processing added. |
| Cached audio and warmup | Actual unit voice, model/delivery/pipeline identities and spoken text participate in cache keys. Existing character-mode preparation guard remains; unsupported attribution does not force full-chapter planning. | Speculative character preparation remains disabled until an identical persisted cast plan is guaranteed. |
| Backend/lifetime | One native renderer switches style tensors without reloading synthesis graphs. Existing cancellation, bounded vocoder and foreground-GPU/background-CPU handoff remain. | These changes do not newly qualify device memory, thermals or background behavior. |
| Model preparation | SDK `preparationIdentity` replaces the app's hard-coded SDK-version receipt. | Preparation identity is distinct from voice selection and PCM identity. |
| Downloads and updates | SDK owns known prior asset IDs and verified-file reuse. App copies only files matching the new manifest into private staging, preserving old installations; existing verified preparation/finalization remains. | Complete model-update UX and retaining an older runtime as a fallback during a changed-model download are not implemented here. |

## Basic-to-Plus parity register

Audited the current SDK and the app candidate `c43f513b`, including
`ListeningSettingsView`, `ListeningVoicePreview`, `ListeningCenter`,
`NeuralSpeechReader`, `NarrationBookStore`, the planners and both render adapters.
Source sharing does not replace testing the new native model in TestFlight.

| Basic feature | Plus status and evidence | Remaining action |
| --- | --- | --- |
| Voice audition, selection and persistent settings | Shared voice cards/list, preview owner and renderer; native ten-style catalog and Automatic selection covered by existing tests. | New native voices still need listening review. |
| Narrator/character selection, manual narrator fallback and aliases | Shared cast schema/attributor; app persists separate catalogs. Regression tests exercise source spans, reopen and assignments. | No new device-interaction acceptance claimed. |
| Spanish theatrical directions and printed speakers | Gap fixed in this pass through the same bounded structural parser; differential Basic/Plus planning tests use the same play and saved character. | Native transitions still require listening. |
| Numbers, dates, money, times, Roman chapter numerals | Shared normalizer already covered structured forms; this pass fixes native English signed/grouped decimals, longer ordinals and numbers next to sentence punctuation, using Basic's `NumberToWords`. IDs/malformed syntax stay intact. | Context-dependent English year/address readings and arbitrary abbreviation/name pronunciation are not identical to the phoneme frontend. |
| Pronunciation dictionaries and corrections | Reviewed written-to-spoken overrides share the SDK pipeline. Native receives normalized words. | Basic's IPA/stress/G2P dictionaries are not yet equivalent native pronunciation guidance; do not call this full dictionary parity. |
| Supported book languages | Native has 31, Basic has 8; **Chinese (`zh`) is Basic-only**. Hindi is supported by both. | The current native model cannot gain Chinese by adding a picker entry. Model-level support and listening qualification are required. Never silently switch engines. |
| Regional pronunciation | Basic consumes Spanish phone substitutions; Plus does not. | Native equivalent remains required; hidden control is not parity. |
| Expressive delivery | Basic uses explicit attribution evidence and scoped phone gestures. Native baseline is accepted; optional surrounding-context research is separate/default-off. | Native equivalent needs listening evidence; do not forward unsupported phone controls. |
| Voice blending | Basic has reviewed specific voice pairs; Plus exposes ten distinct styles. | Native style interpolation is not implemented or accepted; ten presets are not blending parity. |
| Conversation/chapter seam pacing | Basic applies `NarrationPlaybackCadence`; Plus currently bypasses it to preserve accepted native delivery. | Native timing equivalent remains open. Do not claim the earlier DL result or add unreviewed fixed pauses. |
| Speed, pause/resume, seek, chapter advance, source highlighting | Shared `NeuralSpeechReader`, player and timeline; sample rate comes from selected model. Native unit source offsets survive substitutions/splitting. | Existing tests/source evidence; repeat usage in TestFlight for the changed native model. |
| Sleep timer/end-of-chapter, mini-player, Now Playing, route/call interruption and CarPlay presentation | `ListeningCenter` owns these independent of Basic/Plus; both use the same neural driver. | No new hardware checks declared passed. Matt deferred dedicated checks to TestFlight. |
| Offline cache, prewarming, cancellation and memory lifetime | Shared cache/driver; model, pipeline, spoken text, delivery and actual voice identities separate audio. Plus additionally reserves opening/resume audio. | Character prewarm guard is shared; complete update UI/runtime fallback remains open for new assets. |
| Download verification and preparation | Both use SDK manifests, checksums and staged installation; Plus reuses verified prior files. | Publish immutable SDK/assets and update all app graphs before release. |

The numeric fix changes `spoken-text-2`; stage casting changes
`native-characters-2`. Both flow into `NarrationPipeline.revision`, which the app
includes in prepared PCM keys. No model graph/style bytes change in this pass.

## Download reuse

The manifest comparison identifies 403,528,597 bytes reusable from the released
CT model. With those verified files installed, 38,869,809 bytes are new/changed
for this bundle. From the earlier DK F1/M1 candidate, only 2,333,939 bytes are
new/changed. These are manifest-derived network requirements, not a measured
network transfer; missing or corrupt files must download again.

Reuse verifies the current hashes and never moves or deletes a source install.
Staging must not overlap an installed root. A changed voice or graph is never
accepted solely because its filename or old receipt matches.

## Validation and remaining work

All ten presets rendered English and Spanish through native Core ML with one
loaded renderer. The 20 WAVs/receipts are under the local asset root
`/Users/matt/Code/swift/librox-dk-native-assets-v2`. Samples were finite and within
the output bounds. These are technical render checks: only F1/M1 English/Spanish
baseline quality has been accepted by listening; the additional voices and cast
transitions are available for review.

SDK tests cover all 310 style/language mappings, preserved casts with expanded
catalogs, model-independent default casting, effective delivery options and safe
asset reuse. App tests cover native style preservation under Automatic/explicit
language, older saved casts selecting new presets and retained inactive settings.

This audit does not claim full feature parity: native DL pacing, context/emotion
qualification, broader linguistic/listening qualification, complete model-update UX,
publication and new iPhone/iPad/TestFlight qualification remain open. Do not
expose unsupported controls or equate metadata with an acoustic capability.

## Full language rollout

The subsequent [all-language implementation](ALL-LANGUAGE-NARRATION.md) removes the cast-storage/frontend-enum coupling and EN/ES attribution gate. All 31 Plus languages now share persistent character choices, localized explicit reporting/label rules, stage direction routing, spoken overrides and numeric preparation. This supersedes earlier EN/ES-only capability statements; it does not imply equal linguistic quality in every language. No model bytes change.

## Beta successor (supersedes the earlier implementation gaps above)

SDK0.4.0-beta.1 implements native style blending for all ten styles/all31 languages,
persistable Unicode-aware spoken corrections, common multilingual reporting seam
rules and an opt-in native semantic timing adapter. Shared native context PCM keys
are integrated, but context is not attached by default: the newest comparative
listening feedback did not establish a meaningful improvement.

The released CT F1 manifest/runtime is retained independently for playback while
DK stages and prepares. The app snapshots installation identity per playback
generation, keeps model-specific PCM keys, offers an explicit Update action and
keeps verified old files/receipts. No silent voice or engine substitution is used.

Model-level gaps remain: Chinese synthesis in Plus, native regional pronunciation,
phonemic/stress-dictionary equivalence, meaningful expression improvement and DL
timing qualification. Ten-style blending and semantic cadence are implemented
choices with technical tests, not automatic claims of preferred sound. See
[shared delivery integration](SHARED-DELIVERY-UPGRADE.md) and the beta upgrade guide.
