# Standard library optimization handoff

This SDK owns planning, grouping, immutable conditioning, decoding, acoustic
execution, semantic seam timing, bounded preparation and PCM caching. Librox
supplies document text/settings and owns playback/UI/OS lifecycle. No new
application-side narration engine is required.

## Implemented API

- `ChatterboxBookDirector.plan(..., grouping: .compatibleNarration())`:opt-in
  same-performance narration grouping, at most300characters. Paragraphs, dialogue,
  differing voices/settings/performance remain boundaries. Default `.sentences`
  preserves old segmentation. Revision is `librox-chatterbox-director-2`.
- Each directed unit contains exact `sourceFragments` UTF-16 ranges and a combined
  request/source context. There are **no inferred audio timestamps**. Highlight a
  group unless/until a real sentence aligner supplies acoustic offsets. Input is
  exactly the requested source window; no preceding text is spoken or prepended.
- `ChatterboxMLXRenderer`: Standard-only decoder with the original pinned hashes,
  numerical reference and safety gates. Use instance `profileIdentifier` for
  cache/telemetry. Experimental decoder profiles are permanently retired.
- `renderer.makeNarrator(overlap: true)`:optional structured overlap with one
  decoder and one acoustic worker, not duplicate models. A cancelled batch joins
  the worker before releasing its busy lease. First-audio latency and sustained
  heat must be measured separately; serial remains the default.
- `ChatterboxChunkTimings.acoustics`:encoder/preparation/flow/vocoder/watermark
  wall times, prompt/generated token counts, window and CFM prediction totals.
  Native `synthSeconds` now excludes separately reported watermark time; acoustic
  stage counters include their host preparation/copy overhead.
- `reuseAcousticInputs: true`:optional invocation-owned synchronous x/t buffer
  reuse. Eight controlled watermarked ABBA renders are bit-identical. Timing was
  not convincingly better, so this flag remains **false by default**, including
  the Standard configuration. Solver/CFG/compute policy unchanged.

## Text-to-ready-audio session

`ChatterboxBookSession(narrator:cacheDirectory:modelManifestSHA256:rendererProfile:)`
owns the director, content-addressed current-plus-two cache and cadence. Its
`stream` accepts text/language/voice files/settings; it computes actual hashes,
validates and freezes conditioning in private0700/0600 temporary snapshots, and
cleans only those snapshots after joined work completes. Original voice profiles
and recordings are never rewritten. Snapshot URLs are ephemeral; persist voice
IDs, not those request URLs.

Default `preparation: .playbackLookahead` stops preparation at the audible current
unit plus two upcoming units. On completion of a passage's playback, the host
calls `didFinishPlaying(index:generationID:)`. This is a platform playback event,
not app-owned scheduling logic. Future/out-of-order/stale acknowledgements return
false; a trailing acknowledgement after the stream finishes is harmlessly stale.
Cancel **and await** the stream before seeking, replacing a book/voice or unloading.
For an explicit finite offline job, use `.finiteExcerpt` instead. It prepares only
the supplied bounded excerpt and does not pretend to track audible consumption.

The excerpt cap is32768UTF-8bytes, planner cap128units, each request≤300characters
and≤350generated tokens. Source ranges refer to the supplied excerpt. EOS is not
guaranteed for arbitrary model output; generation-limit failure remains explicit,
with no truncation/retry/fallback to another voice or profile.

## Mac Pro direction

All experimental quantized decoder code, weights and generated trial artifacts
are removed at Matt's request. See `CHATTERBOX-EXPERIMENT-RETIREMENT.md`.
The active target is full-quality native Swift Mac chapter rendering, with the
existing library planning/expression/cadence pipeline and a strict GPU acoustic
seam. The current `LibroxChapterWorker` is a value/state foundation, not a live
remote backend. See `MAC-COMPANION-DESIGN.md` and `CHAPTER-WORKER-CONTRACT.md`.
