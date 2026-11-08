# Max resource recovery candidate

Base: LibroxTTS beta.5, `8e4645bf4d6000b48d92803b430127b2e7e3580d`.
Candidate checkout: `/Users/matt/Code/swift/librox-tts-max-resource`, branch
`codex/max-resource-recovery`. This records the beta.6 SDK resource-recovery work. Publication is recorded in the release receipt.
The app upgrade is coordinated separately with the app and release owners. The parallel app seek/default-policy
worktree was inspected read-only and has not been edited.

## Changes

- Reset Mimi decoder state on every chunk/render exit, including cancellation and
  callback failure. Reset residual `StreamingAdd` held audio as part of decoder
  reset; it was previously omitted.
- Consume, convert and release checkpoint tensors individually rather than
  overlapping all BF16 sources and FP32 destinations. Evaluate prefill in
  bounded transformer-layer groups, with cancellation between layers. Preserve the
  existing single-frame sampler scheduling: per-step synchronous barriers were
  measured and rejected because of their rendering cost. Observe cancellation
  before submitting subsequent codec work. Requested temperature, step count,
  voice, chunking and FP32 weights are preserved.
- Drain the selected default stream and retire model/RNG state on failure before
  returning. Parent cancellation remains `CancellationError`.
- Check current available process memory before load and at frame boundaries on
  iOS. Estimate FP32 residency at twice the BF16 model file size, with 128 MiB
  reserve for tensor conversion and runtime allocations. Reject critical thermal state. These are
  conservative, uncalibrated admission margins, not an iPhone qualification or
  a hard cap on allocations inside an individual operation.
- Recycle allocator cache above 256 MiB at checkpoints without changing shared
  process-wide MLX allocator limits. Active tensors and process footprint remain
  separate from cache memory. Reclaim cached allocations before a low-headroom
  rejection. Full Mach diagnostics are collected only when an observer exists. Existing input/frame/300-second returned-PCM bounds
  remain; this does not introduce an incremental host playback API.
- Normalize resource errors to existing facade `.memory`/`.thermal` errors.
- Add `NarrationRenderer.setMaxResourceObserver` and engine observer. Synchronous
  callbacks contain phase, monotonic time, backend, steps, tokens/frame index,
  process footprint/available memory, MLX active/cache/peak and thermal state.
  No source text, book IDs or voice names. Observers must remain cheap and must
  not block awaiting the same renderer. Tokens/frame index are omitted outside
  active chunk generation. MLX peaks are process-wide, not per operation.

## Validation and boundaries

Release-mode real-assets tests exercise cancellation during weight load,
conditioning, prefill, flow and codec boundaries, then unrelated text on the SAME
engine; residual-state reset, callback failure, typed admission and cancellation
precedence. Broader Pocket tests include CPU/GPU transitions and existing catalog,
settings and planning contracts. Logs and final counts are in the evidence receipt.

An early isolated Mac GPU run of eight passages at 1/2/4/8/8/4/2/1 steps kept completed
active MLX allocations at 398,901,940 bytes. Process-wide MLX peak was 598,357,076
bytes. Process footprint at completion ranged from 1,155,204,800 to 1,319,945,920
bytes; it was not flat. This is a short candidate-only Mac run, not a baseline
comparison, iPhone measurement, long-run bound or listening-quality acceptance.

Still required:

1. Affected iPhone 17 Pro Max reproduction with exact iOS/build, memory warning or
   jetsam evidence if applicable, and seek actor/task timeline. The device was
   unavailable via CoreDevice during this work; no app was installed on it.
2. Long iPhone narration, background GPU grant expiration/denial, CPU fallback,
   rapid seeking, and cancellation during actual executing kernels. Checkpoint
   injection tests do not establish maximum kernel retirement latency.
3. Hardware-calibrated initial sampling/resource profile through the facade. No
   new initial-step recommendation is claimed from the Mac measurements; the
   app owner's temporary policy remains separate. Fewer steps do not guarantee
   lower peak memory or sufficient CPU throughput.
4. Host buffer/streaming changes if measurements show returned units or scheduled
   PCM contribute materially. The existing 300-second Float array bound alone
   allows about 27.5 MiB, excluding allocator/decoder/model and host copies.
5. SDK publication/new exact pin, app integration and
   physical/listening acceptance before marking the reported issue resolved.

## Final allocator investigation

Active MLX peak alone hid the dominant retention: beta.5 cached approximately
3.1 GB of freed allocator blocks during the continued-passage matrix on M3 Ultra,
with sampled frame-boundary process footprint reaching 4.6 GB. The final 256 MiB
cache recycling threshold retained substantially less memory while avoiding the
extra overhead measured at 32/128 MiB. This is a soft checkpoint threshold, not
an allocator hard limit; a frame can temporarily exceed it. Exact figures,
throughput differences and byte-equality checks are recorded in the validation
JSON. Do not translate Mac process footprint into an iPhone memory guarantee.
