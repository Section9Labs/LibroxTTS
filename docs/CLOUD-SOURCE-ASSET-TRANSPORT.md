# Exact source CKAsset transport

Status: native source-only transport implemented, offline contract and real local
file tests pass. This is not a deployed CloudKit schema, durable source database,
ChapterService, render worker or working cross-device chapter feature. No live
CloudKit calls have run in this stage.

## Native contract

`ChapterCloudTextTransport` accepts the actual signed container/account identity,
a fresh account session/gate, an app-owned account-partitioned storage directory,
and a live asset-transfer authorization closure. The closure is called before
every operation and reconciliation attempt; a captured reachability or Wi-Fi
preference snapshot is insufficient. Construction performs no network operation.
The default environment is never inferred from Debug/Release or APS.

The proposed pre-provisioned private custom zone is `LibroxProChaptersV1`.
The proposed record type is `LibroxChapterSourceV1`:

| Field | Type | Binding |
| --- | --- | --- |
| `manifestV1` | Bytes | Canonical sorted JSON, <=128KiB; exact source identity/account/UTF8 byte count/hash |
| `sourceV1` | Asset | Exact original UTF8 extraction; no normalization/re-extraction/audio/voice conditioning |

Record name is `s-` plus the validated source key. The key is independent of
AAC/ALAC options; its use is always scoped by the private account and manifest.
The adapter never creates a zone, deploys schema or overwrites an existing source.
It inserts with `ifServerRecordUnchanged` in an atomic modification operation.
A different or corrupt record is rejected rather than silently repaired.

A normal publish reads metadata then inserts. An already present source requires
metadata admission followed by verified asset download. An ambiguous save or
conflict permits one metadata+asset reconciliation, not a blind repeated upload.
Server quota/backoff/configuration failures and local file/verification failures
retain their actual categories. Source acceptance is not a device-demand receipt,
job status or playback availability.

`ChapterSourceServerReceipt.evidence` distinguishes `acknowledgedUpload` (actual
save acknowledgement plus stable verified input custody) from `verifiedDownload`
(actual independent private verified copy). The opaque revision hashes the bound
account/source/type/server tag/payload; it is not a clock or worker lease. An
operation can have reached the server even if its caller later cancels; a missing
receipt is not proof that nothing was uploaded.

## File and operation lifetime

Input `ChapterTextAsset.withFileAccess` remains alive through actual Foundation
operation completion and its post-operation account/content/path checks.
Cancellation cancels the owned CK operation and awaits Foundation completion.
Request/resource timeout configuration is15/30 seconds. There is no detached
network request or later retry launched after the caller returns.

Metadata is fetched without the asset first. Its exact canonical manifest is
admitted before requesting the asset; the second response must match its tag and
payload. CloudKit's staged files can be reclaimed. The native adapter therefore
copies and verifies the downloaded source inside its per-record callback, before
operation completion; retaining a CKRecord alone is not a staging-file guarantee.
The outer actor validates the session after completion before returning custody.
[Apple CKAsset documentation](https://developer.apple.com/documentation/cloudkit/ckasset)
explains staging and the use of desiredKeys to omit assets.

The callback copy uses the same bounded regular-file/NOFOLLOW/private-inode
builder as local source adoption. It applies cancellation checks between64KiB
chunks and after verification. Only a verified private copy may survive removal
of the staging URL. Per-record operation references are weak, and completion
handoffs empty result slots so completed callback objects do not retain custody.
No original, staging, unknown or unrelated file is recursively removed.

The40MB manifest bound limits private copy/verification and allocation, not the
opaque CloudKit wire/download-cache size if server metadata lies. Native SDK
request deadlines and host storage/network policy remain necessary. Actual
CloudKit cancellation, sleep, account switch, framework staging, network bytes
and storage pressure still require signed-host qualification. Local epoch fences
establish rejection of stale results; offline tests do not prove CloudKit's
account-switch behavior or the absence of an in-flight server write.

## Validation and remaining integration

All66 Release ChapterWorker tests pass. New source cases cover exact Unicode
>64KiB, independent private download, source reuse across delivery formats,
one lost-ack reconciliation and per-operation authorization, malformed metadata
before asset request, changed tags/corrupt bytes, epoch revocation at the second
authorization, ownership while a cancelled insert deliberately delays completion,
source staging disappearing before completion, mid-copy cancellation cleanup,
permanent backoff and local-error classification. Fakes establish SDK contract
behavior; they do not establish CloudKit delivery. No native CKContainer is
instantiated in the unsigned test host.

Required next stages remain durable source/outbox adoption, authoritative
intent-read-set worker leases/generation/fences, complete chapter rendering and
source maps beyond excerpt limits, verified audio publication/download, a real
ChapterService/provider, signed helper/account/environment/schema provisioning,
and real Mac/iCloud/reader playback tests. No UI may present the backend as ready
from this source transport alone. No private phone recordings or conditioning
are uploaded by this API.
