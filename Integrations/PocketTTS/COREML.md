# Experimental Max Core ML backend

This isolated backend is based on SDK commit `cd969c6` (Max 0.4.0). The SDK now
selects Core ML CPU on iPhone/iPad and MLX on macOS/Mac Catalyst. Saved book
quality and delivery settings are unchanged. The platform integration is distributed in SDK 0.6.0; it does not release
the Librox app. See [asset separation](Validation/CoreML/ASSET-SEPARATION.md)
for manifests, preparation, migration and release status.

The source weights remain Kyutai snapshot
`a7056f505a4a8ca72d8b5fb1440071d6f1a35739`. The exporter verifies the SDK's
SHA-256 manifest before loading them. English and Spanish packs were converted
locally initially; all seven packs now pass numerical conversion checks.
Model binaries and audio are excluded from Git.

## Preserved behavior

- Original tensor values, float32 compute, tanh GELU, tokenizer and voice KV states.
  The original BF16 storage is expanded to FP32, as in the existing MLX runtime;
  no new quantization or fine-tuning is applied.
- Caro Davy / Calm, temperature 0.3, four sampler steps, careful-reading phrasing
  for the English acceptance profile. All existing sampler counts 1–8 remain supported; four/eight use the
  benchmarked fused graphs and other counts use the same Euler update graph.
  Unsupported values fail without a lower-quality retry.
- The shared token-aware chunker and text preparation; paragraph resets;
  previous-chunk text and latent teacher forcing; twelve-frame Mimi warm-up;
  minimum six generated frames before EOS; configured tail and first-frame fade.
- Cancellation and bounded input/output. An unfinished EOS throws rather than
  returning truncated narration as success. Experimental assets are separately
  identified and must not share prepared-audio cache identities with MLX.

The Core ML transformer uses a growing cache, without truncation or circular
wrapping. An explicit position input avoids a shape-derived position problem
detected by recursive validation. The Mimi decoder uses its original sliding
attention context with a 512-position ring and float32 streaming state.

All neural inference in the iOS Max path is Core ML. The package still depends on `PocketTTSMLX`
for the shared tokenizer/configuration/chunker/resource checks and uses MLX **on CPU only** to
read existing safetensors voice states and generate the same seeded noise.
It does not initialize an MLX acoustic model. Removing that packaging dependency
would be separate work; this is not an MLX-free binary.

## Reproduce

From this worktree, with the existing verified Max assets in `ASSETS`:

```sh
uv venv .coreml-tools/venv --python 3.12
uv pip install --python .coreml-tools/venv/bin/python -r Scripts/PocketTTS/CoreML/requirements.txt
.coreml-tools/venv/bin/python Scripts/PocketTTS/CoreML/convert.py --assets "$ASSETS" --output .coreml-tools/models --language en
.coreml-tools/venv/bin/python Scripts/PocketTTS/CoreML/validate.py --assets "$ASSETS" --models .coreml-tools/models --language en
POCKET_ASSETS="$ASSETS" POCKET_COREML="$PWD/.coreml-tools/models" swift test -c release --filter ContractTests
./script/build_and_run.sh REQUEST.json "$ASSETS" .coreml-tools/models OUTPUT
```

Example request:

```json
{
  "backend": "coreml-cpu",
  "language": "en",
  "repetitions": 3,
  "steps": 4,
  "temperature": 0.3,
  "seed": 42,
  "text": "She rested her hand against the door. For a moment, she could almost hear his voice again.",
  "voiceID": "pocket-caro_davy-en-v1",
  "style": "calm"
}
```

Backends: `mlx` (GPU), `mlx-cpu`, `coreml` (CPU/GPU allowed), `coreml-cpu`,
`coreml-ane` (CPU/Neural Engine allowed), `coreml-all`. Mimi is always CPU/fp32.
Selecting a compute-unit set does not establish actual Neural Engine residency.
The current float32 dynamic transformer is a quality-preserving baseline, not
an ANE-optimized implementation.

The benchmark saves a first-generation measurement plus the requested warmed
repetitions, natural first-audio latency, physical-footprint samples and thermal
state. Loading is timed separately. First-generation timing may benefit from
Core ML's persistent compilation cache; it is not a fresh-device cold install.
RTFx is generated audio seconds divided by elapsed render seconds; above 1 is
faster than playback. Frame-period memory snapshots are not instrumented peak
allocations, and thermal state is not an energy measurement.

## iPhone and background harness

`Examples/MaxCoreMLProbe` has a separate bundle ID and does not touch Librox data.
Stage original verified packs under `Assets/original`, compiled packs under
`Assets/coreml`, requests under `Assets/requests`, and a real narration WAV as
`Assets/prebuffer.wav`. Generate with XcodeGen and build Release for the device.
Launch with `--run --request NAME`.

Add `--background` only with an explicitly GPU-free backend (`coreml-cpu`,
`coreml-ane`, or `mlx-cpu`). It plays genuine narration through an audio session,
waits for the app to enter the background, then synthesizes and queues completed
audio. Before/after files record application state and playback progress.
Use a 19-repetition request for twenty consecutive passages. Reports and WAVs
are in the app's Documents directory.

Core ML does not grant background execution time. This test exercises active
audio playback; it does not qualify unlimited silent background book preparation,
system-scheduled BGProcessing tasks, or background GPU grants. Those require
their own lifecycle and resource policy. Production integration must cancel or
retire GPU-capable models when their execution authorization ends.

## Acceptance boundaries

Numerical checks compare against unmodified Kyutai and against the existing
Swift MLX backend, including recursive caches and decoder rollover. Complete
passages also receive fixed-seed PCM comparison and an ASR content screen.
These are not human listening acceptance or a claim of identical samples across
different floating-point backends. No quantization or reduced sampler setting
is used to obtain the reported speed.
