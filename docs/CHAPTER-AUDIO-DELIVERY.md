# Chapter audio delivery

The user chooses **Lossless** (ALAC24) or **Smaller files** (AAC-LC, requested
64 kbps, mono 24 kHz). Lossless remains the default UI preference. This is an
encoding choice, independent of stock voice, expression, model, solver and
synthesis precision. AAC is lossy and must not be advertised as equivalent to
lossless. The native encoder may realize a bitrate different from the request.

`ChapterAudioDelivery` is the typed SDK choice. New clients pass it explicitly
as `ChapterRenderRequest.delivery`. It participates in `renderKey()`, so queues,
receipts, manifests and downloads cannot confuse encodings. `synthesisKey()`
excludes delivery and may identify reusable, verified original PCM. Never
re-encode AAC to make a lossless rendition; encode both from original PCM.
Changing a preference affects new requests; it does not rewrite saved books or
silently cancel an existing device demand.

Compatibility: omitted delivery preserves the old serialized request and hash.
That legacy request remains WAV/ALAC-only; it cannot admit AAC. Explicit
lossless accepts `alac24-1`, and explicit smaller accepts `aac-lc-64k-1`.
Unknown formats fail decoding. An explicit request's manifest codec must match.
The local artifact factory then checks actual decoded codec, 24 kHz mono,
exact gapless frame count, bounded reads, finite samples and peak <=1. A file
extension, hash or remote-ready record is not playable proof. AAC has no
sample-equivalence claim. Unsupported/invalid output fails; no silent fallback.

A catalog lists supported `deliveryFormats`; default is lossless only. The app
must offer only end-to-end supported choices from an available capability.
A local encoder/adopter test alone does not make the cloud service available.

## Measured short-sample codec comparison

Existing full-quality generated PCM, three rotations per format, native
AVFoundation encoding plus actual decoded readback. No neural rerender.

| Language | Duration | ALAC24 bytes | AAC bytes | Reduction | ALAC median | AAC median |
|---|---:|---:|---:|---:|---:|---:|
| English | 13.32 s | 659,628 | 141,175 | 78.6% | .03661 s | .02725 s |
| Spanish | 16.48 s | 821,847 | 167,562 | 79.6% | .04242 s | .03021 s |

These are encoded-file size and encode/readback measurements, not measured
iCloud transfer times. Neural generation is unaffected by delivery format.
AAC listening approval and live cross-device delivery/playback remain pending.
The original lossless samples are retained.

Evidence: owned `runs/chatterbox-macos-pro-evaluation-v01/codec-comparison-v01`.
