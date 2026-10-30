# Durable exact source and Reader intent pairing

`ChapterLocalSource` publishes a bounded, immutable source blob in a Reader-owned source directory. It carries only account partition, original book/chapter/extraction identity and exact source text. No device/session epoch, mutable journal, book-file URL, voice recording, conditioning bytes, or model is transferred. This component does not queue or authorize inference by itself.

Source admission is explicitly limited to 131,072 UTF-16 units / 393,216 UTF-8 bytes. Canonical JSON has a two-MiB cap. Exact UTF-8 hashing/length and canonical re-encoding protect NFD, CRLF, attachment placeholders and control characters across serialization; no normalization or lossy replacement occurs. Identity includes account and original source, so the same source can be reused across delivery formats and rendering settings without duplicating its text. References admit only lowercase 64-character SHA-256 values, including when decoded.

```swift
let publishedSource = try await ChapterLocalSource.publish(
    exactReaderSubmission, gate: readerGate, directory: readerSourceDirectory)
let intent = try await readerOutbox.setDemand(
    true, for: exactReaderSubmission.request, source: publishedSource)
// Intent and source reference are now ONE durable Reader journal snapshot.

// On reopen the Reader retrieves this pair; a future SDK immutable intent
// transport delivers the admitted snapshot to the worker without sharing a journal.
if let stored = try await readerOutbox.storedSubmission(for: request) {
    let workerSubmission = try await ChapterLocalSource.receive(
        stored.sourceReference, request: stored.intent.request,
        session: workerSession, gate: workerGate, directory: readerSourceDirectory)
    // Source recovery only; actual rendering needs current intent/plan admission.
}
```

An absent snapshot requires source/submission preparation rather than inference. This example shows source recovery, not permission to render a `wanted=false` intent or to use a received source without authoritative intent/catalog admission. The Worker never opens the Reader's `ChapterDemandOutbox` or SwiftData store.

Publication uses an owned detached task: bounded writes and actual readback, file synchronization/read-only mode, then atomic no-replace linking into the content-addressed destination. Existing matches are hash/byte checked and the parent is synchronized on both new and reconciliation paths. Supplied and resolved directory paths are bound to retained descriptor identities. Cancellation and current publisher gate are checked before commit and after operation completion. An ambiguous/post-commit failure can retain a complete blob without returning a publication receipt; repetition reconciles rather than replacing it. Cleanup removes only a matching owned staging file. Unknown data is preserved. Local filesystem operations still must finish before the owning task can be released.

Receive opens only the exact reference, with regular-file/no-symlink/nonblocking checks and bounded descriptor-based reads. It verifies content hash, canonical bytes, account/source identity and original text against the expected request, then returns an immutable `ChapterSubmission` bound to the Worker's **own** fresh session. The publisher's epoch is not serialized or reused. No staging URL escapes. Hosts/services derive account partitions from actual signed configuration and observe lifecycle changes; this API does not discover or open an account.

The Reader journal's source overload admits only an SDK-created matching `ChapterLocalSourcePublication`. Source keys are compared by canonical digest, so Swift-canonically-equal but byte-distinct NFD/NFC keys cannot silently match. Adding a source to an existing legacy wanted intent advances its revision even when `wanted` is unchanged, fencing late callbacks. Cancellation/re-request preserve source and completed-audio references. Neither source persistence nor `storedSubmission` clears pending demand, creates a server acknowledgement or marks audio playable.

Journal V1 remains unchanged with no new references; V2 remains unchanged for handoff-only recovery entries. Storing a source reference selects explicit V3. New code reads V1/V2/V3 and checks version/presence, references, checksum and intent structure. Older writers fail closed instead of dropping new data. No user journal has been opened or migrated by this checkpoint. Compatible owners and migration/recovery validation are release prerequisites; never reset or downgrade a journal to acquire its lock.

Crash ordering is deliberate: source is published **before** the atomic intent/reference journal write. Failure between them can leave an orphan source, but cannot create an intent pointing to an uncommitted source through this API. Source existence alone authorizes no work. A failed post-rename journal write blocks stale in-memory use until close/reopen recovery of the entire pair. Aggregate quota/retention, durable intent delivery and an authoritative Worker read-set still need implementation.

This is not yet a portable render plan. `ChapterRenderRequest` contains identity digests; a worker cannot recover exaggeration, CFG, temperature, direction/grouping or authored expression annotations from those hashes. A separately versioned SDK payload carrying those exact options must accompany immutable intent publication, and the Worker must reconstruct and compare the canonical recipe against its actual backend before inference. No default reconstruction or expression loss is authorized by source receipt.

Current Release checks use synthetic source data and in-process Reader/Worker gates: exact Unicode/control text beyond 64 KiB, delivery reuse, source/intent atomic persistence and reopen, revision advancement/stale-ack fencing, ambiguous journal recovery, source-key mismatch, pre-commit cancellation, late epoch revocation, corruption/no replacement, bounds and FIFO rejection. These do not establish signed-process/App Group transport, live account/cloud service, native generation, narration quality/speed, or a releasable backend. All existing app pins and runtime scopes remain frozen until the reviewed committed dependency and separate host authority arrive.
