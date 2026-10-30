# Reader storage admission

This checkpoint connects the private storage allowance to actual Reader source,
option and complete-audio writers. It does not implement the Worker fresh-render
growth budget, a service provider/catalog, IPC, CloudKit or a signed app runtime.
It runs no model. All rendering controls and expression/source digests stay
unchanged.

## Submit exact source and options

`ChatterboxLocalSubmissionAdmission.submit` requires the Reader's own explicitly
activated durable-authority outbox, current session gate, exact submission and
portable plan. It validates the complete plan/source/recipe fingerprint before
writing. Both destinations must be exact roots managed by the supplied budget.
It captures the exact existing intent, including absence, and a live Reader
command fence before publication. The final attachment atomically compares that
observation; an intervening cancel or re-request cannot be overwritten by an
older submit continuation. Even idempotent intent commands invalidate it. This
fixed-size fence conservatively also invalidates submissions when another
chapter receives an intent command; callers can serialize explicit requests and
must not automatically resurrect rejected submissions. It is not serialized and
does not change journal versions or intent revision/acknowledgement semantics.

The allowance is 12 MiB: twice the existing 2 MiB source-envelope cap plus twice
the existing 4 MiB portable-plan-envelope cap. This counts temporary staged and
published hard-link paths conservatively, including retained owned scratch paths
if cleanup fails. Each immutable publisher enforces its existing encoded-byte
cap before writing and writes in bounded chunks. The allowance does not include
or authorize writing arbitrary other files.

An owned task publishes the exact Unicode source and options. Cancellation
signals and joins that task and its component-owned file work. Only after the
original task finishes does the caller settle actual inventory. A failed write,
cancel or settlement releases the joined allowance, preserves completed immutable
files, and makes no new wanted intent. After successful settlement, the exact
source/plan/intent triple commits through the existing outbox. Orphan files alone
never authorize inference.

A cancellation/error after that journal commit is a lost acknowledgement, not a
rollback. Reopen/read the authoritative outbox to reconcile; do not delete its
references or fabricate an acknowledgement. Repeating publication still needs
space for the bounded temporary files even if final identities already exist.

## Receive and accept complete audio

`ChapterLocalHandoff.inspectManifest` checks bounded canonical metadata, its
content identity, exact request and complete source map under the receiver's
current gate. It returns only a manifest. It does **not** inspect or decode the
audio and is never playback evidence.

`ChapterReaderStorageAdmission.receiveAndAccept` checks the exact current wanted
read set, inspects that metadata, and reserves its exact encoded audio length.
`receive` checks the same metadata identity again and performs the existing
bounded private copy, hash, codec, frame and sample validation. The metadata
length is enforced before and during copying. Cancellation joins this original
producer and its descendants. Settlement precedes actual Reader acceptance.

The outbox then compares the current wanted source/plan/revision and atomically
records the verified handoff reference using its existing acceptance API. Stale
intent, changed epoch, corrupt bytes and insufficient capacity never return an
accepted handle. A lost acknowledgement after acceptance may retain a valid
reference; a new epoch must perform real receive/adoption again. No producer
epoch or private file handle is serialized. The host must continue checking its
gate and stop playback on revocation; acceptance is a past observation, not a
permanent grant.

## Control-plane headroom and ownership

Budget the Reader's immutable source/options and Reader artifact roots separately
from its mutable outbox and authority controls. These helpers do not apply data
allowances to cancellation, disable, barrier publication or journal reconciliation.
A full artifact budget cannot reject those control operations. Ordinary OS disk
exhaustion can still fail a journal write: free-space observations do not reserve
physical blocks, so retain a separate free-space floor and preserve the existing
ambiguous-write/barrier failure semantics. Do not claim guaranteed writes when
the OS refuses them.

The Reader remains the sole writer of its journal. These helpers never open the
Worker journal or modify Worker publications. The host owns/cancels/joins calls
before closing the account connection or budget. Release of a joined allowance
may coexist with another owned inventory; it changes only in-memory allowance
accounting and never releases locks or closes the scan. Closing still refuses
live scans or allowances. All normal, unknown and completed files remain subject
to conservative accounting; there is no automatic quota eviction.

These are integrated bounded Reader writes with soft aggregate admission, not a
kernel quota, atomic filesystem snapshot, complete Worker growth guarantee,
power-loss validation, signed cross-process app validation, or cloud backend.
