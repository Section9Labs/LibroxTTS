# Native whole-book device intent and membership CAS

This internal transport writes actual native CloudKit operations for current
device preparation plus the book membership root. Source/offline tests are not
live CloudKit qualification or a shipping service/factory. It creates no zone,
deploys no schema and does not start models or publish segment heads.

Proposed private zone `LibroxProChaptersV1`:

- `LibroxBookDemandV1`, `bd-<scopeID>`: canonical `payloadV1` Bytes<=16 KiB,
  account/scope, logical root revision, up to32 retained device IDs and exact
  canonical device-payload digests. Scalar `accountV1`/`scopeV1` support later
  bounded discovery; query/index deployment and discovery are NOT implemented.
- `LibroxBookDeviceV1`, `bi-<scopeID>-<deviceUUID>`: canonical `payloadV1`
  Bytes<=16 KiB, exact Reader device intent and confirmed immutable full-book
  read-set identity when wanted. No Play/Pause or ready/media bit exists.

Publishing wanted state consumes the WHOLE exact read set and its native
content receipt under the own current operation session, and recomputes the
full identity. A source hash alone cannot invent an uploaded read set. Explicit
cancellation needs no replacement asset: wanted=false has no read-set pointer,
updates ONLY this device and retains every other member/tombstone. Pausing
listening must never call cancellation. Source/priority changes are revisions
of the same durable preparation; wantedRevision preserves transition history.

Every device mutation saves its device record AND membership root atomically
with `ifServerRecordUnchanged`, using the exact held server change tags. This
prevents cooperating writers from overwriting additions/cancellations. Existing
root/device payload digests must agree. Mixed snapshots fail closed instead of
repairing/overwriting. Same-revision different bytes reject; older revisions
never overwrite newer ones. Wanted counters are monotonic with consistent
transition parity; root counters never wrap. Membership exhaustion refuses new
members rather than dropping stored data. No records/assets are deleted.

Exactly matching current device state read back from a valid root is idempotent
and does not write again. A native uncertain/conflict write acknowledgement gets
ONE bounded readback: only actual exact desired member plus matching membership
returns a receipt. A newer/different state is not acknowledged or overwritten.
Local metadata/canonical errors remain local/permanent, not network uncertainty.
Nested native failures retain existing classification/backoff semantics.

The owner supplies mandatory current-Reader-intent validation and live control
transfer authorization. Account/epoch/cancellation/current intent are checked
before and after each await/operation. The exact original native operation is
owned until Foundation completion, including cancellation, with existing15s/30s
request/resource configuration. Settings are not a guaranteed wall deadline.
The caller/service must own/cancel/JOIN its calling Task before closing storage.
A late commit may physically exist after local cancellation, but returns no
successful current receipt; later newer cancellation fences it by CAS.

The returned device receipt acknowledges ONLY this device's exact preparation
intent, under its own current session. It is not source transfer completion,
book/chapter/audio completion, media custody, a clock or a Worker lease. The
Reader still atomically confirms against its actual current outbox and replays
durable confirmations. No global rendering/ready phase is a device receipt.

## Mandatory later Worker fences

The membership root is useful ONLY if every future Worker claim/publication
transaction also conditionally compares this exact root plus all authoritative
member records and its own generation/claim/head read set. Discovery queries,
immutable assets and past receipts alone authorize no inference. No Worker
claim/fence, expiration/takeover clock policy, ordered segment head/seal or
current Reader audio acceptance is implemented here. Logical revisions are
NOT time; no client clock or elapsed timeout is used as a lease proof.

Actual prepared catalog, discovery/subscriptions, durable control orchestration,
separate-host factories and MAIN-authorized signed account/offline/sleep/cancel/
asset/playback acceptance remain unfinished. No live schema/container/zone or
production identity was used in offline tests; the fake store's atomicity is
not Apple server proof. Source/synthetic tests do not activate an unavailable
backend or make the nil app factory ready.
