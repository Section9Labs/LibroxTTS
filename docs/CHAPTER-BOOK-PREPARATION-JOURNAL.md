# Durable whole-book preparation

This stage implements actual Reader-owned persistence and exact lazy source/
options admission. It does not activate a CloudKit service/factory, publish a
Worker authority or make any segment playable. App integration remains on the
reviewed public segment component until a concrete separate-host book provider
is ready. No original user journal is opened or migrated by these tests.

## One preparation, independent listening position

The actual prepared backend's `ChatterboxStockVoiceDescriptor.prepareBook`
creates an SDK `ChatterboxPreparedBookSubmission` from the original
`ChapterBookSource` spine and explicit settings: language, selected delivery,
direction, grouping and UInt64 seed. Full model/conditioning/backend metadata
and actual typed settings bytes are preserved in the canonical scope. A digest
is an identity, never instructions to reconstruct omitted settings. Restoring
the scope produces metadata only; actual Worker backend rebinding/approval and
current cloud intent remain required before inference.

The Reader `ChapterBookOutbox` stores wanted preparation separately from the
priority chapter/global UTF16 position. There is no Play/Pause bit or API.
Priority/source admission increments the device revision but preserves
`wantedRevision`. Explicit cancellation/re-request changes wantedRevision and
retains completed source/plan references. A future cloud service must compare
the exact current wanted/entry read set when claiming/publishing; none of these
local counters is a server clock or distributed lock.

Book scope identity includes the exact source spine, account partition and
canonical backend/settings bytes. Different selected delivery or backend makes
a different scope. Per-chapter authored directions remain in that chapter's
exact portable plan: Float32 bit patterns, UInt64 seed, nil versus empty sidecar,
source ranges, grouping and source content are never dropped or text-rewritten.
Planner/cadence revision is also explicit in the scope identity. Historical
scope/settings metadata remains recoverable, but unsupported pair/segment
validation rejects until an independently versioned historical fingerprint
verifier exists. No old planner label is combined with current synthesis math.

## Reader ownership and recovery

SDK factory wiring must place this private store in a NEW
`Reader/Outbox/Books` namespace and keep source/plan files under separately
managed Reader artifact roots. Never pass the existing chapter journal's
account/device directory, Worker state or model directory. The book writer owns
one lifetime `owner.lock`; other cooperating writers cannot open it. Its
distinct canonical domain also rejects chapter/Worker state and prevents older
chapter writers from interpreting it as an empty chapter journal.

An immutable, checksummed established-role binding records account, device,
publisher and directory inode/device even for an empty book queue. Once that
binding exists, missing/corrupt/foreign journals never become a fresh empty
queue. A first activation interrupted after marker creation but before the
initial journal is durable remains unavailable; it needs explicit recovery,
not an automatic reset. Entire parent-store deletion/replacement across process
restarts is not solved by an in-store marker; the eventual host/server recovery
path must retain its independent identity/authority. No migration or repair is
performed implicitly here.

The journal is bounded32MiB/64 books/8192 total spine entries. Writes use bounded
chunks, staged actual readback, file synchronization, atomic rename and parent
fsync. A late cancellation or fsync/acknowledgement failure poisons the live
writer; only reopen/reconciliation can reveal the actual committed state. No
old in-memory snapshot is written back after uncertainty. File descriptors,
root/path identities and role locks stay pinned; unknown data is not removed,
evicted or recursively cleaned. Replacing a live root makes writes fail.

Only exact server confirmation saves a server revision while clearing pending
in the same journal transaction. Loading enforces both directions of that
invariant. A stale device/revision callback cannot confirm a newer intent.
Persisted confirmations can be replayed after reopen; no global phase, source
publication, segment file or book seal counts as a device acknowledgement.

These guarantees concern the private Reader store. There is NO filesystem
offline head here that a remote Worker may treat as current authority, and no
Worker is allowed to open the mutable book journal.

## Lazy exact entry admission

`preparedBook.prepareEntry` classifies each original spine entry with the SDK.
Literal empty/whitespace/FFFC-only entries produce explicit silent proofs;
meaningful titles/copyright/front matter remain narratable. Original indices
never move. A nonempty silent entry's raw source transport/reverification is
still a cloud integration requirement; a persisted classification is not a
render or cloud completion receipt. Silent entries never produce zero-frame
audio. Authored sidecars on a silent entry reject rather than being discarded.

For narratable entries `ChatterboxBookSubmissionAdmission.submit` validates the
WHOLE exact prepared pair against the book policy, observes a live per-book
admission token, and uses the existing source+portable-plan publishers. It
reserves12MiB soft retained growth for their staged/published aliases. Exact
original producers and children JOIN and allowances settle before the Reader
journal attaches both references atomically. The journal contains references,
request metadata and silent hashes/counts, not text/audio/path/epoch handles.

The token binds its live Reader owner, per-book command, wanted revision,
original spine index and exact prior slot. Cancel/re-request, idempotent control
commands, close/new owner or another update to the same slot reject late
callbacks. Independent other-chapter attachments do not invalidate the token.
Source publication checks use canonical source-key digests, not Swift's Unicode
normalizing string equality. Once admitted, literal chapter source cannot change
within the same book scope; explicit per-chapter authored plan updates may keep
the same source. Known priority offsets must fit the admitted exact source.

Soft artifact admission is not an OS quota or pre-write codec cap. Book control
journal/cancel writes remain outside ordinary source/audio artifact allowances;
physical disk exhaustion can still fail them. Completed immutable source/options
files survive cancellation and failed/stale attachment for explicit verified
reuse. References alone never start synthesis or make media playable.

## Evidence and next real integration

Tests cover actual source/options publication and recovery under a fresh epoch,
exact authored scalar bits and max seed, canonical malformed checksummed state,
NFD/NFC publication mismatch, role locks/foreign formats/missing state, root
replacement/unknown-file preservation, cancellation/re-request races, original
producer joins, late-ack reopen and control writes under source-capacity failure.
No model, GPU, live CloudKit, app/phone or audio generation runs are part of this
stage. Existing codec/model/precision/output/thermal guards and selected AAC
policy are unchanged. Matt rejected the fixed1dB candidate; do not enable it.

Next: actual book cloud control/source/plan synchronization and exact device
receipts, authenticated prepared-backend catalog, native Worker generation/claim
read-set fencing with explicit clock/lease policy, atomic ordered segment head/
seal publication, SDK seek metadata-prefix replay ending at each offered target,
Reader current-book acceptance and restart recovery. Only after concrete
separate-host factories and MAIN-authorized signed runtime can real Mac/iCloud/
iPhone request, transfer, progressive playback and completion be qualified.

## Shared app contract (declarations, no factory)

`ChatterboxPreparedBookService` exposes catalog, durable begin with an exact lazy
`ChatterboxBookSourceProvider`, resume source admission, stored prepared book,
prioritize, resolve, successor, full sticky metadata updates, explicit download,
cancel preparation and synchronous stopRequests/async close+join. The SDK owns
source ordering/admission and recovery; the app supplies exact Reader extraction
and authored directions through the source callback. Begin returns after primary
intent is durable, before every source/audio file has been produced. Closing or
pausing listening must not silently cancel the whole-book intent.

`ChatterboxResolvedBookSegment` is metadata only and requires a prefix ending
exactly at the target manifest plus an actual local rendered-unit frame boundary.
No earlier audio is required for a seek. The actual download returns a separate
`ChatterboxBookSegmentDelivery` containing verified private media custody and
that same per-target prefix. The app retains current+next2 handles, one audio
graph and its own explicit Play/Pause/seek/account revision fences; it does not
reimplement chain/seal validation. Observation/metadata alone cannot play audio.

These declarations enable app wiring, not registration or availability. There
is no concrete book provider/CloudKit factory in this component. `endOfBook` or
complete phase in a future provider requires actual original-spine accounting,
source/silent evidence and verified ordered chapter/book seals, not counts alone.

### App-side call sequence

The caller receives `service` only from a separately qualified factory. This
component does not create one. Use actual Reader-derived `source.book` and the
user's explicit settings, including preserved Lossless preference when selected:

```swift
func beginBook(service: any ChatterboxPreparedBookService,
               source: any ChatterboxBookSourceProvider,
               settings: ChatterboxBookRenderSettings,
               position: ChapterBookPriority,
               session: ChapterAccountSession) async throws -> ChatterboxBookDemandReceipt {
    let catalog = try await service.catalog(session: session)
    let descriptor = catalog.voices[0].descriptor // SDK catalog is exactly one stock identity.
    let book = try descriptor.prepareBook(source: source.book, settings: settings, session: session)
    return try await service.begin(book, source: source, priority: position, session: session)
}
```

Catalog metadata is not permission to override availability/approval. `begin`
must enforce the actual service/account/capability policy. Keep the returned
opaque scopeID for SDK recovery; do not persist the plan/settings in an app stash.
Use `resolve` for the explicit target, then `successor(of: segment)` for prefetch.
Download only `.segment` resolutions through `service.download`; pass actual
delivery.artifact and resolution.prefix to the existing player. On
`.chapterComplete`, pass its seal/finalPrefix to that chapter's `finish` and
use `successor(of: completion)` to prefetch the next original-spine chapter.
Data completion may precede heard completion. `.waiting` is buffering/source/
queue metadata; it never starts playback or implies an acknowledged demand.

Pause acts on the player only. A seek preserves whole-book wanted state and
updates scheduling priority; it cancels/fences the old listening request without
globally stopping source preparation. Explicit cancellation calls
`cancelPreparation`. A connection/account/provider replacement directly calls
`stopRequests` in the host event turn, then OWNS/awaits exact `close` before
replacing the service or releasing storage/network/security scopes. Do not
activate old prepared-chapter and new book demand producers simultaneously or
open SDK journals from app code.
