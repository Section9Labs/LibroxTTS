# Shared narration pipeline candidate

This branch addresses the audible app-versus-audition regression reported on 6 November 2026. It is a candidate for listening review, not a claim of improved perceived quality or a new model-weight release.

## Host contract

Book playback, head-start preparation, previews, installation probes and exports should all call `NarrationPipeline.plan`. Pass the selected model, preferred narrator, optional explicit language, book metadata language and bounded original source. Persist its optional cast; render its units through `NarrationRenderer`. The app owns playback and lifecycle, not model tokenization or linguistic planning.

`NarrationLanguage.detect` uses explicit book metadata first, then bounded on-device text detection. User language overrides take precedence. `model.supportedLanguageCodes` and `model.resolvedVoiceID` provide the same catalog to all host surfaces. Unsupported languages fail explicitly without substituting a different engine.

Plus now exposes the pinned Supertonic 3 helper's 31 languages. Every language has a preview in that language. Mandarin is supported by Kokoro but is not among these CT languages. Upstream capability is documented at https://huggingface.co/Supertone/supertonic-3#supported-languages. Additional languages have desktop render smoke evidence, not native-speaker listening qualification.

## Pronunciation and expression

`SpokenTextLexicon` supplies shared, reviewed written-to-spoken readings (names, abbreviations) without rewriting book text or reading offsets. Text-native rendering also uses the existing language-specific number/date/time/currency normalizer where available, plus the English cardinal reader. Kokoro retains its full existing pronunciation dictionaries, stress and phoneme adapters.

The large Kokoro dictionaries contain phonemes, not interchangeable CT input. We do not transliterate IPA back to invented spellings or claim that CT consumes that dictionary. Model-independent spoken readings apply to both adapters; direct phoneme enforcement remains a Kokoro capability. The current shared dictionary extension API does not add an app editing UI or convert the existing IPA dictionaries into reliable native-text readings.

All units carry shared punctuation/prosody evidence. Kokoro's optional explicit-dialogue focus is no longer restricted to the enhanced profile. CT uses the written context and its trained native prosody, without synthesized emotional instructions, pitch processing or invented performance tags. This does not promise that the more expensive model is more expressive on every passage.

## Context and audio fixes

The previous native planner cut at 280 UTF-16 units and the helper could add a period to a continuation. Planning now measures normalized CT tokens, preserves complete sentences where they fit, handles grapheme clusters and multilingual expansion, and marks true continuation boundaries. The renderer disables synthetic terminal punctuation. If predicted duration exceeds the graph's 30-second bound, it splits conservatively and retries with a bounded recursion depth.

The Plus renderer delivers 44.1 kHz mono Float32. Hosts must use `model.outputSampleRate`; Kokoro remains 24 kHz. Plus no longer adds a fixed 220/320 ms after every passage. It applies one F1 gain calibration (-7.6386552821693705 dB), measured from the frozen accepted English reference at -16.36134471783063 LUFS, rather than normalizing every passage separately to -24 LUFS. A separate constant reduction prevents peaks above 0.98; no compressor or hard clipping is added. The legacy reference loudness mode remains available for matched diagnostic auditions.

Changed text, delivery and planning identities invalidate prepared PCM caches without redownloading unchanged model weights. The app bypasses AVAudioUnitTimePitch at 1x. Cache disk/memory budgets and GPU-foreground/CPU-background retirement remain intact.

## Evidence and remaining acceptance

`swift test` covers all prior SDK suites plus shared language/voice resolution, 31 language previews, normalized token bounds, continuation punctuation, source-preserving readings across adapters, and relative loudness preservation.

`narration-pipeline-probe ASSETS OUTPUT` runs all 31 language previews through the actual public model and renderer, then creates English/Spanish before/after comparisons. Its before path reproduces the 280-character planner and passage gain/pause behavior. Both audition files use 44.1 kHz and one final full-clip gain for equal overall loudness. It uses deterministic diagnostic noise; different text/duration requires a different noise tensor shape. These are desktop processing-path comparisons, not recordings of the installed app.

The optional `PASSAGE.txt` argument performs a controlled English paragraph comparison instead. With frozen `reference-report.json`, `reference-noise.bin`, `reference-text-ids.bin` and `reference-raw.bin` in OUTPUT, it requires matching source text, token IDs, noise shape and sample count before reporting conversion error. `LIBROX_PROBE_BACKEND` selects a diagnostic backend, defaulting to `coreMLGPUHeavy`. See [the Moby-Dick comparison](MOBY-DICK-COMPARISON.md) for evidence and its limits.

Required before acceptance: Matt's English/Spanish listening judgment; actual iPhone/iPad download/cache/seek/rate/lock-screen playback and memory checks at 44.1 kHz; native-language pronunciation review beyond English/Spanish; preview/language-menu device UI checks. Do not infer those from passing tests or waveform metrics.

The actual EPUB reproduction additionally covers blank/indented paragraph separators, single-quoted dialogue, and long quoted sentences. These previously threw `unbreakableText` in the candidate. Native planning now tokenizes within paragraphs and ignores nonspeaking tokens; source offsets remain exact and leading punctuation can be scanned before the first word. Revision `ct-context-tokens-3` invalidates earlier candidate planning identities. Synthetic regression fixtures cover LF, CRLF and Unicode paragraph separators without publishing private book text.
