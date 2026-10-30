# Incremental book delivery

Matt's current requirement is one durable whole-book preparation request, with
listening-position priority and independently usable files uploaded as they
finish. Play/pause belongs to listening; pausing does not withdraw preparation.
The native Companion remains the renderer. Catalyst/iOS Reader uses shared
Planning/Worker products and real iCloud transport, never a second renderer.

## Implemented native segment seam

`ChatterboxMacResidentRenderer.renderSegments(binding:gate:outputDirectory:admission:receive:)`
uses the same complete-source planning, context windows, authored expressions,
grouping, seeds, cadence, Standard decoder and F32 acoustic backend as the
existing chapter method. It does not replan each segment. Every delivered
passage is independently encoded and actually decoded/verified before `receive`.
The callback runs before later passages finish. There is one owned stream; its
callback and exact detached encoder are joined before shutdown returns.

Callbacks must return or throw when cancelled and must join their owned native
transfers. Do not await renderer shutdown from inside its own callback; signal
cancellation/throw, then join from the supervising owner. No detached uploader
may outlive the callback/worker ownership chain. The first version applies
backpressure by awaiting publication; bounded overlap is a later optimization.

`ChatterboxMacSegmentExport` is an actual complete producer file and manifest,
not a CloudKit acknowledgement or playback grant. Files remain immutable after
export. `ChapterLocalSegmentArtifact.adopt` performs the existing bounded private
copy/hash/codec/frame/sample validation under the receiver's own account epoch.
Its underlying partial-range verification handle is private and cannot be
passed to the complete-chapter outbox acceptance API.

No factory/provider activates this seam yet. Soft storage allowances must cover
the producer/custody/publication chain, and cloud authority/leases/publication
acceptance still need implementation and signed-host qualification.

## Ordered metadata and completion

`ChapterSegmentManifest` binds account partition, chapter render key, index,
previous canonical manifest digest, exact global UTF16 source coverage, global
chapter starting frame and local-file audio/frame maps. Each file is bounded
to121 seconds/16MiB; up to4096 passages and8MiB aggregate native metadata.
Complete source text is required for source/grapheme coverage validation.

`ChapterSegmentPrefix` accepts only the exact next index/digest/frame/source
position. Duplicates and out-of-order arrivals cannot advance the prefix or
replace existing files. The service can treat an identical already-stored ID
as idempotent metadata reconciliation; conflicting duplicate bytes fail. A
missing segment remains missing. No omitted spoken text, grapheme split or
fabricated word timing is admitted. Only whitespace/attachment placeholders may
occupy unspoken gaps, including the trailing source suffix.

`ChapterSegmentCompletionSeal` is produced only after the full ordered source
prefix is covered. It proves neither upload nor download nor Reader custody.
A verified early segment may be played without waiting for that seal. A chapter
seal is separate from the book seal, which additionally needs every original
spine entry accounted for. Completed files survive cancellation; incomplete
streams never receive a chapter seal.

## Seeking, late files and app lifecycle

The forthcoming service will persist durable preparation independently of the
listening priority. A seek changes priority/prefetch, not the audible recipe or
preparation wanted state. Exact global source ranges locate the segment; local
decoded frames locate playback within it. No word-level timing is invented.
Already verified segments are reusable under the same exact request. If the
target is absent, Reader waits/prefetches the target and subsequent segments;
it does not replay an unrelated old segment or claim the chapter complete.

An immutable late file can remain stored for future exact reuse, but account
epoch, current book intent/generation and exact request must be rechecked before
installing it in the playback queue. Cancelling observation releases its owned
observation work, not preparation. Closing the service cancels/joins its calls
and streams and releases live handles, preserving durable intent/completed data.
The native host event directly calls synchronous `stopClaims`, then awaits the
worker/supervisor join barrier. Local process locks are not CloudKit leases.

## Whole-book source binding

`ChapterBookSource` binds verified original book SHA, extraction revision and
ordered original Reader chapter keys. App extraction may be lazy and must not
navigate the Reader. No fake source text/hash is supplied for missing entries.
Every narratable chapter uses its actual source-bound prepared pair, including
authored Float32 expression controls, seed, grouping, direction and delivery.

`classify(text:chapterIndex:)` produces a normal `ChapterSourceIdentity` for
meaningful text or an SDK-authored `ChapterBookSilentSource` for literal empty,
whitespace/FFFC-only text. Original spine indices never change. Titles and
copyright/front matter with other characters remain narratable. Silent entry
acceptance must still be durable/current-book fenced, without a zero-frame
audio file or silently omitted requested chapter. The existing nonempty chapter
identity and whole-chapter validation limits are unchanged.

## Current evidence and remaining cloud work

Synthetic narration plus real codec tests show first-segment private adoption
before the chapter seal, exact concatenated PCM equality with the original
whole-chapter path, correct global source/frame maps and cancellation/join
without sealing partial output. No production model/inference was run for this
change. These are not actual iCloud, full-book, signed-process or speed proofs.

The actual iCloud service still needs durable book intent/priority and entry
admission, authenticated backend catalog, exact source/plan transport, owned
worker generation/lease/fence, independently complete segment CKAssets,
authoritative ordered head/seal publication, Reader private adoption/current
intent acceptance, restart recovery and real two-host/phone playback acceptance.
Metadata/content existence alone must never acknowledge wanted state or make a
segment playable. No CloudKit zone/schema/call or shipping factory is activated
by these component APIs.

## AAC issue discovered by the first actual chapter

The immutable Alice v33 raw PCM completed578.85 seconds, finite peak.99000001.
AAC64 reconstruction had exact13,892,400 frames but24 samples above absolute1,
peak1.05738616. The existing strict readback guard rejected the file. A bounded
codec-only reproduction confirmed this without model rerun. The exporter now
reports `decodedSampleRange(codec:index:value:)` instead of generic `input` at
that guard. No threshold change, normalization, limiter, clamping, silent codec
fallback or automatic retry is introduced. AAC remains unavailable for an
individual export that fails this guard; its fixed delivery policy requires a
separately explicit/cache-bound reviewed solution before that export can ship.
