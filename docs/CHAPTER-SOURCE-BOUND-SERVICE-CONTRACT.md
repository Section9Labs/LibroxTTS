# Source-bound local service contracts

The generic `ChapterStockCapability.recipe` fixture contract cannot supply one
production recipe that an app copies onto every chapter. Expression identity
includes the actual source hash; synthesis identity includes those expressions,
direction, grouping and seed. The current app's copy at
`PreparedChapterController` is therefore a concrete integration incompatibility.
Its frozen SDK/build remains unchanged. A production provider must use the
source-bound SDK path below; it must not reconstruct hashes or discard authored
options to satisfy the old catalog shape.

## Canonical Reader preparation

After explicit resident preparation, the actual renderer can return
`stockVoiceDescriptor()`. This is model/conditioning/profile metadata, **not**
availability, listening approval, account authority or proof of a working service.
Cold/loading/closed renderers do not provide it. The descriptor has no public
arbitrary initializer or serialization shortcut at this checkpoint.

`ChatterboxStockVoiceDescriptor.prepareChapter(source:options:session:)` is a pure
Reader-safe operation in `LibroxChatterboxPlanning`. It binds the actual exact
source and all effective authored options into `ChatterboxPreparedChapterSubmission`:
the canonical `ChapterSubmission` and its portable `ChatterboxChapterRenderPlan`.
It validates byte/hash/UTF16 identity rather than normalizing text. No model,
file publication, wanted demand, private conditioning or voice upload occurs.

Mac `ChatterboxMacChapterBinding` now uses that exact same implementation. Three
full request render keys were captured from the original implementation **before**
the move and remain frozen, alongside the six preexisting synthesis/delivery
digest controls. This is metadata code reuse, not a new model oracle or a cache
migration. For new inference, the Worker restores the portable plan and rebinds
it against its own prepared backend. Cache recovery deliberately skips model
preparation: it checks fixed production model/stock identities, the canonical
plan fingerprint and current intent, then performs actual artifact copy/decode.
It does not claim a fresh runtime backend rebind during that recovery path.

The future service must carry this prepared pair through the existing Reader
storage admission flow. Merely constructing it does not authorize any work.
Catalog display/availability/listening state and authenticated cross-process
descriptor transport remain separate provider responsibilities; no placeholder
source, fake recipe or available catalog is created here.

The explicit public production boundary is
`ChatterboxPreparedChapterService` in `LibroxChatterboxPlanning`, separate from
the legacy `ChapterService` fixture API. `catalog(session:)` returns
`ChatterboxStockCatalog`: one stock capability containing its descriptor,
supported delivery formats and explicit availability/listening state. Defaults
are unavailable/pending. There is no generic recipe field or empty-success
catalog. `submit(_ prepared:)` consumes the **whole prepared pair**, and
`download(_ prepared:)` carries that same expected source/options into actual
Reader verification. The SDK service, not the app, persists the portable plan.
`preparedSubmission(for:session:)` recovers the exact pair from SDK-owned durable
references after reopen; it cannot infer defaults from hashes. Cancellation,
updates and connection close retain existing exact receipt/epoch/join semantics.
There is deliberately no legacy adapter that drops the plan. These are concrete
public declarations for app source wiring; the provider implementation is still
pending, and no factory becomes available from importing this protocol.

## Bounded Worker discovery

`ChapterDurableIntentAuthority.wantedSnapshot(session:gate:)` discovers all fully
prepared wanted read sets from the existing canonical Reader authority archive.
It reads only immutable published metadata, never the mutable Reader journal.
The existing 32 MiB/8192-entry limits and strict canonical render-key ordering
remain. Pinned directory identity, exact before/after ready barrier and archive
digest are verified. The Worker's **own** current session is checked before and
after the joined read task; a closed Reader can remain an offline publisher.

The snapshot exposes an opaque publication UUID and archive digest for change
observation. Neither is a sortable clock, lease, completion or lock. A genuinely
ready empty archive has an empty read-set array. Missing, blocked or concurrently
changed authority throws `busy`; it never masquerades as an empty/idle service.
Corrupt or foreign metadata fails. The preexisting single-read-set
`validateCurrent` behavior remains false for blocked/changed authority.

Discovery alone must not start or repeat work. The owned Worker must still claim
and revalidate the exact read set. Current wanted demand can outlive a completed
render, so a queue must reconcile private checkpoints and a verified immutable
completion receipt rather than rerendering every unchanged snapshot. A past
snapshot cannot replace generation, current-intent or Reader acceptance checks.

## Remaining concrete integration

The local service/catalog/factory and authenticated host transport are not
activated. The next service stage must publish a bounded immutable completion
receipt tied to the exact wanted read set only after the owned Worker returns
from joined settlement. The Reader then performs actual copy/decode and its own
current-intent acceptance. No Worker metadata becomes playable directly. A lost
receipt is reconciled from a real verified candidate, with no automatic model
rerun or claimed fresh-render speed.

The app owner received one concrete call-site migration notice, not a build or
activation request. Committed reviewed source and separate signed real-generation
host authority are still required. Tests use synthetic backend metadata and
temporary Reader authority files: no production model, GPU, cloud, app host,
voice-quality, throughput or release evidence is generated.
