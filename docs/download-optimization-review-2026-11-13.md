# Lossless download optimization before 1.1

Read-only runtime review against 1.0.0. No assets published, manifests changed or
download behavior modified. Local experiment: zstd level 3, individual complete
files, English Max base plus all published delivery styles. Source files were
verified against catalog sizes/SHA-256 before compression; all decompressed files
matched those same sizes/SHA-256. Measurements are not network or iPhone timings.

| Complete English installation | Files | Current transport bytes | zstd-3 bytes | Reduction |
|---|---:|---:|---:|---:|
| Max MLX | 86 | 612,187,052 | 522,361,824 | 14.67% |
| Max Core ML | 105 | 1,172,030,056 | 724,554,312 | 38.18% |

Core ML weight files individually shrink 53.6–54.6%; MLX model.safetensors shrinks
28.0%. Voice/style files reduce the whole-pack percentage. Local streaming decode
plus SHA-256 totals were 1.19 s for MLX and 2.11 s for Core ML on this Mac, including
one subprocess per file; these are single-run feasibility observations, not device
benchmarks. The full report, original hashes and codec version are at
`/tmp/libroxtts-download-review-2026-11-13/compression.json`; the reproducer is the
adjacent `measure.py`. No compressed temporary payloads remain.

Catalog totals for all seven languages plus all styles are 4,285,317,840 bytes
for MLX and 8,204,218,847 bytes for Core ML. English compression ratios must not be
presented as measured totals for the other languages. Whole-file deduplication
would save only 309,018 bytes in either complete set; it is not the main win.

Basic already downloads a 499,340,346-byte tar.gz which expands to 537,603,132
installed bytes. Max currently downloads individual uncompressed catalog files.
Plus requires its own compression measurements before making savings claims.

## Recommended design

1. Publish separate immutable compressed transport artifacts; retain original
   downloads and installed-file hashes, paths, model identities and cache identities.
   Do not point an existing raw URL/hash entry at compressed data.
2. Compare zstd with existing zlib support on complete packs and physical devices.
   zstd is a promising candidate, not yet an admitted runtime dependency.
3. Use bounded streaming decompression to a staged destination. Verify compressed
   artifacts and reconstructed original files before adoption; retain size limits,
   cancellation, traversal protection, disk-full recovery and existing installations.
4. Prefer independently retryable file/chunk artifacts over a single multi-GB
   archive. Benchmark 16–64 MiB chunks for large files; validate compression-ratio,
   request-count, temporary-disk and memory tradeoffs. Group tiny metadata only
   where it preserves existing reuse and repair behavior.
5. Add persistent resumable transfers with bounded concurrency and validators.
   The SDK foreground convenience downloader is currently serial, skips completed
   verified files and does not persist partial-file resume state. Host applications
   can already have their own background downloaders; inspect those before claiming
   an app resumability defect. Resume support and range behavior need hosted tests.
6. Keep installed-file manifests and the legacy path compatible. An additive
   transport plan needs SDK and host-downloader integration, accurate wire-byte
   estimates/progress and explicit download/decompress/verify/prepare phases. Do
   not silently redefine existing public download-size/progress contracts.

Complete Max installation must still include every requested language/voice/style;
this proposal does not shrink the advertised feature set. Verified installations
must not redownload merely because a new compressed representation is available.
Transport revision is distinct from model, delivery and prepared-audio identity.

## Qualification

Measure all seven languages, then Plus; compare total time to ready under constrained
and fast networks, including Core ML compilation. Test kill/resume, truncated and
corrupt data, changed validators, disk exhaustion and preservation of a prior install.
Measure peak RAM and temporary disk on iPhone/iPad. Require exact installed bytes,
unchanged raw/facade PCM and unchanged 1.0 Max loudness/cache behavior.

Compression reduces transferred bytes, not final model size or synthesis time.
The larger Core ML reduction makes this worth pursuing before the 1.1 inference
work, while keeping publication separate until transport and host compatibility
are qualified.

References:
- [Zstandard lossless format](https://github.com/facebook/zstd/blob/dev/doc/zstd_compression_format.md)
- [Apple download resumption](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads)
