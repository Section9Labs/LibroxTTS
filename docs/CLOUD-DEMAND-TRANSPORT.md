# Private CloudKit demand transport: demand-only implementation

Status: compiled implementation plus offline CAS/interleaving tests. NO live
CloudKit calls, zone creation, schema deployment, subscriptions, signed helper
account operation, source upload or remote rendering has been performed. This
is not a ChapterService implementation and must not enable the app's backend.

## Construction and account scope

The Librox app source entitlements currently name
`iCloud.com.section9labs.Libros`. The host must independently verify its ACTUAL
signed container/environment and fetch the current CloudKit user record ID;
source entitlements or APS environment are not runtime environment proof.

Derive `ChapterCloudAccountIdentity(containerIdentifier:environment:userRecordName:)`.
It hashes a canonical version/container/environment/privateDB/zone/user identity;
raw user record names are not retained. Open a fresh `ChapterAccountSessionGate`
epoch for that partition on every account lifecycle, including A→A. Construct
`ChapterCloudDemandTransport(container:account:session:gate:)` with that exact
container. It selects the private database itself and rejects a mismatched
container or session partition. Never reuse a context across account epochs.

`ChapterDemandReconciler(outbox:cloud:gate:)` explicitly flushes up to16 local
intents with at most3 conditional attempts per intent. It has no idle timer or
background task. Callers must schedule work within host lifecycle/network policy,
respect deferred/offline/account/configuration outcomes and cancel/await owned
work when closing. Native CK operations have15s request/30s resource configuration
and cancellation handlers. Their result is handed off only from Foundation
completion after per-record results have been collected. Real device/host
cancellation, timeout, sleep and offline join behavior remains unqualified.

## Proposed V1 schema — NOT deployed

All records are in ONE pre-provisioned private custom zone:
`LibroxProChaptersV1`, current-user owner. No default/shared/public database.

| Record type | Deterministic record name | Field |
| --- | --- | --- |
| LibroxChapterDemandV1 | d-{renderKey}-{lowercase deviceUUID} | payloadV1: Bytes |
| LibroxChapterIntentV1 | q-{renderKey} | payloadV1: Bytes |

Payloads are versioned JSON <=128KiB. Demand binds the exact request, durable
local device ID, monotonic device revision, desired membership, and accepted
aggregate intent revision. Aggregate intent binds request, monotonically
increasing revision and at most256 active device/revision pairs. Both payloads
are validated before mutation. No source text, recording, conditioning or audio
asset is present in this demand-only schema. No query index/subscription is
required by these direct-record reads; future worker discovery/subscriptions
must be separately designed and reviewed before provisioning.

## Atomicity and ambiguity

Save BOTH records atomically using `ifServerRecordUnchanged`. An idempotent
lost-ack replay ALSO conditionally saves both records; fetched equality alone is
not treated as authoritative confirmation. Native result membership, IDs/types,
change tags and returned payload counts/SHA hashes frozen BEFORE save must match before producing an opaque version
receipt. Versions are identities, not sortable clocks or leases.

A newer local cancellation cannot be removed by an older server acknowledgement.
Other devices' memberships survive a cancellation. Same device/revision with a
different value or a server revision ahead of the local journal fails closed;
never reset counters or overwrite it. An ambiguous server result leaves local
intent pending until a subsequent conditional confirmation. Account revocation
or cancellation prevents result adoption even if the server committed.

Rate/service/zone-busy outcomes expose retryAfter; offline, account, permission,
configuration, quota and cancellation failures do not enter immediate CAS retries.
No automatic retry scheduler exists at this stage. Never interpret a returned
local journal acknowledgement as a remote transaction receipt.

`ChapterDemandOutbox.confirm` atomically persists the opaque server revision with
clearing pending. `ChapterDemandReconciler.confirmedReceipt(for:session:)` replays
that exact confirmation after a later batch failure, cancellation or process/
epoch reopen. A new local intent invalidates the older confirmation. A real
service must replay confirmations on subscription/resume/error recovery; the
returned array from one flush is not the sole receipt delivery channel. This
replay is a durable past observation, not a fresh server-state query.

## Remaining gates

- Signed custom-zone/schema provisioning ownership and actual environment/account
  agreement across reader and companion, then two-device conditional conflict and
  lost-ack observations. No live writes before that concrete integration boundary.
- Network permission, offline/cancel/sleep/account closure and callback cleanup
  tests on the real signed host. Offline fakes are not CloudKit acceptance.
- Source-text asset transport and book/source custody; complete chapter rendering,
  cadence/source-map continuity, durable render checkpoints and adoption.
- Worker discovery, resource admission, generation/lease/fence publication and
  clock uncertainty. Existing ChapterJob values are NOT a server lock. A future
  worker MUST include the authoritative aggregate-intent read set in atomic
  publication, not infer authorization from a previously queued snapshot.
- Actual audio asset transfer, verified downloaded custody and cross-device
  playback. Only ChapterLocalArtifact represents playable.

Forty-five combined Release ChapterWorker tests pass. The added transport tests
use an explicitly offline atomic CAS fake and cover lost acknowledgements,
other-device membership, newer cancellation, epoch revocation, finite retry,
remote counter regression/equivocation, cancelled callback after server commit,
batch-partial failure receipt replay, process/epoch reopen, and cancellation
after journal confirmation. Native CKRecord.ID error dictionaries are exercised
offline; no container account/network is initialized by those tests.

ChapterServiceUpdate now carries an optional exact request/session-bound device
receipt. A real service must retain its latest local-device receipt in every
subsequent coalesced full snapshot. Consumers also match device/revision/wanted:
acknowledged false can coexist with a globally queued/ready job from other devices in the same account. No global phase acknowledges local cancellation.
