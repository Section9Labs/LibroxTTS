# Librox Plus Core ML v2 — SDK 0.2.0

Core ML v2 is the official CT F1 implementation. All five graphs execute through
Core ML FP32; there is no ONNX Runtime or MLX dependency. The earlier hybrid v1
remains a separate historical experiment and is not selected by this release.
Existing Kokoro APIs and default rendering behavior remain available.

## Download contract

- SDK: `Section9Labs/LibroxTTS`, tag `v0.2.0`.
- Model release: `plus-coreml-v2-2026-11-06` in the same public GitHub repository.
- Model identity: `librox-plus-ct-f1-coremlgpu-v2`.
- Model payload: 23 files, 439,248,281 bytes. Compiler caches require additional disk space.
- Voices: `plus-f1-en-v1`, `plus-f1-es-v1`; one upstream F1 preset.
- Output: mono Float32 at 24 kHz, native 44.1 kHz, ten inference steps.
- Platform floor: iOS/Catalyst 18, macOS 15, Swift 6.

The model files are GitHub Release assets, not Git/LFS blobs. Anyone can download
them over HTTPS without a GitHub account or a credential in the app. Each URL
contains a fixed release tag; consumers must not use `latest` for model assets.
The SDK pins every installed file's size and SHA-256. Hash changes require a new
release and SDK manifest; do not replace assets in this published model release.

`NarrationAssets.manifest(.plus)` supplies all download URLs, sizes and hashes.
`NarrationAssets.repositoryID(.plus)` supplies a stable, version-specific local
storage identity. The release's `download-manifest.json` exposes the same contract;
the trusted pins are bundled in the SDK, not loaded from that remote manifest.

For simple foreground installation, call `NarrationAssets.download(.plus,to:)`.
It resumes completed verified files, downloads to temporary files, checks HTTP
status and hashes before placement, and repairs same-size corruption on retry.
It then compiles models into an OS/source-specific persistent cache without
keeping inference weights loaded. It sets backup exclusion and post-first-unlock
file protection. The caller must serialize installation into a directory and
must not replace files used by an active renderer.

For the Librox app's background URLSession, use the manifest to stage files,
then call `NarrationAssets.prepare(staging,model:.plus)` off the main actor.
Only after validation/preparation succeeds should the app atomically install
the directory and write its receipt. A failed installation remains retryable;
never label it installed based solely on file sizes. `isPrepared` is only a fast
presence check, not a cryptographic validation step.

The app should remove the old bundled `CTCoreMLV2GPUAssets` build resource and
the local SDK path when adopting the remote package. Old v1 caches/receipts must
not be reinterpreted as v2. Voice selection may persist, but model and audio cache
keys must include the new manifest/delivery identities.

## Reader integration

Use `TextNativeNarrationPlanner` to split prose into bounded passages with
preserved UTF-16 source offsets. Supported language scope is English and Spanish,
not all upstream languages or arbitrary Unicode. Inputs that cannot fit model
bounds fail explicitly rather than truncating the book.

`NarrationRenderer` serializes render/load/unload and cancellation retirement.
Select `.foreground` for GPU generator/vocoder execution; text and duration
graphs remain on CPU. Select `.background` before subsequent background
inference. CPU/GPU transitions retain the text models and retire heavy models
before replacement. CPU policy does not authorize background execution, and the
host must coordinate scene transitions with in-flight GPU work.

The reader's separate v2 implementation prepares ~20 seconds of opening/resume
PCM, plays cached PCM while models load, bounds lookahead and disk use, and
unloads after preparation or a long pause. **That reader/cache code belongs to
the app, not this SDK release.** Its audible startup and lock-screen behavior
still need full-app device acceptance before the app release.

The SDK device policy exposes Plus for the measured iPhone 17 Pro Max
(`iPhone18,2`, 12 GB) and iPad Pro M4 (`iPad16,3`, 8 GB) configurations only.
Native Mac inference is numerically tested; the host policy does not automatically
enable Plus on every Mac or other iPhone/iPad. Expanding device eligibility needs
real-app memory and lifecycle evidence.

## Evidence and remaining acceptance

All 431 exact latent lengths pass generator reference checks on Mac, rotating
text lengths 8–512 with masked tails. The shared-weight generator contains
15 tiny fixed functions and four enumerated-length functions. Only the selected
function is kept loaded. No speech-latent padding or FP16 quantization is used.

Physical-device probe 0.1 (6), 6 November 2026, five warm repeats per fixture:

| Metric | iPhone 17 Pro Max | iPad Pro M4 |
| --- | ---: | ---: |
| English, 12.40 s of speech | 0.566 s | 0.409 s |
| Spanish, 13.93 s of speech | 0.645 s | 0.468 s |
| Cached model load, before lazy generator load | 0.483 s | 0.486 s |
| First uncached load + traced synthesis | 12.708 s | 11.550 s |
| Maximum sampled varied-passage physical footprint | 1.901 GB | 2.005 GB |
| Physical footprint after varied-passage unload | 0.647 GB | 0.829 GB |

The iPhone warm result is ~3× faster than the earlier full-CPU implementation.
Each device completed 21 varied-passage renders with explicit GPU → CPU → GPU
transitions. Both devices produced identical saved-noise fixture PCM, with
English/Spanish waveform SNR 60.774/70.993 dB against the frozen ONNX references.
Those are numerical gates, not a perceptual-equivalence claim.

First use of another function can still incur seconds of specialization. Initial
setup is not eliminated by allowing GPU execution. No measured Play-to-audio
claim, sustained thermal/energy claim, or lock-screen playback claim is made.
The distribution adds only descriptive license metadata to the measured models;
the packaging script asserts unchanged graph protobufs and weight bytes.

## License and reproducibility

The model is a modified derivative of Supertone Supertonic 3. The frozen source
revision is `supertone-oss-archive/supertonic-3@aafc6e32416a594460b32413efc49d7fe4ce6d46`;
the upstream project is <https://huggingface.co/Supertone/supertonic-3>.
CT uses its edited early encoder for steps 0–2, original encoder for 3–9, and CT
generator adaptation. The Core ML conversion changes no learned weights from
the frozen CT reference. Model packages carry modification notices; the payload
includes exact source graph hashes in `provenance.json`.

The full BigScience Open RAIL-M license, including use restrictions, accompanies
the model. Downstream apps must pass it on and require users to comply. Original
SDK code remains Apache-2.0 OR MIT; the Supertone helper adaptation remains MIT.
`CTAttribution.text` and the combined `KokoroAttribution.text` expose the notices
and complete model license for app acknowledgements.

Conversion and packaging tools are under `Scripts/CT`. `package_distribution.py`
verifies the frozen source before creating a new distribution. To exercise a
published download, same-size corruption repair, local compilation and real
English/Spanish GPU inference:

```sh
swift run -c release ct-install-probe /absolute/path/to/new-directory
```
