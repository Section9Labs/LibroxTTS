# Immutable segment content transport

Internal source prototype, not a registered service/factory, job claim, ordered
book/chapter head or playback acknowledgement. No zone/schema deployment or
live CloudKit calls have occurred. First scope remains stock-only and contains
no private phone recording/conditioning upload mechanism.

`ChapterCloudSegmentTransport` uses the proposed private `LibroxProChaptersV1`
zone, `LibroxChapterSegmentV1` records named `s-<canonical-segment-manifest-SHA>`.
`manifestV1` is canonical Bytes <=128KiB; `audioV1` is the independently complete
CKAsset. The admitted segment is <=16MiB/121s. Account partition belongs to the
exact manifest and host-derived signed container/environment/current-user
identity. No DEBUG/APS inference. Capture/custody roots must be disjoint.

The eventual service must first authenticate the expected manifest from its
current intent/generation-fenced ordered head. Immutable content existence alone
cannot make an old generation current, acknowledge demand or grant playback.

## Native operations and file custody

Every native fetch/save is configured15s request/30s resource and remains owned
until Foundation completion, including cancellation. Those are configurations,
not an independent guarantee that a native cancel completes within30 seconds.
Caller service owns the entire method task and must cancel/join before closing
account/resources. Current account epoch and live asset/network authorization
are checked before every native operation, including reconciliation, and after
each await. No timer/fire-and-forget transfer is installed.

Upload consumes only an actual `ChapterLocalSegmentArtifact`. Its bytes are
independently copied/hashed into new private FD/inode-bound0400 capture, retained
through native completion and rechecked afterwards. No public path-only upload
API exists. A successful save confirms content, not ordered-head publication.
An existing record and one lost-ack/conflict reconciliation additionally require
actual full download/private copy/hash/codec/frame/sample verification. Local
storage/hash/decode/cancellation errors never become uncertain network retries.

Download first fetches metadata without the asset, admits exact canonical
manifest/key/account/tag, then requests the asset. Downloaded staging bytes are
copied INSIDE `perRecordResultBlock`, before CloudKit's staging URL can disappear.
Returned result slots carry private custody, not retained CKRecord/fileURL as
custody. The capture has bounded65536-byte IO, exact hash/size, nofollow regular
file/source/path/FD fences and nonrecursive inode-bound cleanup. Unknown files
are retained. After native completion, the receiver actually privately copies
and decodes under its OWN fresh session gate. The returned segment handle is
still subject to current book-intent acceptance in the future service.

Native CloudKit wire/download cache volume is opaque. The16MiB limit bounds the
private verification/copy, NOT adversarial remote wire bytes. Byte admission and
native asset cache are not OS quota or whole-service storage proof. Transferred
SDK budgets and ordered output acceptance remain integration gates.

## Evidence and remaining work

Offline tests use an internal record store and actual WAV-F32 private copy/decode:
capture survives staging deletion, unknown files survive cleanup, symlink/FIFO/
wrong hash/mid-copy cancellation reject, uncertain insert reconciles once via
real bytes, metadata rejects before asset fetch, corruption does not retry and
fresh receiver epoch is required. No CKContainer is instantiated in these tests.
Native CloudKit completion/cancel/account behavior needs a separately authorized
signed host and real account; offline tests do not qualify it.

Remaining: durable whole-book intent/priority/exact lazy source+plan admission,
authenticated actual prepared-backend catalog, worker lease/generation/server
clock uncertainty and authoritative intent read-set transactions, atomic ordered
segment head/seal publication, Reader current-book acceptance/recovery, bounded
aggregate control/archive retention and concrete separate-host service factories.
Only then can signed Mac/iCloud/iPhone request, transfer, download and playback
be accepted. The local same-process pair is not that shipping bridge.
