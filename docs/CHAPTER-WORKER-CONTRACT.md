# Mac companion and chapter queue: first SDK foundation

Status: implementation in progress. This is an initial model-independent value/state layer, NOT a CloudKit worker or installed companion. No release, schema deployment, cloud writes or phone workload.

The app remains Catalyst. The companion is a separately packaged native macOS process sharing LibroxKit, with its own menu-bar status and an opt-in Librox enable/disable setting. The menu should show imported books, queued/rendering/publishing/ready/failed chapters, measured progress, model capability, storage and pause state. Imported/queued/prepared are distinct states. Disabling stops new claims; cancel and join active rendering before relinquishing its claim. Preserve queued demands, completed audio, books, voices and reading location. Login registration and signing remain app-owner integration work.

## Implemented SDK product: LibroxChapterWorker

- `ChapterRenderRequest`, `ChapterSourceIdentity`, `ChapterRenderRecipe`: validated, versioned content identity and deterministic render digest. Account namespace is separate from content deduplication. Host must derive account partition from container/private database/environment/opaque account ID. Planner revision must include grouping/cadence policies; synthesis options digest binds every effective sampling/CFG/solver/token option. No recording or conditioning upload API. First integration accepts installed stock capabilities only; a stock ID is not permission to substitute a custom voice.
- `ChapterArtifactManifest`, `ChapterAudioUnit`, `ChapterTextRange`: complete post-cadence frame maps, original UTF-16 ranges and untimed grouped fragments; streaming bounded audio byte verification. Metadata/hash verification does NOT establish codec decode, watermark, finite/peak-valid audio, correct spoken content or playback availability.
- `ChapterJob`, `ChapterClaim`: explicit demand membership, intent revision, finite claims, renewal, publication, cancellation, takeover fencing and joined relinquishment. Conditional transaction persistence is REQUIRED around mutations; this value is not a distributed lock or durable store. Clock inputs require the separately qualified server-time/lease-validity adapter. Never treat local wall-clock comparison as a complete CloudKit lease algorithm.
- `ChapterAccountSessionGate`: fresh local epoch on each account lifecycle; validate callbacks after every await. Signing out and back into the same account does not revive old callbacks.

Frame ranges are half-open. Units partition the full decoded frame timeline in order. Frame counts include boundary cadence as measured after rendering. Fragment ranges carry no per-fragment or word timestamps. Use `validateSourceMap(text:for:)` to bind UTF-16 ranges to the exact hashed extraction and reject ranges splitting surrogate pairs; metadata validation alone checks integer bounds/order. No character-duration estimate is an alignment map.

## Not yet implemented; required before live cloud/app integration

- Durable outbox, crash-safe local checkpoint/adoption and atomic fake transport/interleaving tests.
- Conditional change-tag transactions atomically checking job/intent/worker lease/fence; ambiguous lost-ack reconciliation; per-device versioned demand IDs and account/environment partitions.
- Expired/uncertain lease behavior across system sleep/clock skew; no exactly-once physical rendering claim.
- Whole-chapter text windowing and cadence checkpoint continuity beyond existing 32 KiB/128-unit session bounds.
- Codec/decoded-frame/watermark verification and atomic local availability. Cloud `ready` is never equivalent to phone `available`.
- Resource-qualified renderer scheduling, one-vs-two chapter concurrency, real throughput/latency and safe shutdown under disable/account changes.
- CloudKit custom-zone adapter, actual signed helper/menu UI, Librox settings and prepared playback driver. T3 owns app document/account/network/lifecycle/playback integration; SDK owns transport/rendering/verification contracts and algorithms.

The research checklist in `codex-mac-icloud-chapter-render-research.json` is authoritative for the remaining six acceptance groups. Current tests establish only the implemented subset. T3 may audit interfaces and prepare adapters but must not claim a working remote feature from these values.
