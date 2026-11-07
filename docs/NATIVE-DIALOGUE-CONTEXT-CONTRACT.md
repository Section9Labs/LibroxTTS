# Native context gathering: implementation and listening evidence

Status: presented samples listening-approved; production context remains default off pending integration checks. Accepted DK F1/M1 voices remain the baseline. No model weights, voice tables or assets change.

## Mechanism

The production SDK plans and casts raw book text. For each dialogue unit, `NarrationTextContext.surrounding` constructs a window from the actual prepared synthesis readings and original inter-unit separators: at most two neighboring units on either side, within one paragraph and 512 normalized tokens. Dictionary and number expansions therefore remain aligned to the spoken text.

`CTTextContext` binds the selected span to the normalized whole context, including the language wrappers. Temporary private-use markers establish exact positions through normalization; they never enter the model. The unmarked result must equal ordinary normalization, and gathered tokens must exactly equal the isolated unit. Ambiguous or noncompositional mappings fail closed.

The existing DK early Core ML encoder runs on the bounded context in the selected speaker's style. Its features are gathered at the exact spoken-token positions and used at acoustic steps 0–2. Duration, late encoder at steps 3–9, generator inputs, noise, vocoder and delivery stay unchanged. This exposes surrounding prose to existing learned features; it does not implement an emotion classifier or establish semantic understanding.

The feature binding includes source range, text, normalized tokens, language, actual manifest fingerprint, style and revision. The engine rebuilds and validates it, then also compares actual gathered token IDs. A nil, identity or invalid binding takes the original isolated encoder path. Renderer duration splitting drops context instead of reusing invalid offsets. No production planner attaches context by default.

There is no feature cache in this prototype. Future feature reuse must use `featureCacheKey`; waveform reuse must also distinguish `renderCacheKey` and the full synthesis configuration. Shared context with repeated identical quotes has different gather positions and render keys. This implementation adds no learned parameters or additional generation steps, but encoding longer context can increase runtime. It is not iPhone-qualified.

## Native evidence

SDK base: `1170112e51d5a3ef277ff6191026ae827aa73ad3`.
Asset identity: `librox-plus-dk-coreml-v1` (accepted two-voice bundle).
Runner binary SHA-256: `29f3ccb0928607c253ad9f43b41fb4340822d97b7133fe941a027fee52bdf417`.

Evidence directory: `/Users/matt/Code/swift/librox-dk-native-context-v1`.
`implementation.json` freezes every runtime Swift source hash, the binary and tracked diff. `manifest.json` inventories all ten cases and listening files. Per-case receipts retain exact source, actual cast, model hashes, token-binding files, supplied noise, graph/wall times and WAV hashes. The corpus is in `docs/validation/native-context-scenes-v1`.

Ten complete-paragraph comparisons were generated through `NarrationRenderer` and Core ML: eight dialogue scenes spanning English/Spanish, F1/M1 and relief/danger, plus two narration-only controls. Evaluation scene labels never enter model inputs. The same quoted line appears under opposing surrounding contexts.

Verified in every case:

- Identity and wrong-style rejected context produce byte-exact native and delivered PCM at matched noise.
- Text IDs/masks, both style tables, predicted duration, late encoder features, initial latent and latent mask match exactly between arms.
- Sample counts match; samples are finite and in range.
- Narration units reuse baseline audio explicitly. Both narration-only complete WAV files are byte-identical.

The first eight cases each apply context to one actual dialogue unit. Changed early features or waveforms are not quality evidence. The user subsequently approved the four presented samples as sounding good; see the listening review below.

Each `baseline-then-context.wav` contains accepted baseline followed by candidate with a presentation-only 0.8-second gap. No ASR, added pauses inside narration, waveform pitch or tempo edits, or candidate-specific gain were used. The diagnostic does not implement historical DL pacing.

Validation: release probe build and full `swift test -c release` completed successfully. Six new binder tests cover normalization/Unicode, repeated dialogue positions, dictionary substitutions, paragraph/token bounds and cache separation. Existing opt-in real-model, benchmark and integration tests remain skipped by their normal configuration; the separate ten-case native run supplies the audio evidence described above. Logs: `/tmp/librox-native-context-build.log`, `/tmp/librox-native-context-binding-tests.log`, `/tmp/librox-context-sdk-tests.log`.

## Reproduction

Build `narration-pipeline-probe` in release mode, then run:

```sh
.build/release/narration-pipeline-probe --native-context ASSET_DIRECTORY NEW_OUTPUT_DIRECTORY en plus-f1-en-v1 docs/validation/native-context-scenes-v1/en-female-relief.txt
```

Use `es` and `plus-f1-es-v1` for Spanish. Actual M1 character selection comes from SDK casting, not overriding F1 style data. The output directory must be new. Initial noise is shared within each pair and saved; a fresh invocation creates new noise.

## Ownership and release boundary

This isolated patch owns the binder, optional engine input, nil unit storage, renderer forwarding and diagnostic runner/tests. It does not change production assets, catalog, `NarrationPipeline`, casting, app wiring or defaults. The SDK chat owns all-voice asset registration, casting and iPhone integration. New assets must invalidate old context bindings through their actual manifest fingerprints.

The presented samples received positive listening feedback. Phone latency/memory/thermal qualification, DL timing parity, general emotion understanding and human-narrator quality are not claimed. Keep production context disabled pending native integration and cache-identity checks. The older local-query proposal is deferred and is not this implementation.

## Reconciliation with the ten-voice SDK

Merged SDK `f3b723910e4b099d9bcec7870b5e4ea126de22bd` at `319b1d40d271eff53fafe8fa8b5ddb4ba4256203`. The only merge conflict was probe command dispatch; both `--native-context` and `--native-voices` remain available. The optional context implementation is unchanged and defaults remain off.

Full release tests and the release probe build pass against `librox-plus-dk-coreml-v2`. Two new native integration comparisons exercise M1 English dialogue and newly available F2 Spanish dialogue with F1 narration. Identity/rejected-context PCM, token/style/late-feature/noise invariants and duration checks pass. Final-build receipts and hashes are at `/Users/matt/Code/swift/librox-dk-native-context-v2-reconciliation/final/manifest.json`. The earlier parent-directory runs used the Swift test-built executable; the `final` directory is the separate final-product-build check.

The v1 F1/M1 listening comparisons remain unchanged and tied to their original binary/assets. The v2 checks establish integration only, not new listening acceptance. Current bindings fingerprint the v2 manifest and actual selected style, so they cannot reuse a v1 binding. No app default, asset publication or iPhone qualification is part of this patch.

## Shared pronunciation and stage-structure dependency

Merged SDK `54a2bb0095fe52c9137722f5c0f7cd425adfabc3` at `e23fb0a2470c362c39f1c9eea8e09f3aaf00f956`. This brings shared English numeric readings and Spanish stage/printed-speaker structure into the context branch without changing the optional context implementation. The release check filtered to `KokoroNarrationTests|NativeNumberReadingsTests` passes, including existing context-binding tests; log `/tmp/librox-context-parity-reconcile-tests.log`.

All ten original listening-pair hashes were reverified unchanged. They remain evidence for their recorded earlier code/assets, not the new frontend revision. No audio was regenerated and no context default was enabled. Production context attachment remains gated on listening and incorporating `renderCacheKey` into PCM identity; the frontend revision alone does not supply that context cache separation.

## Listener verdict

Matt's direct response to the four presented Core ML comparisons: “Just listened and they sound good.” Record this as positive listening acceptance for those samples, without inferring an unstated A/B preference or extending acceptance to the unpresented voices/scenes. Exact files and hashes are in `docs/validation/native-context-listening-review.json` and the evidence directory's `listening-review.json`. The original manifests and audio remain immutable.

The SDK chat received the verdict. The next integration work is context-specific PCM cache identity, SDK-owned context attachment and iPhone validation. The original sample-quality gate is satisfied; release/device qualification remains separate. No weights, defaults or audio changed when recording this review.

## All-language dependency and context mapping

Merged SDK `e7cfed982ce94e75d2ad4c665e9f801cc3afa06e` at `c76cf0405b63981b3923507d1dde07aba2dc1bb9`. Context implementation and defaults are unchanged. The only additional code is the isolated `NarrationTextContextLanguageTests` matrix, which reuses the SDK's literal reporting fixtures for all 31 supported languages.

Four parameterized tests (124 cases) pass: exact normalized spoken-token gathering after numeric/dictionary expansion, decomposition and emoji filtering; exact gathered IDs from the pinned production tokenizer; stage-context paragraph isolation; and distinct gather/render identity for repeated quotations. The broader release narration suite passes all 167 tests. The tokenizer test is opt-in with `CT_CONTEXT_TOKENIZER_ASSETS`; it was explicitly enabled for both recorded runs against the v2 assets. It reads the verified indexer table and loads no model. Reproduction and hashes are recorded in `docs/validation/native-context-all-languages.json`.

The initial stress fixture with an emoji before a canonically decomposed reporting prefix yielded no dialogue units in 29 languages before any binder call. That reported gap is now resolved by SDK `6a9d3e2` and verified by the combined matrix below. No casting/catalog/app files were modified beyond merging the owned SDK dependencies.

All four previously approved listening-file hashes remain identical. These structural checks do not establish narration quality, automatic emotion understanding or phone performance in the other languages. The prior user verdict is preserved exactly, without inferring comparative superiority. Context-specific PCM cache identity and deliberate production attachment remain outstanding integration work.

## Decorated and decomposed reporting-prefix fix

Merged SDK `6a9d3e27259213a5931a62de3f3d50aa6e39f1b7` at `f551ae4a65438a15a73aa72c20e967174820cf10`. The matcher uses a local NFC copy and allows leading symbols at line start while preserving original source ranges. No context engine or model changes accompany this dependency.

The context matrix now exercises both the original speech-only Unicode stress and the exact previously failing combined prefix reproduction. All 186 parameterized cases pass, including exact normalized and production-token gathering for both variants in all 31 languages. The full release narration suite passes 169 tests, including the SDK's independent decomposition-only, emoji-only, combined-prefix and preceding-word rejection checks. The recorded parser gap is closed. Current evidence and log hashes replace the active validation record, with prior evidence retained under `previousValidation`.

The four positively reviewed audio files remain byte-identical. No model inference, additional listening acceptance, phone qualification or context default enablement occurred during this reconciliation.
