# Chatterbox Pro narration and My Voices app handoff

## Status and source

Matt requested replacing Pro audio with this path, integrating Librox narration,
and adding a Settings recording flow. **No Libros app source/version/build was
changed in this chat.** This is experimental SDK implementation and audition
evidence, not an installed app or release cut. App adoption and physical flows
remain to be validated. No merge/upload/release is authorized by this handoff.

Implementation worktree:
`/Users/matt/.codex/worktrees/enhanced-voice-reuse/KokoroKit`

Branch: `codex/enhanced-voice-reuse`. Base HEAD at handoff:
`858ad8de4f6811f8a9b9c6a5bbecd47094a7789b`.
The new packages and shared extension are **uncommitted/untracked**; there is no
feature commit to cherry-pick. Use `APP-INTEGRATION-SOURCES.json` beside this
file for exact source hashes. Never copy this entire dirty worktree.

Integrate selectively:

- `Integrations/Chatterbox`: `LibroxChatterbox`, optional `LibroxChatterboxUI`,
  vendor runtime/licenses, Swift package lockfile and tests.
- `Integrations/ChatterboxMLX`: optional native mixed-precision engine, package
  lockfile, attribution and diagnostic CLI. The base package need not depend on MLX.
- `Sources/KokoroNarration/BookNarrationUnit+TextNative.swift`.
- Required shared narration dependencies are pinned in the source manifest.
  Several existing NarrationPerformance/DialogueTiming/Cadence files in this
  worktree are themselves uncommitted shared work. Reconcile with their owners
  and the current clean LibroxTTS revision; do not overwrite newer app/library work.

## App behavior

Use Chatterbox Multilingual V3 as the proposed Pro backend, with the reviewed
`mixedFloat16Accurate` native T3 renderer. Retain the Standard engine and existing
book/source-position, pronunciation, listening, audio-session, interruption,
route, seek, playback-speed and cache lifecycle contracts. Natural Chatterbox
text must not be replaced with Kokoro phonemes. Never label a fallback as this
voice/model. Preserve voice compatibility and cache identities on migration.

`ChatterboxMLXRenderer.makeNarrator()` supplies the shared narrator facade.
`ChatterboxBookDirector.plan` accepts persistent external voice IDs, retains
source ranges and uses Librox delivery evidence. `ChatterboxConversationSession`
adds only missing semantic seam silence. `ChatterboxLookaheadCache` prepares
current plus two upcoming completed units. Native direct rendering is currently
serial per complete unit; no native decode/acoustics overlap claim is made.
Cancel and await generation before seek, book/voice/account change or stop.
To release models, unload the narrator **and drop the retained renderer handle**.

Set `MLX_ENABLE_TF32=0` at the earliest app startup, before any MLX use; do not
toggle it after another model initializes. The native engine verifies exact
weight/fixture hashes and runs18 oracle comparisons at load. Task-scoped GPU
prediction leaves host global defaults intact. The host owns MLX memory budgets
and should unload other MLX engines before loading this one. Initial3GiB and
runtime headroom, Low Power Mode and thermal stops are intentional. Do not
weaken them to make a build appear successful. Unsupported GPU background/lock
behavior must be handled honestly through existing capability/cache/fallback
policy, not hidden CPU substitution or an unproven background promise.

## Settings → Narration → My Voices

Provide a saved-voice list with selected narrator, preview, rename, delete and
Create Your Voice. Use private per-account Application Support storage, stable
UUIDs and `ChatterboxVoiceStore`; keep voice files separate from model weights
and disposable PCM caches. A profile is reusable after restart with compatible
Multilingual V3 assets. Do not silently assign one profile to every character.
Use explicit reviewed cast-to-profile mappings when character voices are enabled.

`ChatterboxCreateVoiceSheet` and `ChatterboxVoiceRecorder` implement the native
recording flow: display the localized reading passage, explicit use-recording
choice, microphone permission, record/stop (20s maximum), signal checks,
conditioning, generated preview, name and Save Voice. Aim for10–15s. Save is
enabled after preview completion; the explicit Save action accepts the preview.
Add the new voice to the list and allow selecting it for narration.

Inject the host's recording/playback audio-session leases. The SDK does not
set AVAudioSession categories. Add microphone usage text in `Libros/project.yml`
and the macOS microphone entitlement where applicable; regenerate with XcodeGen,
never edit generated plists/project.pbxproj. The preview callback writes only the
supplied draft-owned output URL. UUID-scoped cancellation/discard removes the
temporary recording/preview; accepted storage retains derived conditioning,
not the full recording. Signal checks do not certify speech content or identity.
No cloud sync or public voice/reference export is included.

## Approved private Spanish profile and local model assets

Matt said the `spanish-one-shot` sample was “amazing.” This is listening acceptance
of that exact sample/voice, not approval of every later performance or app flow.

- Saved name: **Spanish Narrator 1**.
- Voice ID: `1B6F973A-D7BD-4B48-81B9-A85914BF63A6`.
- Store: `/Volumes/T9.2025/LibroxTraining/voices/chatterbox-multilingual-v3`.
- Conditioning SHA256: `cd3e1e3067617c5c875330f074d41ebd30e6390b2bd6b34fc587a552ed6136ed`.
- Size140047bytes, one authorized8.56s TRAIN reference, zero optimizer updates.
- Use as a private local test preset; do not bundle it as a public stock voice or
  expose reference/conditioning/corpus files. Vicky remains deleted/stopped.

Verified local model inputs:

- Native weights: `/Volumes/T9.2025/LibroxTraining/runs/chatterbox-v3-evaluation-v01/native-t3-backbone-f32-v01/backbone-f32.safetensors`.
- Oracle: same directory, `fixed-prefix-f32.safetensors`.
- Host tables/acoustic models: `/Volumes/T9.2025/LibroxTraining/models/chatterbox-v3-coreml-evaluation/multilingual`.
- Watermark model: `/Volumes/T9.2025/LibroxTraining/models/chatterbox-v3-coreml-evaluation/perth`.

Design an explicit checksum-verified model installation path shared by all voices.
Do not hardcode these development SSD paths in shipping app code or silently
download from YouTube. Native weights are a frozen272-parameter export of the
pinned MLX V3 source, not the entire upstream model file. Replacing this artifact
requires a separate version/review/oracle pass. Preserve source/model licenses.

## Evidence and remaining gates

- Isolated iPhone17ProMax diagnostic:36 predictions passed; warm EN/ES
  18.789/19.204ms per token, peak MLX1.277GB, nominal during the short cases.
  This is decoder-only; no full-phone real-time/battery guarantee.
- Mac Release optional SDK rendered saved voice + actual Librox director,
  semantic cadence and current-plus-two cache:23 units,70.21s finite audio.
  Preview: `/Users/matt/.codex/outputs/chatterbox-librox-directed-2026-10-28/spanish-librox-directed.wav`.
  Report: `/Volumes/T9.2025/LibroxTraining/runs/chatterbox-v3-evaluation-v01/librox-directed-narration-v01/render/report.json`.
- Approved earlier sample: `/Users/matt/.codex/outputs/chatterbox-expressive-2026-10-28/spanish-one-shot.wav`.
- Shared package49 tests passed with real-asset fixtures enabled, including
  persistence, corruption, cancellation, own-recording draft/save lifecycle,
  source/cast preservation and direct-renderer busy-lease lifetime.
- Create Voice UI compiled for macOS and arm64 iOS18. No physical microphone,
  accessibility, interruption/route or visual app acceptance is implied.
- Mac audition acoustics were explicitly CPU; failed full-GPU Mac CFM stays
  stopped. Choose and measure actual per-stage phone policy rather than assuming
  NPU residency from compute-unit configuration.

Read the current release coordination README/state, agree isolated app source,
build number and resource ownership with MAIN, integrate into the current clean
app revision, bump all four targets under1.9.x, build optimized, and validate the
complete experience on iPhone/iPad/Mac. Require device listening, route/background,
power/thermal and record/retry/delete/restore tests before declaring Pro replaced.
Only the release owner merges/distributes an explicitly approved finished cut.
