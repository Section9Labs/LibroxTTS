# Native migration validation — 2026-11-07

Host: Mac15,14, Apple M3 Ultra, 256 GiB RAM. Swift 6.4/Xcode 27 toolchain.
This is developer-machine evidence, not phone or minimum-Mac qualification.

- Debug and release native executable builds passed.
- Published all 217 hosted files after verifying GitHub SHA-256 digests and
  sizes against the pinned manifests. A clean English installation through
  `NarrationAssets.download` verified 31 files (371,942,978 bytes) and rendered
  4.8 seconds of audio successfully; see `hosted-install.json`.
- Full `swift test` passed (496 Swift Testing cases reported across targets, plus
  the package’s XCTest tests). Opt-in asset tests were also run separately.
- Generic iOS `LibroxTTS` build passed with code signing disabled. This proves
  compilation, not physical iPhone GPU lifecycle/background behavior.
- All 25 retained English voices rendered a two-sentence passage successfully;
  see `english-voices.json`. This is a synthesis smoke test, not ASR or listening
  acceptance for every voice.
- Seven standard language models loaded and rendered their default voice.
  See `audition-m3-ultra.json`: 6.0–9.2 seconds of audio per sample. After the
  first cold Metal run, complete process load/verification/render took roughly
  0.66–0.86 seconds. This high-end machine is not a consumer speed guarantee.
- All seven CPU/Swift tokenizer/chunk checks and fixed-input frame comparisons
  passed. Maximum latent absolute error: 0.0000254. Maximum decoder sample
  absolute error: 0.00000191. Assertions cap both at 0.0001. See
  `numerical-parity.json`. Each language compares 15 latent and 16 codec steps.
- Whisper large-v3-turbo transcriptions match every word in all seven short
  samples after normalizing punctuation/case. See `asr-m3-ultra.json`.
- Tests cover model catalog/IDs, source ranges, persistent character cast,
  unsupported language selection, background GPU rejection and actual shared
  pipeline → renderer → native PCM (opt-in installed-asset test).

A comparison initially failed because the community Swift implementation used
exact GELU while current Kyutai uses tanh GELU. The migration corrects that for
both FlowLM and Mimi. Assertions were tightened after the correction.

Not established: perceptual superiority to Plus, all 175 voice/language pairs,
long-book/endurance/thermal behavior, physical iPhone/iPad runtime acceptance,
or a shipped Librox app update. The tiny English models, 24-layer previews and
arbitrary-reference cloning are outside the hosted preset pack qualification.

## Adaptive phrasing update (runtime v2)

The current runtime replaces the fixed 25-token production splitter with
configurable sentence-aware grouping. The earlier numerical results validate
unchanged model operators and the retained upstream reference splitter, not an
assertion that adaptive chunk plans equal upstream plans.

- Full package suite and generic unsigned iOS build passed again.
- All 14 Pocket tests passed with installed packs and reference fixtures enabled,
  including source/cast preservation, shared-voice speaker separation, role
  targets, protected passages, bounded clause/word fallback, Unicode/decimals,
  invalid options, cache identities, real-tokenizer previews and native rendering.
- Seven fresh default-voice renders succeeded. ASR matched six normalized word
  sequences exactly; Portuguese had an `a`/`ao` discrepancy. The source of that
  discrepancy (synthesis or recognizer) is not established.
- A longer English narrative rendered 18.96 seconds in three chunks (24, 53,
  22 tokens), preserving the short follow-on sentences with their preceding
  thought and resetting continuation at the paragraph. ASR reported `things`/`thing`
  and `Then`/`And` differences; word fidelity remains open for listening review.
  The comparison and complete plans are in `adaptive-chunking.json`.

These are structural/content checks. Choosing pleasant narration targets still
requires listening; the 48/32 soft targets are starting points, not tuned presets.

## Controlled listening suite

Generated 106 English/Spanish WAV clips (1,860.24 seconds) across ten language/voice
combinations, three original passages, temperatures 0.15/0.30/0.45, three phrasing
policies, sampler steps 1/2/4 and repeat takes. A same-seed rerun matched the original
WAV byte-for-byte. All clip hashes and token caps were verified.

ASR matched normalized words exactly for 37 clips; 69 have review flags. Those are
not 69 confirmed synthesis failures, and the 37 matches are not listening approval.
Peter Yearsley/English/balanced and Lola or Alba/Spanish/short matched all three
passages at temperature 0.3, one step, seed 42. They are candidates for listening,
not selected winners. See `listening-suite.json` for per-configuration evidence.

The local HTML page supports playback, language/passage/round filters, ratings,
shortlists, chunk inspection and JSON export. Browser checks verified playback,
filters, rating/shortlist state and exported settings; temporary test ratings were
cleared. All 15 Pocket tests reported passing (four opt-in asset tests skipped);
the generated suite itself exercises native synthesis with installed weights.

See `Scripts/PocketTTS/LISTENING.md` for reproduction. Audio and the complete
manifest live in ignored `Benchmarks/Narration/results/pocket-tts-2026-11-07/listening-suite/`.
No production preset or app default has been changed.
