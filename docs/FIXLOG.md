# Reliability changes

## 0.8 — cancelled renderer requests waited for active work

The nonthrowing lease queue held cancelled load/render requests until the current
owner released it. Cancellation now removes only queued cancellable requests;
nonthrowing retirement still joins, and an admission race returns its lease.
FIFO, pre-registration cancellation, actual renderer cancellation and 200 release
races are covered by `NarrationAdmissionTests`.

Rule: cancellation may remove a waiter, but only an admitted owner releases the
lease; cleanup operations must join active work.

## 0.8 — cancellation during Max setup could publish a cancelled load

Max configuration awaited observer/backend setup before publishing its identity,
without the final cancellation check already used for Plus and Basic. It now
retires an unpublished engine when cancellation wins during setup. Controlled
lifecycle tests verify retirement and the absence of a usable partial session.

Rule: publish a session only after configuration and its final cancellation check;
retire any unpublished engine before returning an error.

## 0.8 — interrupted compiled-model adoption lost the canonical path

Preparation renamed `compiled` to `previous-UUID` before publishing staging, but
did not inspect those backups on restart. A process exit between the renames
therefore forced new compilation. Recovery now validates legacy backups and
complete staging, restores a usable canonical generation, then cleans owned
orphans. Fault-injection tests and a real receipt-inode test cover reopening.

Rule: publication may temporarily move the canonical path only when reopening
can identify and fully verify a surviving generation.
