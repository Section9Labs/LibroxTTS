# Local Worker and completion supervisor

`ChatterboxMacLocalWorkerSupervisor` transfers exclusive ownership of the local
Worker and its artifact budget. Its production initializer constructs the
existing stock Worker, without preparing or running the model. `enable()` opens
admission; `renderAndPublish` requires an exact, current, authoritative wanted
read set. There is one active operation, no polling loop and no implicit queue
or inference authority from construction or source-file discovery.

The supervisor owns the entire Task that either observes existing completion
metadata or awaits Worker rendering and publishes its exact completion receipt.
All source, model preparation, synthesis, codec, custody, handoff, metadata and
file children belong to that chain. The existing Worker remains solely
responsible for generation/journal release and its renderer/storage lifecycle.
The supervisor never repeats the Worker's after-join journal release.

`stopClaims()` is nonisolated and synchronous. Call it directly in the host event
turn to block admission and cancel both the supervisor Task and underlying
Worker, including when metadata publication is paused after rendering.
`disable()` and terminal `shutdown()` repeat that fence and await the exact
original supervisor and enable Tasks before calling the Worker's join barriers.
Thus the Worker's budget cannot close underneath an active receipt write.
Concurrent stops keep admission closed; enable uses a revision-bound
cancellation registration and cannot reopen after a racing stop or terminal
shutdown. A caller cancellation also cancels and joins the operation rather
than detaching its remaining publication work.

After the producer joins, the supervisor installs a separately owned final
acceptance task without an intervening await, only while its lifecycle revision
still matches. That task refreshes Reader authority and the Worker epoch; the
caller then directly validates its Worker gate and lifecycle before returning.
The operation slot remains occupied throughout. Stop joins both producer and
any installed acceptance task before Worker shutdown. This is still a past
metadata observation: a later Reader mutation can follow the last observation;
only the Reader's actual adoption and atomic wanted-intent acceptance grant
playback.

An exact existing completion receipt plus matching private Worker checkpoint
returns a metadata observation with `newPublication == nil`. It does not claim
fresh-model speed, resume model state, recopy audio, or mark anything playable.
Repeated unchanged wanted intents therefore do not start a new generation or
rerender. Missing checkpoint evidence, corrupt receipt data, wrong intent and
unavailable authority fail closed. There is no automatic deletion or fresh
render fallback. When a changed wanted intent has no receipt, the existing
Worker may reuse its unverified completed candidate only through its ordinary
actual private copy/hash/codec verification. That reuse is explicitly labeled in
the returned Worker publication and does not reload the model.

The immutable completion envelope is still metadata only. A Reader must use its
own current epoch to privately copy, hash and decode audio, then atomically
accept the complete handoff against its wanted intent. A lost callback after
completion publication can be reconciled by observing the exact receipt without
repeating synthesis. Cancellation preserves complete publications and queued
intent. Soft storage admission and post-write codec bounds are unchanged; this
is not an OS disk quota.

The returned Worker timings exclude supervisor receipt lookup/publication and
Reader copy/playback/cloud. No combined speed claim is made by these synthetic
tests. Full-quality arithmetic, solver steps, expressions, seeds, cache keys,
watermark policy and source maps are unchanged.

The concrete prepared Reader service, descriptor/status transport, catalog,
subscription lifecycle and host factory remain pending. Production model
lifecycle, separate signed processes, sandbox/App Group access, real narration,
cloud and end-to-end speed remain separately qualified gates. This source
component does not authorize a host/model launch or change LocalReview353.
