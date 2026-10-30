# Exact chapter source custody

`ChapterTextAsset` owns a verified private UTF-8 copy of the reader's exact
extraction. It is the local prerequisite for a future source CKAsset transport,
not an upload, durable adoption database, whole-chapter renderer or server-ready
record. No CloudKit calls are made by this component. It contains no recording
or voice-conditioning field.

`ChapterTextAssetManifest` binds version, account partition, source identity,
byte count and UTF-8 SHA256. Source identities retain the existing ten-million
UTF-16-unit ceiling. Header byte counts must be between the UTF-16 length and
three times it, and never above 40,000,000. Actual bytes, strict UTF-8 roundtrip,
UTF-16 length and exact hash are checked before returning custody. CRLF,
decomposed Unicode, non-BMP scalars and extraction placeholders are retained;
there is no normalization or re-extraction. Source keys omit render/delivery
options but must always be scoped by the bound account partition/private store.

Create/adopt work runs in an owned detached utility task. Cancellation cancels
and awaits that task. Every public async boundary validates cancellation and the
same account epoch before and after awaits; hosts must still fence their own UI
and transport callbacks. Input files are read-only and never deleted or moved.
Reads and writes are chunked at 65,536 bytes with manifest bounds. Whole text is
materialized only within the declared bounded source budget.

Storage must be an existing app-owned directory. The helper creates a UUID child
with mode0700 and a mode0400 source file. Source opens use NOFOLLOW/NONBLOCK and
require a regular file. Directory and file descriptors/inodes remain pinned,
including a retained original file descriptor that prevents inode reuse from
masquerading as the owned file. Scoped file access rehashes exact contents and
checks the absolute path identity before and after the async consumer. The
consumer must retain the scope through the real asset operation's completion;
a returned path is not an alternate lifetime or activation mechanism.

Cleanup unlinks only matching owned inode entries and never recursively deletes
unknown files. Early staged failures also clean bound entries before releasing
their descriptor pins. Unbound/uncertain entries, replaced paths or entries the
OS refuses to remove may remain. This is deliberate preservation, not a promise
of unconditional cleanup across all OS failures. No failed operation publishes
an accepted custody handle.

## Validation

Nine focused Release tests plus the existing47 chapter tests passed (56 total).
Coverage includes >65KiB exact Unicode chapters, read-only independent custody,
header/source/account/delivery identity, corrupt and invalid UTF-8/UTF-16 input,
source/storage symlinks and FIFO rejection, stale/pre-cancelled operations,
account revocation during scoped access, content and path replacement, bound
creation faults, partial-write cancellation followed by worker join, and
preservation of unrelated/downloaded files. The internal creation boundary seam
is not a public factory and cannot bypass request/epoch checks in host code.

Independent data-safety source review found no remaining blocker. This does not
qualify live CloudKit source transfer, account changes during a real network
operation, durable adoption/checkpoint recovery, chapter narration or playback.
