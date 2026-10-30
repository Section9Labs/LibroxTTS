# Local Worker storage admission

The public `ChatterboxMacLocalWorker` initializer now requires a
`ChapterArtifactStorageBudget`. Transfer one dedicated budget owner with exact
Worker Exports, Custody and Publications roots. Keep State/control journals and
model assets separate. Enable validates each destination against that budget.
The internal fake-render test seam alone may omit it. No public unbudgeted
production constructor is provided.

This integrates **soft aggregate admission and measured settlement**. It is not
an OS quota or a pre-write hard codec limit. The native file exporter currently
checks encoded size *after* each `AVAudioFile` write and finalization. A native
write can exceed a threshold before observation; neither the reservation nor the
following formula proves that transient bytes stayed under it. No changed codec,
solver, model arithmetic, seed, normalization or expression policy is introduced.

## Admission and observation

Fresh work reserves a conservative envelope derived from the existing policies:

- Six-hour raw F32/24 kHz mono spool, guarded before each passage append.
- Four one-GiB encoded-file allowances: encoder staged/final aliases, adopted
  custody and immutable publication. The one-GiB checks are post-write checks.
- Existing 64 MiB unit cache plus one maximum 120-second unit atomic-write
  temporary, including its 48-byte header/hash overhead.
- Two eight-MiB receipt paths and eight-MiB publication metadata. Receipts are
  now explicitly size-checked before the first receipt write.

This is about 6.2 GiB of requested allowance even for a short new request; it is
not preallocated. Smaller measured per-request reservations are future work.
Available space must satisfy this allowance and the configured free-space floor.
Use separate warm rendering timings; do not call reservation or cached copying
fresh-model speed.

An existing complete candidate uses metadata-only inspection and a smaller
allowance: twice its exact encoded length plus the metadata cap. The source,
portable plan, current Reader authority and canonical synthesis fingerprint still
validate before reuse. Real private copy/hash/decode is required; corrupt or
missing candidates fail rather than falling back to rendering.

After the allowance is captured, Reader authority is checked again before model
preparation or candidate copying. The existing passage/preparation/output
admission checkpoints now also inventory actual managed bytes and free space.
The allowance stays live through model work, raw/cache output, encoding and
readback, adopted custody and immutable publication. Source/plan reads do not
write those roots. Budget observation failures stop the operation; unknown and
completed files are not evicted.

## Joined completion and failures

The existing shared cleanup task awaits the **original producer task's result**
before settlement or release. Successful physical publication is not enough.
Successful settlement is required before the public Worker call returns a
publication result. A failed original producer releases its allowance only after
join. A settlement failure returns no successful result, disables admission and
records storage failure while preserving any complete immutable publication as
an unaccepted recovery candidate. Reader adoption/acceptance remains separate.

If physical publication was already recorded before a later settlement failure,
the private checkpoint is changed to failed; physical bytes can remain. A caller
must never translate a private publication phase or retained reference directly
into Reader playable state. No server acknowledgement is fabricated.

Same-turn `stopClaims()` still signals the exact producer without an actor hop.
Disable awaits producer join, allowance cleanup and journal relinquishment.
Terminal shutdown also releases the resident model and closes its transferred
budget owner, including when a joined storage error is being reported. If the OS
refuses cleanup or roots change, an ambiguous allowance/locks may remain held;
re-enable refuses a leftover allowance. The SDK does not pretend to release
resources it could not verify. Journal controls are not rejected by ordinary
artifact capacity, but physical OS disk exhaustion can still fail them.

## Evidence boundary

Tests exercise actual synthetic narration and AAC encode/readback/copy using the
owned Worker chain, low-capacity rejection before preparation, a fresh process-
shaped owner recovering verified audio without a model reload, cancellation/join
and exact-root contention, and late settlement failure via a sparse temporary
fixture. Sparse logical size is not physical disk allocation. No production
model, GPU trajectory, CloudKit call, user journal, installed host, voice-quality
or speed test runs here. A real service/catalog, account/IPC host qualification,
aggregate control-archive retention and committed dependency are still required.
