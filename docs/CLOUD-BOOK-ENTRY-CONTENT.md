# Exact book-entry source and options content

This package-internal component carries one original-spine entry's exact text
and portable authored render plan, or its exact literal silent text. It does
not publish current book intent, acknowledge demand, claim a Worker, publish an
ordered segment head/seal, supply a catalog, or activate a service/factory.

`ChatterboxBookEntryContent` is created from the SDK prepared book and actual
entry. It validates the source-bound recipe and complete options fingerprint.
The canonical V1 envelope preserves exact UTF8 including NFD, CRLF, FFFC and
control bytes, authored Float32 patterns, UInt64 seed, nil versus empty authored
directions, grouping and delivery. Literal empty/whitespace/FFFC entries carry
their original text and are independently reclassified; meaningful front matter
cannot become silent proof or zero-frame audio. No producer epoch, local path,
source/plan journal reference or voice recording/conditioning bytes are encoded.

The receiver supplies its OWN current session, the exact prepared book and
original spine index, and an expected content identity admitted from separate
authenticated current controls. Decoding reconstructs a new receiver submission,
validates the complete current planner/policy, and requires exact canonical
re-encoding. Historical metadata alone does not authorize a current fingerprint
or model. The Worker must still rebind against its actual prepared backend and
hold current intent/generation/lease fences before inference.

`ChapterCloudBookEntryTransport` stores immutable content in the proposed private
`LibroxProChaptersV1` zone, record `LibroxBookEntryV1`:

- record name `be-<SHA256(canonical identity)>`;
- `manifestV1`: canonical Bytes, at most 4096 bytes;
- `contentV1`: CKAsset, exact canonical content at most 8 MiB;
- identity binds account partition, scope, original spine index, source/plan or
  literal-silent kind, payload size and SHA256.

The 8 MiB cap accommodates the bounded exact text and base64 portable plan; it is
a private-capture/read/validation cap, not a bound on opaque CloudKit wire/cache
traffic. Each source and plan retains its existing independent source/plan limits.

Uploads create a private 0400 captured file with bounded chunks and before/after
hash/FD/path checks. The capture remains alive through native operation completion.
Downloads admit exact metadata before requesting an asset, then capture INSIDE
the per-record callback before CloudKit staging may disappear. The own-epoch
reader validates actual captured bytes before typed planning decode. Result slots
clear private custody; weak operation captures avoid a callback ownership cycle.

Create-if-absent conflicts or a lost native acknowledgement reconcile ONCE by
fetching metadata and verifying the full actual content bytes. Local file/hash,
typed validation, storage and cancellation failures are not uncertain network
retries. The live host authorization closure runs before EVERY native operation,
including reconciliation. Native operations use the existing owned Foundation
completion/cancellation join and explicit 15-second request/30-second resource
configuration; those settings are not a guaranteed wall deadline.

No native CloudKit container was instantiated, no zone/schema was deployed and
no live operation is implied by offline store tests. These tests do not establish
server immutability against an adversarial writer, signed host/path authority,
aggregate quota, durable source adoption or cross-host recovery. Metadata/content
existence is not a book acknowledgement, inference/playback authorization or
completion. The source/options must remain durably owned until authoritative
control acknowledgement. Control/lease/head transport, durable cloud admission,
real prepared catalog and separate-host book factories remain unfinished.
