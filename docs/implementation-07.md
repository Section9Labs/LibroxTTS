# LibroxTTS 0.7 implementation evidence

Baseline: release 0.6.2, `f75bacfbdc86c0c6dd81f0fb11cb9bcd160e49dd`.
Work is isolated on `codex/0.7-architecture-review`; the Companion checkout is
untouched. These are local implementation and validation results, not a release.

## Contract gates

Before runtime edits, `Release07ContractTests` recorded 128 normalization results
across eight languages and full plan fields for multilingual, numeric, paragraph,
combining-character, CJK, unbroken-text and expanding/shrinking dictionary inputs.
The fixture also freezes serialization, defaults, cache identities and limit errors.
Concurrent callers compare against the same frozen normalization fixture.

`Scripts/check-public-api.py` compares public declarations against 2,802 baseline
macOS module-symbol entries. Reexports count separately; this is not ABI proof.
`Release07AudioTests` captures exact PCM and completed chunk events with verified
English/Spanish Core ML assets before and after changes. Max visits all sampler
counts, repeated graph selection, two voices, Calm/original style, continuation,
receiver cancellation, recovery and unload. Plus replays captured initial noise
and compares traced versus ordinary synthesis. PCM assets remain local.

## Text preparation

`CompiledTextRules` owns a bounded, thread-safe cache of immutable regexes. No
source text or mutable formatter is cached globally. Numeric-only productions
are skipped when no numeric scalar is present, preserving Italian's unconditional
`alle una` correction. The source planner's first-failing-prefix algorithm and
all normalization ordering are unchanged; no monotonic-length assumption is made.

The frozen contract suite passes. Initial Release measurements on the original
Spanish long-clause probe show Plus 16,000-scalar planning falling from 28.910 s
to 4.617 s (6.26×), and Max from 29.609 s to 7.714 s (3.84×). All eight plan
fingerprints match. These are synthetic source-planning timings, not speech
generation speedups. The workstation is shared and some build activity overlapped;
see the final confirmation measurements when assessing the gain.

Raw evidence: [baseline](architecture-07/planning-release.json),
[candidate](architecture-07/planning-candidate-release.json).

## Model residency

`PocketFlowModels` keys by compiled graph name inside a loaded-language owner.
Counts 1, 2, 3, 5, 6 and 7 reuse `flowstep`; 4 and 8 retain specialized graphs.
All eight counts therefore load at most three flow objects instead of eight,
eliminating five redundant loads when a session visits every sampler count.
These are exact loader/object counts, not an inferred RSS percentage. Placement,
asset validation and language retirement remain owned by the existing engine.

Loader tests verify graph identity, retries after failure, reuse after sampler
switches and release on retirement. The exact-audio gate exercises the actual
models across the same settings. Text-only preview separation and voice prompt
caching remain deferred: both have additional warming/ownership semantics that
this change intentionally preserves.
