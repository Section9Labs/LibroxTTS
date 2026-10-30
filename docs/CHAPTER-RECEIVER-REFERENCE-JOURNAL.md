# Reader-owned retained handoff references

`ChapterDemandOutbox` now retains an immutable `ChapterLocalHandoffReference` beside an existing demand entry. This reuses the already exclusive, account/device-partitioned Reader journal and atomic snapshot persistence; it does not create a journal shared with the companion. Worker claims/checkpoints remain in separate Worker storage.

```swift
let intent = try await readerOutbox.setDemand(true, for: request)
// After receiving the matching immutable publication identity:
let accepted = try await readerOutbox.rememberHandoff(reference, for: intent)

// On reopen, this is only a recovery identity:
if let saved = try await readerOutbox.retainedHandoff(for: request) {
    let artifact = try await ChapterLocalHandoff.receive(
        saved.reference, submission: currentReaderSubmission, gate: currentReaderGate,
        directory: workerPublishedDirectory, storageDirectory: readerArtifactDirectory)
    // Only this freshly verified custody can enter the existing playback path.
}
```

`rememberHandoff` accepts only the exact current intent from this account/device, with `wanted=true`. Late callbacks for an earlier request revision or a cancellation cannot replace the reference. It records the reference and its original intent revision, without clearing `pending`, creating a server revision, or acknowledging demand. Missing or incorrect external publication data still fails ordinary receiver admission.

Cancel and re-request preserve the completed reference and its original `recordedAtIntentRevision`. That revision is deliberately distinct from the current intent revision: preserving an available asset does not acknowledge a new cancellation or request. No audio, source text, local URL, account epoch or playable handle is serialized in this field. Reader source/submission persistence remains a separate required implementation.

The original V1 encoding/checksum is retained while no handoff exists. The first remembered reference writes explicit journal V2. New code reads V1 and V2 and verifies version/presence consistency, reference syntax, checksum and `0 < recordedAtIntentRevision <= currentIntent.revision`. Older writers reject V2 rather than silently stripping recovery data. Opening a journal does not rewrite it. All owners of a namespace must therefore use the compatible SDK before enabling this new mutation; never open the same journal from both apps or downgrade/reset it to acquire ownership.

Existing 8,192-entry / 32-MiB journal bounds and ownership locks are unchanged. Snapshot writes synchronize the temporary file, rename it and synchronize the containing directory. An ambiguous post-rename failure blocks further access/writes until close/reopen reconciliation; a committed reference must not be discarded because its acknowledgement was lost. As with existing demand mutations, cancellation after commit can leave durable state. The service validates task cancellation and account epoch after each await before accepting UI work.

This is a retained-reference journal, not durable adoption of a `ChapterLocalArtifact` object or proof that a file still exists. Reopen must use exact source and a fresh admitted Reader session/gate, then actually copy, decode and verify the publication. Corrupt/missing/stale records do not become playable and never justify a silent reset or regeneration. This stage supplies no catalog/service factory, submission/source spool, aggregate artifact quota, retention sweep, Worker scheduler or CloudKit acknowledgement.

Release validation covers reopen, cancel/re-request retention, rejection of stale/account/device callbacks, pending/server-confirmation independence, ambiguous-write recovery, structural corruption with an independently recomputed checksum, and reference reopen followed by fresh-session real WAV custody. These are synthetic local filesystem tests. They do not qualify a signed two-process App Group path, live account/cloud operation, native model generation, actual playback, or an app release.
