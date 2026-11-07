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

| Feature | Shared implementation / result | Model-specific boundary |
| --- | --- | --- |
| Playback, preparation and previews | `NarrationPipeline` and `NarrationRenderer` remain the shared entry points. | Adapters prepare phonemes for Kokoro and normalized text for Plus. |
| Voice selection and Automatic language | App now uses SDK `resolvedVoiceID`; F1–F5/M1–M5 survive all 31 language resolutions. Voice picker lists ten styles for the effective language and preserves Automatic when selecting a style. | Kokoro retains its own language-specific catalog. |
| Character casting and saved assignments | Same `BookVoiceCast`, attributor and source ranges; old native pools expand without changing characters, aliases, manual assignments or manual narrator fallback. Direct Kokoro pipeline calls now create a usable cast too. | Automatic attribution is English/Spanish for both, not all synthesis languages. |
| Dictionary readings and normalization | `SpokenTextLexicon` shares reviewed spoken readings and source offsets across both adapters. Native uses common text normalization and English number expansion. | The large Kokoro phoneme dictionary cannot be fed verbatim into a grapheme-input model. Native pronunciation is not certified identical to Kokoro's G2P. |
| Expressive controls and blending | SDK exposes actual capabilities and resolves supported delivery options. Unsupported retained preferences no longer create different native cache requests for identical audio. | Kokoro's phone-level gestures/blends are not native emotion controls. Native context response is a separate, default-off candidate. |
| Pronunciation dialect | Capability belongs to SDK; app only offers it where consumed. | Native does not consume Kokoro regional phone substitutions. |
| Source highlighting and seek | Original UTF-16 ranges survive dialogue segmentation and spoken-reading substitution. | Token budgets differ; neither renderer receives unsupported input representation. |
| Audio format, rate and level | App playback/previews use runtime sample rate; existing 1x bypass and fixed native dynamics remain. | Plus is 44.1 kHz; Kokoro is 24 kHz. No audition normalization or new waveform processing added. |
| Cached audio and warmup | Actual unit voice, model/delivery/pipeline identities and spoken text participate in cache keys. Existing character-mode preparation guard remains; unsupported attribution does not force full-chapter planning. | Speculative character preparation remains disabled until an identical persisted cast plan is guaranteed. |
| Backend/lifetime | One native renderer switches style tensors without reloading synthesis graphs. Existing cancellation, bounded vocoder and foreground-GPU/background-CPU handoff remain. | These changes do not newly qualify device memory, thermals or background behavior. |
| Model preparation | SDK `preparationIdentity` replaces the app's hard-coded SDK-version receipt. | Preparation identity is distinct from voice selection and PCM identity. |
| Downloads and updates | SDK owns known prior asset IDs and verified-file reuse. App copies only files matching the new manifest into private staging, preserving old installations; existing verified preparation/finalization remains. | Complete model-update UX and retaining an older runtime as a fallback during a changed-model download are not implemented here. |

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
qualification, wider-language automatic attribution, complete model-update UX,
publication and new iPhone/iPad/TestFlight qualification remain open. Do not
expose unsupported controls or equate metadata with an acoustic capability.
