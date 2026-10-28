# Optional native Chatterbox narration

`LibroxChatterboxMLX` adds the phone-tested `mixedFloat16Accurate` decoder to the
existing `LibroxChatterbox` request, source/cast bridge and current-plus-two PCM
cache. The base/Core ML package does not acquire an MLX dependency. Requires
Swift 6.2 and MLX Swift 0.32.3; platforms are iOS18+/macOS15+.

The four backbone/cache files are preserved copies of the reviewed native probe
that passed36 fixed-prefix phone comparisons. See `Vendor-MLXAudio-LICENSE` and
the pinned revision/source hashes in the experiment receipts. No new weights
or retraining are introduced. FP16 covers dense projections/KV; norms,
residuals, speech head and sensitive activation/attention arithmetic stay FP32.

Set `MLX_ENABLE_TF32=0` **before any MLX operation in the host process**. Loading
checks exact weight/fixture hashes and runs all18 fixed-prefix oracle checks
under unchanged .05/.002/both-lane-top1 gates. Prediction operations use a
task-scoped GPU device, without changing a process-global default. The host owns
global MLX budgets and must serialize model loading with other MLX backends;
profile conversion releases unused pooled buffers. Resource checks include
initial3GiB headroom, Low Power Mode and serious/critical thermal stops. Mac
free+inactive-memory estimates and iOS process headroom are different evidence.

Create `ChatterboxMLXRenderer` with local verified assets, a saved default voice
and explicit acoustic compute policy. `makeNarrator()` returns the shared SDK
facade. The direct path awaits a complete bounded unit and holds its busy lease
until cancellation/renderer completion. It currently serializes complete units;
it does not claim native decode/acoustic overlap. Use `ChatterboxBookDirector`
and `ChatterboxConversationSession` for source-aware delivery and seam timing.
Named whisper/shout/mood labels remain unmapped model capabilities: the current
profile uses authored intensity/guidance heuristics, never fake acting tags,
pitch shifting or text rewriting.

Saved voices: `ChatterboxVoiceStore` keeps private UUID folders containing
conditioning plus metadata/checksum/model-family compatibility. Model weights
and prepared PCM stay elsewhere. The approved Spanish reference is about137KiB.
`ChatterboxVoiceCreation` snapshots a6–20s recording, checks signal quality,
prepares locally and saves only after the host's accepted preview action.
`LibroxChatterboxUI` provides the sheet/recorder. Its preview callback writes
only the supplied draft-owned output; the host injects recording/playback audio
session leases and adds NSMicrophoneUsageDescription plus the macOS microphone
entitlement where applicable. No installed-app microphone test is implied by a
library build. Use per-account Application Support roots, and unload the prior
engine when changing backend. Voice files contain private derived reference
features; host backup/export policy must preserve account ownership.

All work is experimental until app integration, physical recording routes,
whole-pipeline iPhone energy/thermal behavior and new listening comparisons are
validated. No release/merge/upload is performed by this package.
