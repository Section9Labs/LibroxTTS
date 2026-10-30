# Chatterbox expression and pronunciation routing

## Current verified coverage

The multilingual pronunciation resources have 793,586 entries across eight
locale profiles: es105,910, es-419129,677, es-AR130,622, fr88,259, it91,902,
pt-BR37,425, hi27,672 and zh182,119. Counts were checked against the 16-byte
packed-index headers and adjacent manifests, without scanning corpus content.
Spanish locale inventories overlap; this is not 793,586 distinct words or
languages. English/Japanese stores are separate and excluded from that sum.

These entries primarily return IPA/phonetic readings for the existing
pronunciation engines. Chatterbox uses its own grapheme/text tokenizer. The
current `ChatterboxNarrationBridge` sends original natural-language text,
conditioning and model scalars; it deliberately does not send Kokoro phonemes or
style vectors. The large dictionaries therefore do not automatically improve
Chatterbox pronunciation. Model-compatible names, homographs, numbers,
abbreviations, language/dialect and reviewed spoken aliases need a dedicated
text-native adaptation with exact source/spoken-text maps and listening tests.
Do not feed IPA into a grapheme model or mass-respell every word.

The existing expression layer is real but small:12 delivery labels (including
neutral),6 mood labels and7 speech-act labels. Automatic lexical/reporting-clause
rules currently target EN/ES only. It preserves explicit evidence, negation,
source ranges, dialogue roles, cast identity and punctuation/structural cadence.
It is not a multilingual chapter-context classifier or an emotion guarantee.

`ChatterboxBookDirector` storyteller mode uses these cues to choose a small set
of intensity values (maximum1.0), CFG .25/.3 and default temperature.8. The
renderer already accepts the model request's full bounded exaggeration0..2,
CFG0..2 and temperature.1..2. The gap is how the director selects/exposes those
controls, not a missing scalar connection to the decoder.

The upstream expressive demos include reference/output comparisons and
exaggeration .5/1/2. Multilingual can be expressive without explicit named tags.
The upstream README separately documents native paralinguistic tags for Turbo;
that distinction is not evidence that the multilingual model lacks emotion.
References:
- https://resemble-ai.github.io/chatterbox_demopage/
- https://github.com/resemble-ai/chatterbox
- https://huggingface.co/ResembleAI/chatterbox

## Added reviewed directions seam

`ChatterboxPerformanceDirections` binds up to128 reviewed annotations to the
exact <=32KiB source excerpt. It rejects stale/canonically changed text, invalid
ranges, overlap, partial planned-unit intersections and unused annotations.
It preserves book words, voice/conditioning, source ranges and max-token/seed
contracts. It never inserts tags. No annotation leaves existing defaults and
cache identities unchanged. This does not extend existing excerpt/chapter limits.

An annotation can carry a descriptive `NarrationPerformanceOverride`, explicit
`ChatterboxExpressiveControls`, or both. Explicit numerical controls take
precedence over the director's automatic intensity suggestions; the original
renderer bounds remain unchanged. Different annotation boundaries stay distinct
during grouping. A single annotation may cover several complete planned units.
The canonical expressionSHA256 covers source, ranges, text hashes, intent,
strength and all explicit scalars; bind it to the chapter recipe's expression
identity. Existing raw-PCM cache keys already cover actual scalars and text.

Named delivery remains an intent. Lowering intensity is not proof of whispering;
raising it is not a guaranteed shout. This is a usable control/annotation seam,
not a completed automatic expression detector or proven auditory improvement.
No learned model weights, solver schedule, output/resource/numerical gates or
original source texts are modified.

## First book audition

A single101-word paragraph from bundled Moby-Dick Chapter1, beginning
“But look! here come more crowds…”, is preregistered with source file hash and
original UTF16 range in owned book-expression-audition-v01. Stock voice,
exaggeration.9/CFG.3/temp.8, seed42, native full-F32 acoustics, ten cosine CFG
steps/.7, deterministic-gather-2, watermark disabled and AAC-only delivery.
This is an authored-controls audition atop the existing director. Actual
per-unit scalars, source coverage, output frames and complete warm timing are
recorded. Listening approval is pending; do not claim automatic detection,
pronunciation improvement, full chapter/cloud support or5x from this sample.

Audition completed:32.56s audio,26.3253s complete warm generation+AAC+decoded
verification (1.23683x),297,759 bytes,7 units; startup145.871s separately.
Actual per-unit scalars/source coverage/cache/export hashes were independently
reviewed. The scalar settings are authored, not newly inferred emotions. This
real-book result is slower than the previous short2.5x controls;5x is unmet.
Decoder prefill+decode totals23.307s and acoustic totals11.908s overlap and
must not be added as wall time. Owned child joined; no other model job remains.

Final annotation validation additionally checks actual String grapheme boundary
indices, explicitly excluding half-surrogate and mid-grapheme spans. This is a
post-audition rejection-only tightening; the immutable audition is bound to its
frozen source snapshot, not a claim that a later binary produced that file.
