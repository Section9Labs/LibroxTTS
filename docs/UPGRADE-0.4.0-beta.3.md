# Upgrade to LibroxTTS 0.4.0-beta.3

Pin exact `0.4.0-beta.3` in every SwiftPM graph. This SDK beta adds Pocket TTS as
`.pocket` (`pocketTTSV1`); existing Basic/Plus IDs and stored choices are preserved.
Swift 6.3 or newer is now required by the pinned MLX Swift 0.32.3 dependency.
`LibroxTTS` links MLX; the catalog, pronunciation and planning products remain
independent of the MLX runtime. Minimum deployment targets remain iOS/Catalyst 18
and macOS 15. Update exhaustive switches over `NarrationModel`.

## Install and render

Use the [Pocket integration guide](../Integrations/PocketTTS/README.md). Seven
optional language packs are hosted with pinned SHA-256 manifests, approximately
360 MB each or 2.52 GB together. This version selects the v2 packs, with **23
voices** and structured recording credits. Read the [voice license inventory](../Integrations/PocketTTS/VOICE-LICENSES.md):
MIT code, CC BY 4.0 model weights, separate CC BY 4.0/CC0 recording sources.

The native runtime is currently eligible on Apple silicon Macs only. iPhone/iPad
compilation is verified; physical-device narration qualification is pending.
GPU generation requires the foreground. Prepare PCM before background playback,
preserve source ranges and persist character casts before consuming a plan.
No App Store or TestFlight app release is included in this SDK publication.

## Advanced narrator controls

The SDK provides Codable sampling and phrasing settings for an app to persist
under the selected model, language and voice. Apply the same settings to preview,
foreground preparation and playback planning. Direct `synthesize` and `renderFrames`
also accept matching temperature, sampler-step and continuation controls:

```swift
let sampling = PocketTTSSamplingOptions(temperature: 0.3, samplerSteps: 8)
let phrasing = PocketTTSChunkingOptions(
    narrationTargetTokens: 64, dialogueTargetTokens: 40, maximumTokens: 96)
let plan = try await NarrationPipeline().plan(
    chapterText, model: .pocket, bookID: bookID, chapterID: chapterID,
    narratorVoiceID: "pocket-alba-en-v1", language: "en",
    pocketChunking: phrasing, pocketSampling: sampling)
```

Defaults are temperature 0.3, four sampler steps, narration target 48 and dialogue
target 32. Eight steps is available for higher-compute auditions; one/two steps
are explicit device fallbacks. No automatic downgrade is performed. More compute
or a higher temperature is not a guarantee of better narration.

An app's Advanced panel should offer a short preview before applying a saved
configuration, reset to defaults, and a clear account of what each control does:

- **Variation (temperature):** audition 0.15 / 0.3 / 0.45. Higher values vary the
  sampled delivery; this is not a calibrated emotion/intensity slider.
- **Sampler steps:** expose four/eight for quality comparisons. Steps are model
  refinement iterations, not the output sample rate or a number of candidate takes.
- **Phrasing:** short/balanced/flow targets guide grouping, while whole sentences,
  paragraph boundaries and speaker changes remain significant. `keepTogether`
  protects a caller-supplied passage and throws if it exceeds the token cap.
- **Character voices:** use the existing persistent cast rather than changing a
  narrator's voice at arbitrary sentence boundaries.

Keep drafts separate from committed preferences so canceling an audition does
not change a book's narrator. Include `NarrationModel.renderIdentity(for:)` in
cache keys: sampling, chunking and passage role affect the rendered output.
Changing these controls requires regenerating affected cached audio.

Text/audio continuation within a passage already improves continuity. Emotional
tags, prompt-based acting instructions, voice blending, arbitrary cloning and
cross-speaker acoustic carryover are not supported here. Future expression work
should compare connected narrative passages and deliberate dialogue boundaries
using the [listening suite](../Integrations/PocketTTS/LISTENING.md), preserving
the exact book text and checking pronunciation/repetition as well as expression.
