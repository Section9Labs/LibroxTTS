# Private chapter storage admission

`ChapterArtifactStorageBudget` inventories only explicitly supplied, existing
app-private artifact directories. It admits bounded growth allowances against
their aggregate logical file size and an observed volume free-space floor. This
is a local inventory/admission component, **not an OS quota or an integrated
producer write limit**. No service advertises storage protection from this
component alone.

## Scope and preservation

Supply one to eight disjoint managed roots, including the control directory.
Reader and Worker use separate owners and separate role roots. Do not pass a
library, a model store, an entire home directory, or another process's mutable
Reader journal. The caller must already hold the relevant role ownership and
coordinate all writers in that scope. Exact-root budget locks do not detect an
independently configured owner over a parent or descendant of those roots.

Every regular file in those roots counts, including unknown files, old account
partitions, failed exports and completed audio. Hard links count at every visible
path; sparse/compressed files count their logical size. Filesystem metadata,
extended attributes, open-but-unlinked data and copy-on-write allocation are not
measured as logical file bytes. Root directories and their entries are traversed
without reading file contents. Counts, recursion depth, root count and live
reservation count are bounded. Symlinks, FIFOs, sockets, devices and nested
mount points fail admission rather than being followed.

No file is evicted, truncated, rewritten or deleted. An exhausted budget stops
new admission and preserves queued and completed data. Unknown data is not
reclassified as disposable. Automatic retention deletion is not implemented.
The only filesystem creation is the reserved zero-length
`artifact-budget.lock` in each managed root. Existing nonempty or unsafe lock
entries fail closed; they are not replaced. All roots retain exclusive locks for
the owner's lifetime, including while a detached inventory is being cancelled
and joined.

## Allowance lifecycle

1. Open an owner with explicit policy limits and private managed roots.
2. `reserve(bytes:)` inventories current files and compares their total plus all
   active allowances plus the requested allowance with the configured budget.
   It also compares the free-space floor plus all allowances with the minimum
   observed free bytes on the managed volumes. This is deliberately conservative
   across volumes and while earlier allowances already have files on disk.
3. The producer must independently bound its writes and own/join its work. A
   reservation does not enforce writes, allocate disk blocks or prove that a
   producer honored its allowance. Reader immutable publication and verified
   receive/adoption integration is documented separately in
   `CHAPTER-READER-STORAGE-ADMISSION.md`; measured Worker admission is described
   in `CHAPTER-WORKER-STORAGE-ADMISSION.md`. No model or pre-write codec cap
   follows from this component alone.
4. After every producer using that allowance has joined, call
   `settleAfterJoining` to remeasure actual files and the free-space floor. A
   settlement retains all other active allowances in both checks, conservatively
   counting them even where some bytes already exist. A failed settlement retains
   the token and all files. After a joined failure,
   `releaseAfterJoining` releases only the in-memory allowance.
5. Close after scans and allowances are finished. Closing while either is live
   fails. Tokens from a closed or different owner cannot be reused.

Cancellation awaits the exact detached scan before clearing its task slot. File
and root identities are checked around descriptor-relative traversal; path
replacement or unsafe entries reject the observation. This is not an atomic
filesystem snapshot: unrelated writers and other disk consumers can race an
observation, and later writes can invalidate it. Writer coordination, producer
growth limits, streaming write fences and admission/settlement integration are
required before claiming an end-to-end bounded service.

Allowances are process-local and are not serialized. After process death the
next owner inventories all retained files before admitting new growth. This
does not resume audio or recover a claim; those responsibilities stay with the
existing Worker journal and verified artifact admission.

## Validation boundary

Release tests use only fresh temporary fixtures. They cover aggregate counting,
preserving unmanaged originals and unknown old partitions, multiple allowances,
settlement after actual growth, overshoot, exact-root contention, count/depth/
reservation limits, free-space and integer bounds, symlink/FIFO rejection,
root/lock replacement, cancelled scan join and stale tokens after reopen.
They run no model, CloudKit request, app host or user-data migration. This
component is not a hard quota, retention engine, service/catalog provider,
signed cross-process validation, cloud transfer or narration speed result.
