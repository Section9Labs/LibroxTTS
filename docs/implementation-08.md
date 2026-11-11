# LibroxTTS 0.8 implementation

Base: local 0.7 candidate `dee2b49`; no release or integration is implied.
Branch: `codex/0.8-reliability-performance`, separate from both 0.7 and Companion.

Authorized order: controlled lifecycle tests and repeatable baselines; cancellable
admission and session ownership; interrupted preparation recovery; planning;
profile-driven inference experiments. Public contracts, model assets, sampling,
audio identities, source boundaries and exact within-backend PCM remain gates.

## Baseline

The original renderer lease has been extracted into an internal synchronized
admission object without changing its queue behavior. Tests control the lease
without model assets: FIFO exclusion, cancelled nonthrowing unload joining its
predecessor, and release after a render error. These pass before introducing
cancellable admission. Log: `/tmp/libroxtts-08-admission-baseline.log`.

`Scripts/benchmark-08-plus.py` builds 0.6.2 and 0.7 CT modules with identical
compiler flags and unchanged catalog objects, then runs two ABBA blocks. Each
process performs two warmups and four timed renders per language with saved
noise, checking exact PCM on every call. All 96 renders match. Median process
timings show English 0.7 about 4.4% slower and Spanish about 2.9% faster. The
English delta is predominantly inside the unchanged vector-estimator graph;
non-graph overhead is approximately 0.9 ms in both revisions. This does not
reproduce the earlier 17% English slowdown or demonstrate a general speedup.
Shared-host/device/thermal uncertainty remains. Raw per-graph observations:
[`plus-062-vs-07.json`](architecture-08/plus-062-vs-07.json).

## Admission

Throwing load/render requests now cancel while queued, without waiting for an
active render. Nonthrowing settings/unload and existing uninstall semantics still
join the queue. Stable waiter IDs and doubly linked entries permit constant-time
removal without retained cancellation tombstones. Admission/cancellation races
return an acquired lease before throwing; each continuation is completed once.
Seven focused tests pass, including 200 cancellation-versus-release races and an
actual queued `NarrationRenderer.render` cancelled before its predecessor exits.
Log: `/tmp/libroxtts-08-admission.log`.

The renderer now publishes a single `NarrationSession` pairing identity with one
engine. An internal Max backend seam has production Core ML/MLX adapters and a
controllable test actor. Shared dispatch preserves sampling validation and error
mapping; no synthesis code or frame delivery is moved onto a new queue. Four
additional lifecycle tests cover held frames versus retirement, receiver errors,
memory/thermal mapping, cancellation during configuration, failed replacement,
identity reuse and persistent observer/CPU settings. Combined lifecycle/admission
tests pass (11 tests). Log: `/tmp/libroxtts-08-lifecycle.log`.

## Interrupted preparation

Core ML preparation now validates and recovers the existing `compiled`,
`previous-UUID` and completed `compile-UUID` generations before recompiling.
The canonical verified generation wins; otherwise a verified previous generation
is preferred to staging. Receipt/source/OS checks and full compiled-file hashes
remain required. Cancellation is never interpreted as corrupt data. Publication
and rollback remain recoverable across rename failures, and cleanup never removes
unrecognized directories or turns a committed installation into an error.

Seven tests pass: same-size corruption, stale OS, partial staging, cancellation,
faults before/after both renames, failed rollback/cleanup, and real English asset
recovery. The real test moved `compiled` to a legacy `previous-UUID`, reopened
preparation, validated the files and verified the original receipt inode: no
recompilation. Assets are a task-owned APFS clone at `/private/tmp/libroxtts-08-assets`.
Log: `/tmp/libroxtts-08-recovery-real.log`. Tests simulate interrupted filesystem
states/failures; no power-loss durability or device-kill qualification is claimed.

Plus compiler coordination now uses per-generation exclusive locks and a shared
legacy lock. Different keys may compile concurrently; the shared legacy lock
still excludes older SDK processes using the original global exclusive lock.
Nonblocking lock attempts check task cancellation while waiting. Tests observe
actual lock contention before cancelling, verify same-key exclusion and legacy
compatibility, and prove two different keys can own locks simultaneously. All
three tests pass in the same recovery log. Existing compiler receipt/cache keys
and atomic publication remain unchanged.
