# Local complete-publication receipts

`ChapterLocalCompletion` is an immutable metadata transport between the local
Worker and Reader. A receipt names an exact wanted `ChapterIntentReadSet` and
complete `ChapterLocalHandoffReference`. It is not playable audio, a demand
acknowledgement, an inference grant, or a CloudKit receipt.

The package-only Mac publisher consumes a live `ChatterboxMacWorkerPublication`
returned after the original render, codec, custody and handoff producer has
joined and its storage allowance has settled. The result carries a small
nonretaining lifecycle fence: stopping, re-enabling, shutting down or destroying
the originating Worker invalidates it. Neither that fence, the producer epoch,
nor ephemeral timing/cache measurements are serialized.

The SDK `ChatterboxMacLocalWorkerSupervisor` owns the publication task after
`render` returns. It cancels and joins that exact task before disabling or shutting
down the Worker. `Worker.disable()` alone does not join a separately invoked
metadata task. See `CHATTERBOX-MAC-LOCAL-SUPERVISOR.md`; the concrete Reader
service/provider remains pending.

Each canonical checksummed V1 envelope is limited to 128 KiB. Its deterministic
leaf is `completion-<SHA256 of canonical exact read set>.json`. Bounded no-follow
descriptor reads validate regular-file size, identity and modification state;
decoding checks canonical bytes, the body checksum and exact read-set key.
Only a missing exact leaf returns `nil`; missing roots, invalid data, symlinks
and unavailable or changed Reader authority fail closed. There is no scan or
fallback to a different intent. Existing source/plan blobs retain their original
content-hash namespace and validation.

Publication writes and verifies an owned staging file, synchronizes it, links
without replacement and synchronizes the parent. A retry accepts only identical
existing metadata. A conflicting handoff for the same intent fails without
replacement. Cancellation or a lost callback after the link can leave a complete
record; no rollback deletes it. Unknown files are preserved. The Mac seam reserves
twice the metadata cap for temporary/final logical aliases, joins the exact
metadata/file producers, then settles the allowance before returning success.
This uses the existing soft storage admission, not an OS quota or atomic free
space guarantee.

Both publication and observation validate the current wanted read set and their
own account session before and after asynchronous work. A Reader uses its own
fresh epoch and still must receive, privately copy, hash and decode the complete
audio under its storage allowance, then atomically accept that verified handoff
against its current wanted intent. Discovering this metadata never sets ready or
updates server acknowledgement. A late physical receipt may exist after a stale
or cancelled call without becoming accepted Reader playback.

The host must establish Worker-only writes and Reader reads for these private
paths. Checksums detect corruption; they do not authenticate arbitrary writers.
Signed separate-process/App Group access, power-loss behavior, actual narration,
live account and cloud transport remain unqualified. Tests use synthetic
narration and real AAC export/copy/readback, with no production model forwards.

The concrete prepared service, catalog transport and authenticated descriptor
transport remain subsequent SDK work. No app factory or runtime is activated by
this component.
