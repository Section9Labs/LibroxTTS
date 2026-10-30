# Immutable local worker → reader audio handoff

`ChapterLocalHandoff` is a filesystem transfer component, not a service, catalog, request queue, job claim, CloudKit transport, login helper, or playback controller. It does not start a renderer or submit demand. App-side factories remain unavailable until the remaining integration and host gates are qualified.

The publisher owns an existing private Worker publication directory. The reader only reads its completed bundles and copies admitted audio into its own private Reader artifact storage. Neither process opens the other's mutable outbox/journal. The app supplies the settled role directories; the SDK additionally rejects receiver custody inside Published and publication inside ephemeral source custody, using resolved filesystem ancestry bound to descriptor identities. Ancestor-symlink aliases cannot evade those exclusions.

Publication requires an already verified `ChapterLocalArtifact`, its exact original `ChapterSubmission`, and the publisher's current session/gate. Request/session equality and complete source-map validation are mandatory. The explicit new `validateCompleteSourceMap` method is bounded to the first local 131,072-UTF16 chapter scope; the existing range-only validator is unchanged. Complete admission rejects omitted non-whitespace source and split graphemes. Whitespace and attachment placeholders may remain unspoken.

```swift
let reference = try await ChapterLocalHandoff.publish(
    workerArtifact, submission: workerSubmission,
    gate: workerGate, directory: workerPublishedDirectory)

// Transfer only immutable reference/request metadata through the future SDK
// service/spool. The receiver supplies its own admitted source and NEW epoch.
let readerArtifact = try await ChapterLocalHandoff.receive(
    reference, submission: readerSubmission, gate: readerGate,
    directory: workerPublishedDirectory, storageDirectory: readerArtifactDirectory)
```

The content reference is the SHA-256 of canonical metadata containing the exact render request and complete artifact manifest. It contains no filesystem path or producer epoch. Its public initializer and decoder admit only 64 lowercase hexadecimal characters. A reference is an identity, **not** a credential, publication acknowledgement, download receipt, or playable state. The first local scope admits at most 4,096 units and 131,072 total fragments, eight MiB metadata, the existing one-GiB encoded manifest limit, and six hours of decoded audio. The metadata structural counts are checked before encoding; all audio copy/hash work uses 65,536-byte chunks with autorelease pools and cancellation checks.

The worker stages exact encoded audio and metadata in a new mode-0700 UUID directory. File descriptors bind regular-file identities, size, timestamps and hashes. Files are synchronized and made read-only. Actual staged audio bytes are hashed again before publication. `renameatx_np(RENAME_EXCL)` atomically publishes the complete directory without replacing another entry. Both a new rename and a matching-existing reconciliation synchronize and fence the parent before reporting success. An existing bundle is reused only after exact metadata and encoded hash verification; corrupt or unrelated data is preserved and rejected.

Publication checks the current publisher gate before commit and after completion. A cancellation, epoch change or storage failure after rename can leave a complete bundle without a returned acknowledgement. The bundle is retained. `contentReference(for:submission:)` lets the owning future journal predict that recovery identity; it is side-effect-free and does not prove anything was published. Interrupted staging directories are not completed bundles. Normal error cleanup removes only descriptor-bound owned files and their matching empty staging directory. Unknown entries are preserved; cleanup is never recursive. No retention sweep or automatic repair is implemented.

The reader opens the identified complete directory, admits bounded canonical metadata, matches its **own exact expected request**, and validates the complete map against its own original source. It never opens or reuses a producer epoch. `ChapterLocalArtifact.adopt` then performs actual byte-hash, codec, rate/channel, gapless-frame and finite/full-scale verification while making a private reader copy under the reader's current session/gate. Parent, bundle and reader-storage identities plus metadata are rechecked across awaits. Revocation returns no handle; a reference, metadata record or file URL never becomes playable by itself. The host must still stop current playback and cancel/join operations on lifecycle revocation.

This API assumes trusted app-owned private directories with the publisher as their sole writer. It does not authenticate an arbitrary external filesystem tree, establish App Group entitlements, defend against adversarial same-user mutation, or supply distributed authorization. The canonical CloudKit account/environment derivation remains separate and cannot be inferred from build flags.

The current Release tests use synthetic audio and two independent in-process account gates. They cover actual WAV/AAC readback, exact immutable copies, fresh receiver epochs, request mismatch, complete-map rejection, cancellation/join and unknown-file preservation, lost-ack recovery, post-adoption revocation, corruption/symlink rejection, directory replacement and stable ancestor aliases. These are restart-shaped reopen and filesystem protocol tests, **not** independent signed-process, real App Group, power-loss fault-injection, live account, native model generation, cloud transfer or real playback acceptance.

Remaining SDK work includes durable source/submission intent publication, a receiver-owned reference/adoption journal and bounded aggregate retention/quota, worker checkpoints and service/catalog orchestration. Signed native helper/reader transport, safe disable/login lifecycle and eventual CloudKit delivery still require their own host/runtime qualification. Keep the existing frozen app/353 pin until a reviewed committed dependency and explicit runtime scope are provided.
