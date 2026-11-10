# Max assets by device — 2026-11-10

The SDK uses Core ML CPU for Max on iPhone/iPad, in every execution context,
and retains MLX on macOS and Mac Catalyst. There is no iPhone fallback that
loads or downloads the MLX acoustic checkpoint. The separate MLX library product
remains available for direct callers and benchmarks.

This is an execution-format conversion of the original Kyutai checkpoint, not
retraining, fine-tuning, a replacement voice or an Apple system speech model.
Caro Davy / Calm, temperature 0.3, four sampler steps, careful-reading chunking,
continuation, decoder warm-up and EOS behavior remain unchanged. Explicit
existing sampler selections 1–8 remain supported without lowering quality.

## Language, voice and style coverage

All seven language packs retain 23 original voices each (161 voice/language
combinations). Each language also has 13 delivery styles for four supported
narrators: Bill Boerst, Caro Davy, Peter Yearsley and Stuart Bell. These 364 style
states use the original safetensors files with either backend; they do not need
a second acoustic model or a new conversion. Other voices retain Original only.

The 203 original pack files and all 399 style-pack files (including credits)
were checked against GitHub release asset sizes and SHA-256 digests on November
10. No hosted files were missing or mismatched. Missing style files in the local
benchmark directory were simply not downloaded there. This is an availability
and integrity audit, not human listening qualification of every voice/style.
Only English Caro/Calm retains its existing non-preview acceptance; other style
preview status is unchanged.

See [asset-separation.json](asset-separation.json) for per-language conversion,
sampler checks and the hosted coverage receipt.

## Download and installation contract

- `PocketTTSBackend.platform` owns backend, repository and runtime identity.
- `NarrationAssets` and narrator/style manifests select the device's format.
- Core ML packs contain portable `.mlpackage` graphs, BOS and conversion metadata.
  They exclude `model.safetensors`. They are compiled on the destination device,
  not distributed as Mac-compiled `.mlmodelc` directories.
- The original configuration, tokenizer, voice states and attribution retain
  their pinned hashes and immutable URLs. Delivery-style states remain optional
  downloads, with the same default narrator bundle as before.
- Mac manifests and immutable MLX model URLs are unchanged.
- Core ML installations have a distinct repository/preparation identity, and
  prepared audio uses a distinct runtime identity. Old MLX receipts cannot be
  accepted as Core ML readiness.
- The former MLX installation is a verified reuse source for shared files.
  Migration copies matching files into separate staging; it does not delete the
  old model. The host may retire the old installation after successful adoption
  and after releasing its active renderer.
- Preparation validates all source hashes, compiles into private staging, then
  adopts completed graphs with a manifest/OS-bound receipt. Failed preparation
  cannot publish a successful receipt. Prepared graphs are verified on loading.
  An OS update requires preparation again.
- All iOS files receive background-readable protection after successful SDK
  preparation. Background execution still requires an active permitted task,
  such as the narration audio session demonstrated in the original benchmark.

A single backend is not necessarily a smaller file. The English base Core ML
pack is about **919 MB decimal**, including about 141 MB of shared voices and
metadata, versus about **360 MB** for the existing MLX pack. The current FP32
Core ML layout has separate transformer graphs; it is not a compressed export.
Optional Calm assets add the same bytes on either platform. Core ML compilation
also needs additional local storage. No size reduction is claimed.

The binary still links MLX for shared code, safetensors voice-state reading and
CPU seeded noise. It never needs the MLX acoustic checkpoint on iOS. Removing
the MLX code dependency is independent of downloading a second model.

## Validation

- Seven language conversions passed independent Kyutai comparisons, recursive
  transformer checks, seventy decoder frames and all eight sampler counts.
- A real Core ML-only installation, with no `model.safetensors`, compiled and
  rendered identical samples to the benchmark layout at 4, 8 and 3 steps.
- Catalog/routing, immutable shared assets, narrator manifests, verified reuse,
  malformed receipt rejection and tensor contracts passed (9 XCTest cases, including directory-alias and bounded-hashing regressions).
- The existing 45 Pocket tests passed, including Mac MLX lifecycle tests.
- Signed Release iPhone build/install succeeded. On the physical iPhone 17 Pro
  Max, the Core ML-only pack compiled and passed public SDK routing checks for
  foreground, background and backgroundGPU contexts, all using CPU. Each result
  was byte-identical to direct Core ML output (80,640 samples at temperature zero
  for deterministic comparison). The application stayed foreground during this
  routing check. [Device receipt](installation-device-2026-11-10.json).
- Physical testing exposed two installation issues, now corrected: iOS `/var`
  aliases produced invalid relative receipt paths, and Foundation file reads
  retained large temporary buffers during hashing. Canonical relative paths and
  per-block autorelease pools address these without relaxing hash validation or
  the memory guard. The failed comparison reached roughly 3.52 GB app footprint;
  corrected recorded checkpoints were about 59–140 MB across two complete runs.
  These figures exclude Core ML services and are not total model memory.

The earlier two-minute locked/background benchmark remains evidence for the
acoustic computation, not a new endurance qualification of this packaging
change. Battery life, longer sessions, human listening and previously observed
Mac Core ML allocation retention remain open. Mac production routing stays MLX.

## Reproduce and release boundary

Generate and independently validate each language with `convert.py` and
`validate.py`, then stage a fresh output directory:

```sh
python3 Scripts/PocketTTS/CoreML/package_assets.py \
  --assets "$ASSETS" --models .coreml-tools/models \
  --output .coreml-tools/phone-packs-v1
```

This writes the seven `coreml-*.json` graph manifests. Runtime catalogs combine
these with hash-identical shared assets. `PocketTTSCoreMLAssets.prepare` supports
explicit local Core ML installs on Mac for tests. The public `NarrationAssets`
preparation path selects this automatically on iOS.

The physical probe's `--run --request installation --installation` mode expects
`Assets/install/en`, containing the Core ML pack and the existing Calm state
plus credits. It copies to writable app storage, calls public SDK preparation,
then checks foreground/background/backgroundGPU *context routing* against direct
Core ML output. The app remains foreground for this routing test; it does not
claim a fresh background lifecycle test.

**Assets are staged locally, not published; the SDK/app is not released.**
`PocketTTSCoreMLCatalog.isDownloadPublished` deliberately remains false until
hosting is verified. No unavailable URLs are advertised as downloadable. The
immutable publication helper can use `--manifest-pattern 'coreml-*.json'`,
`--tag pocket-tts-coreml-2026-11-10-v1`, and this worktree's staged pack root.
After hosted digest verification, enable the publication flag and integrate the
SDK into the app. No release/tag/upload was performed as part of this change.
