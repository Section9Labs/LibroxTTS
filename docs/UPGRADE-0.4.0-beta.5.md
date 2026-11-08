# Upgrade to LibroxTTS 0.4.0-beta.5 — Max background narration

This supersedes beta.4's foreground-only Max instructions. Keep **iOS 18+**,
Catalyst 18+ and macOS 15+. Max stays an additional model above Plus; persisted
IDs remain `.pocket` / `pocketTTSV1`. Existing Plus selections are unchanged.
Pin exact `0.4.0-beta.5` in every package graph. This is an SDK prerelease, not an
app or TestFlight release.

## Host integration prompt

Integrate LibroxTTS 0.4.0-beta.5 into the existing Librox narration path. Preserve
concurrent app changes and existing saved profiles, casts, downloads and reading
positions. Complete the following wiring and test it in the real app:

1. Keep Basic, Plus and Max separate. Max has 23 retained preset voices in seven
   language packs. Reuse the hosted `pocket-tts-mlx-2026-11-07-v2` packs; no model
   redownload is required. Use `language:` consistently in manifest, download,
   prepare and isPrepared; track independent receipts. Offer individual language
   downloads rather than forcing all seven (~2.52 GB) when one (~360 MB) suffices.
2. Remove every Max-only foreground rejection, wait-for-activation loop and
   forced chapter-preparation gate in loading, `KokoroTTSEngine`,
   `NeuralSpeechReader`, previews and preparation. The SDK now reports
   `requiresPreparation == false` and `supportsBackgroundGeneration == true`.
   This does not remove the host's obligation to select a permitted backend.
3. During real background audio playback, use `.background` for CPU on iOS 18+
   unless an actual iOS 26+ GPU grant owns that render. Use `.foreground` only
   while active. On macOS, select foreground GPU for ordinary app execution;
   do not treat an unfocused Mac window as an iOS background restriction.
4. On iOS 26+, request `NarrationBackgroundGPUGrant` in response to a foreground
   Play/Prepare action. Check runtime support, but do not equate support or a
   successful submission with permission. The SDK waits for the launch handler.
   Keep the returned grant with the user-started listening/preparation job.
5. Add Background GPU Access to the app's explicit App ID and regenerate signing
   profiles; include `com.apple.developer.background-tasks.continued-processing.gpu`
   with value true in entitlements. Add a bundle-prefixed permitted wildcard,
   e.g. `com.section9labs.Libros.narration.*`, to
   `BGTaskSchedulerPermittedIdentifiers`. Use a fresh matching UUID identifier
   per request. Enable the Background Modes audio/processing capabilities.
   Check the signed app/profile, not just the source entitlement file.
6. The SDK rejects unowned `.backgroundGPU` loading and rendering on iOS. Its
   task-local authorization is revoked at operation completion or expiration.
   Wrap **both load and render** in `grant.withGPUWork` before choosing
   `.backgroundGPU`. For CPU, explicitly load `.background` before each retry
   or new unit; a prior GPU renderer must never remain selected after expiration.
   See the example below. GPU fallback preserves voice, text, sampling and
   chunking. It discards partial output and retries only the unfinished unit.
7. On loss of foreground without a valid grant, cancel and await in-flight GPU
   work before loading CPU. With a valid grant, do not cancel solely because the
   scene becomes inactive. Expiration cancels the work through the SDK; await its
   retirement before CPU retry. Cancellation checks occur between model frames;
   already-submitted GPU work must drain. Finish the grant on every exit path.
8. Pause, seek, chapter/book/account switch, and playback cancellation must cancel
   the owning task and await it. Never catch `CancellationError` as an instruction
   to restart playback. A user-cancelled standalone Prepare task stops; do not
   recreate it or continue CPU preparation after its Live Activity is cancelled.
   For an ongoing audio session, retry CPU only while the user still wants playback.
9. Update the continued task's progress with completed units and a useful title /
   subtitle. Await `finish(success:)` when complete or cancelled. This API is for
   bounded user-started work, not a permanent GPU entitlement. If a chapter's task
   finishes while the app is backgrounded, subsequent work uses CPU unless an
   already-valid grant still owns it; do not repeatedly request from background.
10. Keep a genuine spoken-audio buffer and the existing background playback/audio
    session, remote commands, reading position and interruption handling. No
    silent-audio keepalive. CPU alone does not provide unlimited runtime. If
    no legal execution time or buffer remains, preserve position and expose
    buffering/resume; never submit unauthorized GPU work.
11. Start the new Max profile at temperature 0.3 and eight sampler steps. Keep
    temperature, sampler steps, narration/dialogue token targets, hard cap,
    grouping and continuation semantics consistent across audition, preparation,
    live playback and exported/cached audio. The SDK's compatibility default
    remains four steps; explicitly set eight for the app's quality-first profile.
12. For automatic live playback, use `PocketTTSRealtimeBudget` (below) to lower
    effective steps only after measured throughput threatens the buffer. Show
    the effective quality when it differs from the saved profile. Preserve a
    fixed-quality option that buffers/prepares at the selected steps. Do not
    lower temperature, change voice or split speakers to save computation.
13. Store `unit.pocketSampling` and `unit.pocketChunking` before computing
    `model.renderIdentity(for: unit)`. Cache the settings actually rendered.
    Never store four-step fallback audio under an eight-step key. Use model
    sample rate (Max: 24 kHz mono), source ranges, dictionary readings, shared
    speaker planning and existing playback cadence; apply pauses only once.
14. Keep a separate Max cast namespace. Expand its voice catalog through
    `NarrationModel.pocket.expandingVoiceCatalog(in:)` so verified VCTK gender
    metadata is available for new automatic assignments. Preserve all existing
    and manual assignments. Twelve of the 23 presets have verified metadata;
    unknown voices remain selectable manually. Attribution-language coverage
    still depends on Librox's attribution layer.
15. Preserve advanced narrator controls, saved profiles and audition comparisons.
    Do not attach Kokoro phonemization/dialect/expressive DSP, Plus/DK expression
    tensors or voice blends to Pocket. This port does not expose voice cloning,
    SSML or emotion prompts. Expressiveness comes from voice choice, source
    punctuation, sentence grouping, continued context and sampling—not an
    unsupported “emotion” slider.
16. Settings notice: “Max uses Pocket TTS by Kyutai. Model and voice credits.”
    Link to acknowledgements using `KokoroAttribution.text` and installed
    `VOICE-CREDITS.json`. Code is MIT/upstream or Apache-2.0 OR MIT/port; model
    weights are CC BY 4.0, retained recordings CC BY 4.0 or CC0. Preserve complete
    notices. Do not label all model and voice assets MIT.

## Rendering with a grant

Guard all grant storage and calls with iOS 26 availability; on iOS 18–25 call the
CPU branch directly. The operation belongs to the host's serial narration job:

```swift
// iOS 26+, foreground user action. Request may return nil.
let grant = try await NarrationBackgroundGPUGrant.request(
    identifier: bundleID + ".narration." + UUID().uuidString,
    title: "Preparing narration", subtitle: chapterTitle,
    totalUnitCount: Int64(plan.units.count)
)

// Inside the playback/preparation job. An expired grant may never leave the
// renderer on its previous GPU backend. CPU retry is allowed only for an
// independently ongoing playback session, not cancelled standalone preparation.
func backgroundRender(_ unit: BookNarrationUnit) async throws -> [Float] {
    try Task.checkCancellation()
    if let grant, grant.isValid {
        do {
            return try await grant.withGPUWork {
                try await renderer.load(.pocket, directory: directory,
                                        executionContext: .backgroundGPU)
                return try await renderer.render(unit)
            }
        } catch NarrationBackgroundGPUGrant.GrantError.expired {
            try Task.checkCancellation()
            // Host must confirm playback is still requested here.
        }
    }
    try Task.checkCancellation()
    try await renderer.load(.pocket, directory: directory,
                            executionContext: .background)
    return try await renderer.render(unit)
}
// In the host's success/error cleanup, after awaiting the operation:
await grant?.finish(success: completed)
```

Use the isolated [device probe](../Examples/MaxDeviceProbe/Sources/BackgroundRun.swift)
for a complete runnable example. Its audio buffer and paths are test fixtures;
production must use the real reader's ownership, cache and cancellation rules.

## Quality under CPU pressure

The M4 iPad CPU trials were slower than real time, including a one-step long
passage. An unpaced sustained run was killed by the iOS CPU watchdog; the SDK
now paces iOS CPU execution against process CPU time at frame boundaries, aiming
for 50% of one CPU to leave headroom. This is a conservative execution budget,
not a guarantee of runtime or throughput on every device. The paced one-step
M4 iPad run generated 73 seconds of audio in 214 seconds while backgrounded.
Prepare enough audio
ahead while foreground/GPU execution is available. Keep eight steps
when the buffer permits, and prefer GPU when granted. Optional policy example:

```swift
var budget = try PocketTTSRealtimeBudget(requested: savedSampling)
// Before render and cache lookup:
unit.pocketSampling = budget.effective
let identity = NarrationModel.pocket.renderIdentity(for: unit)
// After successful, uncached render; durations are audio seconds:
budget.record(renderSeconds: elapsed, audioSeconds: duration,
              bufferedAudioSeconds: buffered, playbackRate: userPlaybackRate,
              renderedWith: unit.pocketSampling!)
```

Two measured slow units and less than 30 seconds of playable buffer are required
before stepping down 8→4→2→1 (never above the requested setting). Temperature is
preserved. Reset on backend, voice, language or playback-rate changes; reset
restores requested quality. Cached hits, cancelled/failed renders and other
profiles are not throughput samples. One step is the floor, not a guarantee of
real time; continue buffering or prepare offline when necessary. This policy is
opt-in and does not silently alter prepared/offline output or saved preferences.

## What the SDK fixes

- True CPU MLX execution for Max, including a CPU LayerNorm implementation that
  avoids an MLX 0.32.3 fallback operation accidentally targeting GPU.
- Per-engine random state and explicit backend retirement, avoiding CPU renders
  retaining GPU graphs across transitions.
- iOS CPU work pacing at frame boundaries to respect background CPU limits;
  this can require substantial prepared-audio buffering.
- Allocator cache trimming between renders/languages and unloading; no model
  weight or precision downgrade.
- Granted background GPU execution with expiration/cancellation ownership.
- Automatic casting metadata and measured-quality policy described above.

Existing v2 weights, IDs and compatible prepared audio remain reusable. Backend
changes preserve the model equations and requested settings, but floating-point
execution and stochastic draws need not produce bit-identical CPU/GPU waveforms.

## Validation boundary

See the [physical device evidence](../Examples/MaxDeviceProbe/Evidence/background-ipad-m4-2026-11-07/README.md).
The SDK is not the production app. App integration must still verify Play → Home,
lock/unlock, grant denial/expiration, foreground return, pause/seek/resume,
interruption/headphones, memory pressure, long chapters, download recovery,
credits and settings on iPhone and iPad. Test an actual iOS 18–25 device for the
legacy-OS path; forcing CPU on a newer iPad establishes CPU execution, not older
OS device qualification. No iPhone was available in this session.

Apple references: [Background GPU entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.gpu)
and [continued processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados).
