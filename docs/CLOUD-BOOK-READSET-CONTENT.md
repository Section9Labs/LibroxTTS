# Complete immutable book policy and desired-entry read set

`ChapterBookReadSet` carries the FULL exact canonical book scope: original
ordered spine (including unadmitted empty/attachment/front-matter positions),
actual typed backend/settings configuration bytes, device preparation intent,
current priority, and strictly ordered admitted-entry metadata. Per-entry rows
bind source hash/UTF16 length and exact desired render key/content identity.
No local source/plan references, paths, handles, producer epoch or content/book
acknowledgement tags are serialized. Acknowledgements alone do not churn this
asset identity at the same logical intent revision.

Each chapter's complete authored options remain in its exact referenced entry
content. `ChatterboxPreparedBookReadSet` restores the complete typed policy and,
after real entry-content download, validates the SPECIFIC desired render key,
source and content identity. Common book defaults alone cannot replace authored
controls. Actual receiver epoch/account, supported planner and source/plan
fingerprints still apply. No settings are reconstructed from opaque hashes.

The read set is limited to12 MiB, with at most4096 entries and the existing
4 MiB canonical scope bound. Rows contain fixed-size identities/digests instead
of repeated full renderer profiles/requests. Missing rows or nil content
identities mean unadmitted/pending source, never silent proof or completion.
Even an empty read set retains the entire original spine and priority. Literal
silence requires its actual exact entry-content validation later; metadata is
not zero-frame media. This is desired-state CONTENT, not actual current intent.

`ChapterCloudBookReadSetTransport` uses the proposed private
`LibroxProChaptersV1` / `LibroxBookReadSetV1` record:

- `brs-<canonical identity SHA256>`;
- `manifestV1`: canonical Bytes<=4096, bound to account/scope/device/revision,
  payload SHA and exact size;
- `contentV1`: CKAsset, private capture/verification bound12 MiB.

Typed metadata is admitted BEFORE asset fetch. The reusable private
`NativeChapterCloudAssetStore` captures downloaded bytes inside the per-record
callback before Foundation staging can disappear. Upload captures remain alive
through Foundation completion. It reuses the owned native operation helper,
explicit15s request/30s resource settings, weak operation capture and cleared
result slots. These configurations are not guaranteed wall deadlines.
`ChapterCloudFileCapture.data` uses bounded pread on the pinned FD; concurrent
readers do not mutate a shared file offset, and all before/after hash, path,
root, account/cancellation checks remain in force. Actual native wire/cache
volume is opaque and is NOT bounded by the private capture limit.

Only one uncertain/conflict reconciliation fetches and verifies actual full
bytes. Local I/O/hash/canonical/epoch/cancel failures are not network retries.
Live host transfer authorization runs before EVERY native operation. Successful
upload returns a package-only receipt constructed from the admitted native
snapshot/verified existing bytes and own operation session. It is PAST immutable
content evidence, never a book acknowledgement, clock, lease, current read-set
grant or playable asset. A separate current member transaction must name the
exact identity; Worker claim/generation and Reader acceptance fences remain
mandatory even if this content exists.

This component does not instantiate a container, create a zone/deploy schema,
query demand, publish a mutable member/head, claim work or activate a factory.
Offline store/filesystem tests are not live CloudKit, separately signed hosts,
power-loss, aggregate quota or media/rendering proof. The eventual service must
own its calls, apply aggregate soft admission and current-intent pre/post checks,
and retain recoverable source/options. Native authoritative book/member CAS,
actual prepared catalog, generation/lease/clock policy, ordered segment heads,
Reader current-book audio acceptance and real separate-host factories remain.
