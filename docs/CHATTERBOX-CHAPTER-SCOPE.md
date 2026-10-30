# Explicit bounded chapter scope

`ChatterboxBookSession.streamChapter` is the new SDK-level finite chapter stream.
It plans the complete exact source first, then renders using the existing bounded
three-unit windows. Global source indices, attribution context, one generation,
one cadence state and immutable conditioning snapshots persist across those
windows. There is no hidden excerpt splitting or per-window cadence reset.

This is a low-level library seam, not a finished app provider or whole-chapter
file writer. The SDK resident renderer must own encoding, source-map assembly,
checkpointing and complete artifact publication; the app supplies authorized text
and consumes that eventual high-level service. No cloud/backend readiness follows
from this API.

## Admission and identity

| Policy | Existing excerpt APIs | Explicit chapterV1 |
| --- | --- | --- |
| Story metadata | 16,384 Unicode scalars /256 dialogue annotations | 131,072 UTF-16 units /393,216 UTF8 bytes /4096 annotations |
| BookSession input | 32,768 UTF8 bytes | 131,072 UTF-16 /393,216 UTF8 |
| Directed units | 128 | 4096 |
| Performance sidecar | 32,768 UTF8 /128 annotations | Chapter source limits /4096 annotations |
| Single performance annotation | Existing32KiB exact-text/grapheme guard | Same unchanged guard |
| Default compatible grouping | Existing API defaults preserved |160 characters; same speaker/direction/paragraph boundaries |
| Model frontend, token and acoustic limits | Unchanged | Unchanged; this does not make every text/token shape admissible |

Legacy direct planning retains its original scalar guard; the session's byte
limit is not newly imposed on direct callers. Old phonemizer limits are unchanged.
The chapter entry is explicit and bounded. Excessive source/unit counts are
rejected before any unit is generated. Chapter planning checks cancellation at
entry and between planned units.

`ChatterboxNarrationScope.chapterV1` gives render caches a separate
`chapter-scope-1:source131072:units4096` suffix. Excerpt suffix is empty, preserving
existing identities. Performance directions bind their scope into their canonical
expression digest, and a sidecar for the wrong scope is rejected. Existing model
controls and their finite/range checks remain unchanged; there is no text/voice
rewrite, automatic phoneme injection or new acoustic emotion guarantee.

Whole-source quote metadata is planned before synthesis windows: a dialogue span
can cross the old16Ki-scalar/32KiB boundaries without becoming narration halfway
through. Unsupported/nested quotation styles remain conservative narration as
before; no character identity or alternate voice is guessed.

Source fragments retain exact global UTF16 ranges, including decomposed Unicode
and extraction placeholders. Each generated unit has actual post-cadence frames.
There are no estimated per-fragment/word audio timestamps.

## Evidence boundary

Existing adapter regressions and new fake-renderer tests cover long source beyond
32KiB/128 units, continuous cadence/global ranges and indices, conditioning scope,
legacy guards, many reviewed expression controls, cache separation, pre-render
unit-budget rejection and quotation context across the old boundaries. Fake PCM
establishes orchestration mechanics only. It does not establish real long-chapter
voice quality, model throughput, file export or installed-host playback.

The signed LocalReview353 grant is a separate synthetic app fixture, SDK5709bef,
with no model inference, downloads, live account/cloud, login or original-app
launch. New chapter code is not silently substituted into that pinned artifact.

The local checkpoint passed all75 Release adapter tests, including the original69
regressions and six chapter-specific tests. Independent source review found no
remaining blocker for this code checkpoint, including the final cancellation and
Unicode/placeholder/long-quote cases. No model inference, new audio, codec export,
cloud call or signed-host launch occurred in this stage.
