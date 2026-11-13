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

## 0.9 — downloaded replacement removed the installed file too early

Both download paths deleted the destination before moving downloaded bytes into
place. A failed move could therefore lose the existing installation. A shared
publication helper now copies to a unique sibling, verifies that copy and replaces
the destination only at adoption. Tests inject partial-copy/disk-full, corrupt
staging, cancellation and failed adoption, verifying unchanged installed bytes
and cleanup; a successful real filesystem replacement is also covered.

Rule: verify replacement bytes on the destination filesystem before replacing
the installed file; failed staging must leave the installed path intact.

## 1.0 — synchronous styled rendering retained temporary memory

Repeated foreground Core ML synthesis on the physical iPad exposed steadily growing
process footprint. The unchanged 0.9 baseline reproduced the growth. Native tensor
views made per-render ownership more important, and delivery-state validation also
read a voice file on every render without draining autoreleased Foundation buffers.

Core ML now drains temporary bridge objects when each render returns. Delivery
validation drains each read block while retaining its original read, cancellation,
hash and error order. Exact PCM/events are checked after the change; the isolated
memory regression and sustained physical-device probe record the remaining growth.

Rule: synchronous SDK work owns its temporary-object lifetime; correctness must not
rely on the caller returning to a UI run loop.

## 1.0 — recovery verified across real process exits

Crash helpers terminate child processes before and after compiled-generation
renames and downloaded-file adoption. Reopening validates a complete surviving
generation, and publication retries preserve complete installed bytes. These tests
supplement the existing injected-error, cancellation and rollback tests; they do
not simulate a power-loss filesystem or delete another writer's staging files.

## 1.0 — changed original voice archives retain legacy validation

Native voice preparation initially admitted any structurally supported archive.
A caller can replace an original voice file after engine load; the old MLX reader
would then observe and validate every record, including unused tensors. The native
path now requires a catalog-pinned whole-file digest on every read. Unknown or
changed bytes use the original reader. A replacement-archive regression and all
48 installed English/Spanish voice fixtures pass, followed by final exact audio
and device qualification. No verification result is cached.
