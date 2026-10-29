# Library optimization and experimental8-bit phone handoff

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
- `ChatterboxMLXRenderer(..., decoderProfile: .q8ExperimentalV1)`:explicit packed
  Q8 loader. Default mixed-FP16 profile and its identity/gates remain unchanged.
  Always use the instance `profileIdentifier` for cache/telemetry, not legacy
  static `ChatterboxMLXRenderer.profile`.
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
  the recommended initial phone configuration. Solver/CFG/compute policy unchanged.

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

## Q8 artifacts and gate

Owned test artifacts, not publicly released:

| File | Bytes | SHA256 |
| --- | ---: | --- |
| `local-backbone-q8-g64-f16scales.safetensors` | 568662708 | `231647ebb4deedad901c46cf3d7ca1e0fa70371b461c934c14dc63f16ec69017` |
| `q8-dense-cpu-reference-v01.safetensors` | 2698781 | `8f7b5d2a6437c23cfa753f0ac25e2f23f296ca32f3e91b98b3f6219b26325b44` |

Both are in
`/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01/`.
The frontend, CoreML acoustics and Perth assets remain the installed exact V3
assets. Do not substitute smdesai weights or a different language pack's frontend.

Named profile:`native-mlx-q8-g64-f16-affine-experimental-1`.
The independent intended-Q8 reference unpacks the exact artifact into ordinary
dense FP16 CPU projections, preserving FP32 norms/head/accurate activations and
correctly advanced separate KV states. It does not call quantizedMatmul or the
Metal projection path. Candidate GPU checks pass18/18 against this reference at
unchanged max-abs≤.05/relative-L2≤.002/both-CFG-top1 criteria (observed maxima
.0111895/.00087757). File identities and all692tensor keys/dtypes/shapes are checked.

This is **implementation clearance for an explicit experiment**, not equivalence
to the original FP32 model:that separate comparison remains3/18. Decoder parameter
memory falls45.35%. Neither speaker quality, phone throughput nor battery acceptance
follows from this implementation gate. Matt explicitly authorized the8-bit trial;
the sound and sustained-phone result remain open.

## Validation and measured limits

57 Release library tests pass, including source/group boundaries, voice mutation
isolation/private snapshot cleanup, real lookahead permits, stale acknowledgements,
cancellation/restart, caching, buffer Float bits and batch routing. Independent
read-only review found no remaining blocker after the snapshot/backpressure fixes.

Preliminary real-asset optimized Mac EN/ES comparison, identical input text/settings
and seeds, CPU acoustics+Perth; generation histories differ with grouping:

| Path | EN RTF | ES RTF | Units per language |
| --- | ---: | ---: | ---: |
| Sentence units, serial | 1.229 | 1.109 | 7 |
| Grouped, serial | .801 | .750 | 2 |
| Grouped, overlapped | .670 | .672 | 2 |

RTF uses actual generated frames, excluding added seam silence. These are short
Mac trials, not5× playback or phone/energy proof. The overlap path is roughly
1.49× real time here; target is5×. Acoustics remain the large remaining cost.
Receipts/configs:`implementation-v01` under the artifact root above. The final
private-snapshot/backpressure changes are covered by tests and a final real-asset
validation; the timing comparison is preliminary and precedes those metadata fixes.

## T3 integration and phone check

Use a distinctly numbered local build. Keep compute units CPU for encoder/CFM/
vocoder/Perth initially, preserve TF32/memory/thermal/output guards and watermark.
Select the experimental profile explicitly, update manifest files/sizes/hashes and
cache identity, and retain the default backend as a separate explicit profile—no
automatic fallback. Do not delete old model assets until the new install verifies;
preserve all saved voices, book state and unrelated downloads.

Prefer the BookSession interface so Librox does not duplicate the scheduler/cache.
Alternatively the lower-level plan/narrator APIs remain available for a bounded
integration check, with planning/scheduling algorithms still exclusively in the SDK.
Collect actual request conditioning identity and all substage counters. Test stock
voice first, then Matt's recorded voice **on the phone only**. Keep PCM/output
acceptance independent of the Q8 implementation oracle. No app install/launch or
phone workload until Matt confirms current availability for the ready build.

No release, merge, TestFlight, private audio export, watermark removal or old unsafe
GPU/ANE run resumption is part of this handoff. CoreAI/acoustic acceleration toward
whole-pipeline RTF≤.20 remains a separately versioned next stage.
