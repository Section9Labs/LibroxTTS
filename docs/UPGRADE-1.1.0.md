# LibroxTTS 1.1.0 — compressed Max downloads

1.1 adds lossless gzip transport for all seven Max languages and all published
voices/styles. It does not change installed model bytes, synthesis, sampler
settings, 1.0 Max loudness profiles, model identities or prepared-audio identities.
Basic and Plus retain their existing transport. Existing installations need no
redownload and existing 1.0 audio caches remain valid.

Measured complete fresh download sizes (decimal bytes, including original raw
fallback files):

| Scope | Original | 1.1 gzip transport | Reduction |
|---|---:|---:|---:|
| English Max, MLX | 612,187,052 | 525,207,728 | 14.21% |
| English Max, Core ML | 1,172,030,056 | 732,448,602 | 37.51% |
| All seven Max languages, MLX | 4,285,317,840 | 3,677,540,496 | 14.18% |
| All seven Max languages, Core ML | 8,204,218,847 | 5,128,829,785 | 37.49% |

Installed size is unchanged. These are byte counts, not network-speed promises.
Compression uses the existing zlib dependency; no new runtime dependency.

## API and ownership

Legacy `AssetManifest`, `NarrationAssets` download/prepare methods, progress and
size estimates remain unchanged. New transport is explicitly adopted through
`NarrationDownloads`; upgrading the dependency alone does not convert a host's
legacy background downloader.

```swift
let manifest = try NarrationAssets.manifest(.pocket, language: language)
let plan = try NarrationDownloads.plan(for: manifest)
try await NarrationDownloads.download(plan, to: stagingRoot,
    cache: transferCache, maximumConcurrentDownloads: 3)
try NarrationAssets.prepare(stagingRoot, model: .pocket, language: language)
```

The example is the base-language manifest only. Preserve Librox's complete Max
install scope: also plan/download `PocketTTSDeliveryCatalog.manifest(language:)`
and call `NarrationAssets.preparePocketDeliveryStyles(in:language:)`. A narrator
preset or single-style manifest can also be passed to `plan(for:)`; do not silently
substitute either for the app's complete language/voice/style installation.

The new foreground helper caps concurrent files at four (default three), downloads
chunks within a file in order, and reuses hash-verified chunks across retries.
OS-provided resume metadata is retained; unavailable or stale resume data can
restart the current chunk. Each compressed chunk reconstructs at most 64 MiB.
The helper does not own background sessions or promise networking survives process
exit. Preserve the app's existing background URLSession for that purpose.

## Background downloader integration

1. Obtain the same original manifests as before; build a plan for each. Keep
   original repository/install receipts and paths. Persist a separate transport
   receipt keyed by plan revision and artifact SHA-256, never by transient URLs.
2. For each `plan.files` entry, verify `file.installed` in the destination first.
   Skip all its artifacts when the original file is already correct.
3. Download each `file.artifacts` item using `artifact.url`, `size` and `sha256`.
   Use ordinary binary requests: a `.gz` artifact is explicit content, not an
   HTTP Content-Encoding request. Retain existing background session identifiers,
   resume/cancel behavior and persisted task mappings.
4. Reuse verified artifacts. Resume using URLSession's supported resume data;
   handle missing/invalid resume data by restarting only the affected artifact.
   Never append a full HTTP 200 response to a partial body as if it were a range.
5. Once all artifacts for one original file are present, call:
   `NarrationDownloads.install(file, from: orderedArtifactURLs, in: stagingRoot)`.
   Order must match `file.artifacts`. The SDK verifies compressed hashes, streams
   bounded decompression, verifies the original hash, then atomically publishes
   the file. Sources remain host-owned and may be reused/removed by the host.
6. After all requested files succeed, call the existing matching prepare APIs.
   Continue to gate readiness on original asset verification and Core ML
   preparation, then publish the host's existing complete-install receipt.
7. Download UI uses `plan.downloadSize` and missing-artifact wire sizes. Installation
   disk estimates use original files plus staged output/compiled assets and cached
   compressed data. Do not use compressed size as installed size. Foreground
   helper progress means verified wire bytes; 100% is not model readiness.
8. Serialize installation/removal for a destination with rendering, and serialize
   helpers sharing a transfer cache. Keep cache outside the installed model tree,
   apply host cache/backup/data-protection rules and remove unneeded transfer data
   after successful preparation. A failed/cancelled install must retain useful
   verified chunks and preserve existing installed files.

On failure, surface the existing retry/install UI. Do not silently download a
second full raw pack or mark a partial installation ready. Legacy clients continue
using the old URLs; there is no forced asset migration.

## Frozen audio behavior

Keep Max's `pocket-level-v1-41466443134c33e7` profiles and existing SDK render
identities. Do not add host normalization, change selected voices/styles/speed,
reset downloads, delete model installations or invalidate 1.0 prepared audio.
Transport chunks are never loaded by a synthesis engine.

## Prompt for the Librox session

Upgrade Librox to LibroxTTS 1.1.0 and integrate its new compressed Max transport.
Read this handoff and the actual SDK declarations before editing. Preserve the
current complete Max installation scope, all seven supported languages and all
published voices/styles, resumable background downloading, accepted download UI,
asset receipts, user data and existing installed models.

Use `NarrationDownloads.plan(for:)` with the same original manifests, download the
returned artifacts through the app's existing background URLSession, and call
`NarrationDownloads.install(_:from:in:)` with ordered verified artifact URLs. Keep
original manifest identity/hash validation and existing prepare/readiness checks.
Separate compressed wire-byte progress from decompression/verification/Core ML
preparation. Reuse correct installed files without any redownload. Preserve useful
completed chunks across interruption; bound concurrency and installation memory.

Keep 1.0 Max loudness defaults and render/cache identities exactly as they are.
No additional normalizer, cache invalidation, model deletion, narration behavior
change or synthesis optimization belongs in this migration. Basic/Plus transport
is unchanged. Existing legacy URLs remain compatible.

Test a fresh Max download, interrupted/resumed download, process relaunch,
corrupt/truncated artifact, already-installed no-download path, full voice/style
readiness and a short playback smoke test on the app. Verify exact resolved SDK
tag/SHA and report the measured download bytes, time-to-ready, peak installation
memory/disk and remaining device gaps. Commit the integration and report validation;
do not upload an app build unless separately authorized.
