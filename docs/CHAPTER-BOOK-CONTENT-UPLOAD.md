# Finite owned book-content upload reconciliation

This package-internal step connects durable Reader pending content to the native
immutable CKAsset transport. It does not register a service/factory, publish book
demand or grant Worker/playback authority. No live CloudKit qualification is
implied by offline record-store tests.

`ChatterboxBookContentUpload.reconcileOne` atomically observes ONE current wanted
book intent and priority-ordered pending entry. It requires the exact book,
Reader session/account, own current gate and matching transport session. Both
the retained-content and private-capture roots must belong to the supplied soft
artifact budget. No pending entry means no transfer, not catalog/ready/completion.

The owned producer actually reads and verifies the retained bounded content,
reconstructs its exact source/plan or literal silence, and compares against the
specific admitted chapter request/silent hash. Common book settings alone do not
select per-chapter authored expression controls. It rechecks current intent
before invoking transport. Each native operation still checks live host transfer
authorization and its own session; cancellation remains owned through Foundation
completion and private capture cleanup.

The native transport returns a package-only `ChapterBookContentServerReceipt`
constructed from its admitted server snapshot: exact identity, current operation
session, opaque revision bound to account/record key/tag/metadata hash, and either
acknowledged upload or actual full-byte verification of existing content. No
producer epoch is serialized to CloudKit. This receipt is a PAST content
observation, not a clock, lease, current book acknowledgement or media receipt.

The Reader reserves24 MiB soft retained growth for bounded upload/reconciliation
captures plus metadata headroom. The exact original producer and all its native
and detached children JOIN before settlement. Only after successful settlement
does the outbox atomically confirm the actual content receipt against the exact
current wanted intent and identity. Book pending/server acknowledgement remains
unchanged. Late cancel/seek/re-request, changed source/plan or account/cancellation
returns no successful current confirmation, even if immutable remote content
exists. Late storage failure preserves complete local/remote material and does
not acknowledge it. These allowances are not OS, wire/cache or prewrite native
transient quotas.

No uploader escapes the awaited call. The eventual Reader service must OWN its
calling Task and signal/cancel/JOIN it before closing account/outbox/budget.
This component creates no perpetual loop or independent task. A lost local
confirmation leaves pending content; an explicit later current operation can
reconcile existing remote bytes without another insert, source publication or
model call. A fully confirmed unchanged queue performs no more store I/O.
Local corruption fails before transport and never becomes a network retry.

Still unfinished: durable authoritative whole-book cloud controls/read sets,
authenticated actual prepared-backend catalog, Worker claim/generation and clock/
lease policy, ordered segment heads/seals, current Reader audio acceptance and
separate-host factories/signed runtime/live transfer/playback qualification.
No model, app, phone, portal, schema or zone operation is required by this source
checkpoint.
