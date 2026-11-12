# LibroxTTS 0.9 implementation

Authorized sequence: measurement/contracts; bounded preparation reuse; Max request
handling; broader planning; verified file installation; full-model cache experiment.
Base: 0.8 `e72a0cd`. Work is isolated on `codex/0.9-preparation-refactor`.

## Review and commit plan

1. **Measurement [Strong].** Existing preview-based benchmark excludes model load
   from its first generation. Add separate cold, preview-warmed, repeated, switched
   and backpressured cases without changing existing report fields. Capture PCM,
   events, first accepted frame, frame service percentiles and sampled footprint.
2. **Preparation ownership [Strong].** Share immutable English dictionary data
   only while owners remain alive; reuse actor-owned DSP setup with per-unit reset.
   Explore one verified voice prompt per loaded language, preserving current file
   validation/errors and exact tensor snapshots. Measure before adoption.
3. **Max requests [Strong].** Consolidate duplicated complete/streamed MLX execution
   and pure request preparation, retaining backend-specific validation precedence,
   resource retirement and RNG initialization. Keep public types in their modules.
4. **Broader planning [Worth exploring].** Extend the proven prefix domain and
   localize it to safe source spans, retaining full normalization for contextual
   text and exact first-failure split decisions. Differential-test against 0.8.
5. **Verified publication [Strong].** Share streaming hashes and download handling
   behind internal adapters. Stage replacement on the destination filesystem and
   atomically rename only verified files. Preserve public errors/progress order.
6. **Capacity cache [Experiment].** Run actual model inference with the candidate;
   check offsets, snapshots, trim/reset and exact seeded PCM before performance.
   A failed equivalence or inconclusive gain means production keeps concatenation.

Top recommendation: complete measurement and ownership changes first. Public type
moves, MLX-free iOS, altered acoustic models and altered RNG streams are excluded.
Qwen concurrency remains a separately scoped maintenance track, not a new model
selection or an excuse to alter existing streaming behavior.
