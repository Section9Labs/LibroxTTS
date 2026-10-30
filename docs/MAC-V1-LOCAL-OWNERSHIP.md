# Mac v1 process ownership and local acceptance

The selected first delivery is a standalone native companion beside the Catalyst
reader. The release owner controls signing/profiles/notarization. Initial runtime
acceptance is genuine local generation/playback; cloud remains excluded until its
own signed-host/account/transfer qualification. This document grants no launch,
portal, login, network or cloud-operation authority.

## Exactly one mutating process per journal

| Storage / mutable state | Sole mutating owner | Other process access |
| --- | --- | --- |
| Reader demand outbox, future local submission/source journal | Reader process | No direct open or mutation by the companion |
| Worker claims/generations/checkpoints, renderer progress and worker identity | Native companion | Reader receives immutable service snapshots, not journal handles |
| Native renderer KV state, conditioning snapshots, raw synthesis cache and temporary output | Native companion | No reader access to in-progress files or model objects |
| Reader verified downloaded/adopted audio availability and playback state | Reader process | Companion publishes a complete immutable artifact, never edits reader availability |
| Per-operation source/asset staging custody | The process performing that operation | File scope stays owned until actual operation completion; no borrowed URL as durable availability |
| Stable installation/device identity file | Existing narrowly locked identity creator | Both may read the resulting immutable identity; this does not permit shared journal writes |

A worker identity is separate from a requesting device's demand identity. The
companion does not become an additional requester merely by rendering a reader's
request. A shared physical-device ID does not make a mutable outbox multiprocess.

The implemented `ChapterDemandOutbox` must be opened by exactly one owner of its
account/device partition. Its exclusive descriptor lock is held for the handle's
lifetime. Never open the same journal in both apps, even under different actors.
A new instance after process death must reconcile the existing checked journal;
it must not reset revisions or delete uncertain state to acquire ownership.
Worker and reader stores use separate role roots and independent lifetime locks.
Their durable implementations remain pending; the role assignment is settled,
not evidence those stores already exist.

Account/environment partitions bind to actual signed container/environment/user
identity, with a fresh local epoch for every lifecycle. Old source/queue/audio
partitions remain preserved on disable/logout. Old callbacks cannot adopt data
into a new epoch, including sign-out/sign-in to the same account. Neither a shared
App Group URL nor a title/hash metadata row authorizes arbitrary book-file access.

## Cross-process protocol

Cross-process communication is through immutable, identity-bound requests,
versioned receipts/status snapshots and complete artifact publication. No client
passes an open mutable journal or the reader's SwiftData database to the helper.
The reader supplies authorized exact extraction and original book/source hashes.
The SDK owns all planning/rendering/source-map/codec/custody work.

Before a file-based local spool is bound, the SDK must implement and test its
admission, durable publication, fencing, account/owner isolation and recovery.
A copied JSON file or filesystem notification alone is not a queue transaction.
Until that concrete transport exists, the real backend remains unavailable.

Complete audio is privately copied and decoded/verified by the receiving owner
before becoming playable. Do not play helper in-progress output, transfer mutable
availability databases, or estimate word/fragment timestamps from character count.
The future cloud route uses the same receipt/fence model, not a shared journal.
Existing value-only `ChapterJob` is not a distributed lock.

## First isolated local fixture runtime

For MAIN's upcoming explicit runtime contract, use an isolated per-run input and
output root with one mutating companion process, approved public stock inputs,
exact source hashes/ranges and pinned Standard model/runtime assets. The local
fixture does not open a demand outbox or instantiate a CloudKit account/container.
It does not create a fake signed cloud identity. Login and cloud remain disabled.
The host supplies only the approved source/controls and consumes real SDK output.
The SDK local-render facade and full-chapter admission are still implementation
work; CLI sample completion is not installed-host proof.

Only after the genuine profile/signed artifact and exact runtime contract exist
may the app owner execute the bounded host checks. Passing fake-service tests or
an unsigned compile does not activate a production provider. The existing
companion69-test artifacts and SDK pin remain frozen until an actual reviewed
SDK dependency is supplied. No phone operation is part of this route.
