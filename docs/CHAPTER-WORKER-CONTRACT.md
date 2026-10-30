# Mac companion and chapter queue: first SDK foundation

Status: implementation in progress. This is an model-independent value/state, verified-artifact and local-outbox layers, NOT a CloudKit worker or installed companion. No release, schema deployment, cloud writes or phone workload.

The app remains Catalyst. The companion is a separately packaged native macOS process sharing LibroxKit, with its own menu-bar status and an opt-in Librox enable/disable setting. The menu should show imported books, queued/rendering/publishing/ready/failed chapters, measured progress, model capability, storage and pause state. Imported/queued/prepared are distinct states. Disabling stops new claims; cancel and join active rendering before relinquishing its claim. Preserve queued demands, completed audio, books, voices and reading location. Login registration and signing remain app-owner integration work.

## Implemented SDK product: LibroxChapterWorker

- `ChapterRenderRequest`, `ChapterSourceIdentity`, `ChapterRenderRecipe`: validated, versioned content identity and deterministic render digest. Account namespace is separate from content deduplication. Host must derive account partition from container/private database/environment/opaque account ID. Planner revision must include grouping/cadence policies; synthesis options digest binds every effective sampling/CFG/solver/token option. No recording or conditioning upload API. First integration accepts installed stock capabilities only; a stock ID is not permission to substitute a custom voice.
- `ChapterArtifactManifest`, `ChapterAudioUnit`, `ChapterTextRange`: complete post-cadence frame maps, original UTF-16 ranges and untimed grouped fragments; streaming bounded audio byte verification. Metadata/hash verification does NOT establish codec decode, watermark, finite/peak-valid audio, correct spoken content or playback availability.
- `ChapterJob`, `ChapterClaim`: explicit demand membership, intent revision, finite claims, renewal, publication, cancellation, takeover fencing and joined relinquishment. Conditional transaction persistence is REQUIRED around mutations; this value is not a distributed lock or durable store. Clock inputs require the separately qualified server-time/lease-validity adapter. Never treat local wall-clock comparison as a complete CloudKit lease algorithm.
- `ChapterAccountSessionGate`: fresh local epoch on each account lifecycle; validate callbacks after every await. Signing out and back into the same account does not revive old callbacks.

Frame ranges are half-open. Units partition the full decoded frame timeline in order. Frame counts include boundary cadence as measured after rendering. Fragment ranges carry no per-fragment or word timestamps. Use `validateSourceMap(text:for:)` to bind UTF-16 ranges to the exact hashed extraction and reject ranges splitting surrogate pairs; metadata validation alone checks integer bounds/order. No character-duration estimate is an alignment map.

## Additional local stages validated 2026-10-30

- `ChapterLocalArtifact`: nonforgeable private adopted WAV-F32/ALAC24 custody,
  actual bounded decoding at24kHz/mono, exact frame count, finite peak<=1,
  source-map and account-session validation around awaits. New Mac Pro policy is
  `disabled-1` only. Caller retains the handle throughout playback and must stop
  immediately on lifecycle revocation. This is scoped custody, not a durable
  crash-recovery availability database.
- `ChapterDemandOutbox`: per-account/per-device local demand intents with
  monotonic revisions and exact-intent acknowledgements. A late acknowledgement
  cannot erase a newer cancellation/re-request. Acknowledged tombstones preserve
  revision counters. Exclusive ownership, bounded/checksummed journal,
  descriptor-relative directory access, fsync+atomic rename, ambiguous-write
  poisoning and reopening reconciliation are implemented. Tests cover real
  reopen, late acknowledgements, account/owner isolation, injected post-rename
  failure, cancellation, corruption/checksum tampering and ancestor replacement.
  This establishes local process-crash recovery semantics, not power-loss proof,
  server delivery, distributed ownership or exactly-once rendering. At8192
  distinct retained intents /32MiB, admission fails without deleting old state.
  A transport must reconcile the versioned device demand in conditional server
  transactions before calling local `acknowledge`; local acknowledgement is not
  delivery evidence. Host must use current account epochs around every await.

Forty-five Release chapter-worker tests pass across artifact, local journal,
service contracts and offline conditional-demand reconciliation. These include
actual filesystem/codec checks; offline CAS fakes are not CloudKit acceptance. No real CloudKit writes,
account synchronization or cross-device playback were performed.

## Frozen host interface, not a backend

`ChapterService` defines catalog, exact-text submission, device-demand
cancellation, account/epoch-bound coalescing status snapshots, cancellable
verified-artifact download and epoch shutdown. `ChapterWorkerService` defines
synchronous stop-admission followed by awaited cancellation/join and conditional
relinquishment. Production implementations do not exist yet. Consumers must
revalidate epochs after awaits and reject mismatched request/session updates.

Catalog capability availability means the end-to-end service can admit a source
within its explicit UTF-16 limit; merely installed weights and short-excerpt
success are insufficient. Listening approval is separate. No invented production
catalog/recipe values are supplied by these interfaces. New policy is disabled-1.
Full updates retain the latest exact local-device receipt through coalescing;
global phases cannot acknowledge this device's cancellation. A demand receipt
distinguishes durable local intent, network submission and an
adapter-issued server acknowledgement. Opaque server revisions are deliberately
not Comparable and are not clocks, leases or proof of delivery. Only an actual
`ChapterLocalArtifact` can represent playable; remoteReady remains metadata.
The test-only stream fake validates bounded cancellation/coalescing mechanics,
not CloudKit or production subscription implementation.

## Demand-only CloudKit implementation, not live integration

`ChapterCloudAccountIdentity`, `ChapterCloudDemandTransport` and
`ChapterDemandReconciler` implement canonical account/environment/zone scope,
private custom-zone demand+intent conditional pair writes, finite reconciliation
and durable confirmation replay. No live CloudKit operation has been run. Schema
is proposed only. See `docs/CLOUD-DEMAND-TRANSPORT.md` for exact construction,
record types/fields and signed-host/lifecycle/publication gates still outstanding.

## Not yet implemented; required before live cloud/app integration

- Cloud transport around the local outbox, crash-safe render checkpoint/adoption database, and atomic fake transport/interleaving tests.
- Native demand-only conditional pair writes and offline lost-ack reconciliation now exist: see docs/CLOUD-DEMAND-TRANSPORT.md. Live signed-host acceptance, source/assets, worker job/lease/fence and atomic publication remain pending. Account/environment partitioning is canonical; host must supply actual signed environment/current user identity.
- Expired/uncertain lease behavior across system sleep/clock skew; no exactly-once physical rendering claim.
- Whole-chapter text windowing and cadence checkpoint continuity beyond existing 32 KiB/128-unit session bounds.
- Durable atomic local availability and actual downloaded CloudKit codec/source verification. Scoped WAV/ALAC verification exists; Cloud `ready` is never equivalent to phone `available`.
- Resource-qualified renderer scheduling, one-vs-two chapter concurrency, real throughput/latency and safe shutdown under disable/account changes.
- CloudKit custom-zone adapter, actual signed helper/menu UI, Librox settings and prepared playback driver. Dedicated Codex app chat01a18a96-6a01-7ff3-851f-edd02d086e6e owns app document/account/network/lifecycle/playback integration; SDK owns transport/rendering/verification contracts and algorithms. T3 is frozen.

The research checklist in `codex-mac-icloud-chapter-render-research.json` is authoritative for the remaining six acceptance groups. Current tests establish only the implemented subset. The app owner may audit interfaces and prepare adapters but must not claim a working remote feature from these values.
