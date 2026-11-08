# Max (Pocket TTS) in LibroxTTS

Max is an additional, explicitly selected narration tier above Plus, powered by
Pocket TTS (`NarrationModel.pocket`, persisted identity `pocketTTSV1`).
It uses the latest pinned Kyutai reference, ported to **native Swift MLX**, with
local 24 kHz mono PCM output. Python is used only for preparation and validation.
Basic and Plus retain their existing model IDs and voices.

The SDK registers model identity, downloads, language/voice selection, text-native
planning, spoken dictionary readings, source ranges, persistent character casts,
rendering and prepared-audio identities. It does not change Librox app defaults or
ship an app update. MLX is now a pinned package dependency; existing Basic/Plus
inference still uses their own renderers.

[Hosted language packs](https://github.com/Section9Labs/LibroxTTS/releases/tag/pocket-tts-mlx-2026-11-07-v2)
are published as an asset prerelease. Pin SDK `0.4.0-beta.5` separately;
the asset tag is not an SDK version tag. Beta.5 reuses the existing v2 packs.

## Voices and languages

| Language | Pack | Suggested starting voice |
| --- | --- | --- |
| English | `en` | Alba |
| French | `fr` | Estelle |
| German | `de` | Alba (cross-language; audition first) |
| Portuguese | `pt` | Alba (cross-language; audition first) |
| Italian | `it` | Giovanni |
| Spanish | `es` | Lola |
| Dutch | `nl` | Daan |

Each pack exposes 23 names (161 stable language/voice IDs). A language selects a
separate checkpoint/tokenizer; changing a voice does not turn an English model
into a multilingual model. IDs look like `pocket-alba-en-v1` and
`pocket-lola-es-v1`. Cross-language voice identity is available through the supplied
states, but accent and narration quality need listening review. Automatic speaker
attribution remains limited to the languages supported by Librox's attribution
layer. Twelve presets now carry verified VCTK gender metadata for automatic casting;
the remaining presets stay unknown rather than guessed from names. See
[voice metadata](VOICE-METADATA.md). Saved and manual assignments are preserved.

The unfiltered upstream catalog has 27 voices. We omit Cosette and Jean because
of their noncommercial recording licenses. Juergen and Rafael are also withheld because
their source-recording licenses are not documented. See the [per-voice license inventory](VOICE-LICENSES.md). Model weights are CC BY 4.0; code is
MIT. See [provenance and credits](PROVENANCE.md).

## Integration

```swift
import LibroxTTS

// Explicit optional foreground download. One language is about 360 MB;
// omitting language installs all seven (about 2.52 GB).
try await NarrationAssets.download(.pocket, to: modelDirectory, language: "es")

let plan = try await NarrationPipeline().plan(
    chapterText, model: .pocket, bookID: bookID, chapterID: chapterID,
    narratorVoiceID: "pocket-lola-es-v1", language: "es",
    characterVoices: true
)
// Persist plan.cast before playback and reuse it for subsequent chapters.
let renderer = NarrationRenderer(storageRoot: storageRoot, resources: .main)
try await renderer.load(.pocket, directory: modelDirectory, executionContext: .foreground)
for unit in plan.units {
    let samples = try await renderer.render(unit)
    // Commit samples at 24 kHz with unit.range to your bounded chapter cache.
}
await renderer.unload()
```

For background URLSession installers, use
`NarrationAssets.manifest(.pocket, language: "es")`, then
`NarrationAssets.prepare(directory, model: .pocket, language: "es")`.
Use the same language in `isPrepared`; the default checks all seven packs.
Keep per-language download receipts; do not mark the full model installed after
one pack. Switching language unloads the previous model and verifies the new pack.

`PocketTTSEngine.renderFrames` supplies 80 ms PCM frames through a synchronous,
throwing callback with backpressure. Both streaming and buffered entry points
accept temperature, sampler steps, continuation and chunking settings. Both bound
a unit to five minutes. Stage output until success; cancellation or
EOS-limit failure must discard incomplete units. `synthesize` buffers a bounded
unit (maximum five minutes), never a whole book. Source input is capped at 16,384
Unicode scalars; normal pipeline groups default to at most 2,400 scalars (configurable), then the
model's real language tokenizer chooses sentence-aware generation chunks.

The shared renderer uses CPU for `.background`, GPU for `.foreground`, and GPU
for `.backgroundGPU` only under a real iOS 26+ continued-processing GPU grant.
The iOS 18+ minimum remains. Use `NarrationBackgroundGPUGrant` to acquire the
system grant, wrap GPU work, and cancel/retire work when permission expires.
Older OS versions and unsupported/denied grants use CPU during legitimate audio
playback. Neither backend gives an unlimited background execution allowance.
Max no longer requires chapter preparation before listening. See the complete
[beta.5 host integration](../../docs/UPGRADE-0.4.0-beta.5.md).

Physical M4 iPad trials generated new English and Spanish PCM with both backends
while genuine narration played and the app was backgrounded. These short trials
do not qualify older iPhones, lock-screen transitions or whole-book thermals.

## Reading behavior

Kyutai's reference defaults to temperature **0.3** and one LSD sampler step.
Librox now defaults to **four sampler steps** for quality-first narration and
uses configurable **adaptive phrasing**, replacing its initial fixed 25-token
target. This is structural grouping, not an emotion classifier:

- A whole sentence stays together when it fits the hard cap, even above the target.
- Short setup/follow-on sentences and a small set of language-specific connective
  words can keep adjacent sentences together above the target.
- Narration and dialogue have separate soft targets: initially 48 and 32 tokens.
  These are engineering starting points, not listening-qualified voice presets.
- The hard cap defaults to 96 tokens, configurable up to 100. An oversized sentence
  splits at a clause, then at a whole-word boundary if needed. An indivisible word
  above the cap fails explicitly; it is never truncated or omitted.
- Paragraphs, speaker turns and narration/dialogue attribution spans are firm
  boundaries. They remain separate even when their assigned voices match. The
  model does not infer speakers itself; the existing attribution layer supplies
  those boundaries when character planning is enabled and supported.
- A short dialogue turn is allowed to remain short; it is never padded with another
  speaker's words to meet a target.

```swift
let chunking = PocketTTSChunkingOptions(
    narrationTargetTokens: 56, dialogueTargetTokens: 28,
    maximumTokens: 96, shortSentenceTokens: 12,
    maximumUnitScalars: 2400
)
// Pass pocketChunking: chunking to NarrationPipeline.plan(...).
// Units carry the selected policy through NarrationRenderer.

// A host/editor can protect an individual bounded speaker passage:
var protectedUnit = plan.units[0]
protectedUnit.pocketChunking = .init(grouping: .keepTogether)
// Throws if a protected passage exceeds the cap; never joins paragraphs/speakers.

// Inspect the exact text, token counts, boundary reasons and context resets:
let chunks = try await engine.previewChunks(
    protectedUnit.synthesisText, voiceID: protectedUnit.voiceID,
    chunking: protectedUnit.pocketChunking ?? .init(),
    role: protectedUnit.role == .dialogue ? .dialogue : .narration
)
```

The policy is Codable for book settings. Include `NarrationModel.pocket.renderIdentity(for: unit)`
in prepared-audio cache keys alongside the usual text/voice/model identities. It
includes the policy and resolved role; the runtime revision also changed so old
25-token audio is not reused. Direct synthesis and `renderFrames` accept the same
`chunking` and `role` arguments. Direct engine callers must supply separate speaker
turns; `role: .dialogue` alone does not perform speaker attribution.

Within a passage, previous text and generated latents condition the next chunk;
Mimi warms with the prior 12 latent frames. Continuation resets at a paragraph or
independently rendered unit. No hidden context from another character or previously
played chapter enters a render. Resetting is distinct from adding a timed pause;
this policy does not insert synthetic silence or emotion tags.

The latest punctuation preparation prevents unfinished clause endings, keeps
abbreviations/decimals together, preserves closing quotes with their sentence,
and removes characters absent from individual languages' training data. Rewrites
apply only to synthesis text; the displayed book and UTF-16 source ranges remain
unchanged. Spoken dictionary readings run before model tokenization. Kokoro IPA,
CT style tensors, acting instructions and SSML are not passed to this model.

EOS is ignored during the first six frames to prevent premature short-utterance
stops. A fresh decoder fades in over five milliseconds; continued chunks use the
warm decoder without repeating the fade. Native dynamics are retained: no global
pitch shift, compression or synthetic emotion processing is enabled. Arbitrary
voice blending and explicit emotion controls are not advertised.

For voice auditions, start with the language's default, then compare complete
paragraphs in a small set of alternate voices. Choose a narrator and stable cast
before preparing a book. Lower error on an ASR screen is evidence of content
retention, not proof of pleasant or expressive narration.

## Reproduction

See `Scripts/PocketTTS/`: `prepare_assets.py` prepares/checks pinned downloads,
`reference.py` generates CPU fixtures, `reference_matrix.py` compares all seven
languages, `audition.py` renders the native SDK, and `transcribe.py` screens words.
Use a separate Python environment with the pinned Kyutai checkout installed.

```sh
swift build -c release --product pocket-tts-probe
swift test --filter Pocket
swift run -c release pocket-tts-probe --download /path/to/packs en
swift run -c release pocket-tts-probe --plan /path/to/packs \
  pocket-alba-en-v1 'She waited. Nobody came.'
swift run -c release pocket-tts-probe /path/to/packs \
  pocket-alba-en-v1 /tmp/pocket.wav 'The library was quiet.'
```

Numerical tests are opt-in with `POCKET_ASSETS`, `POCKET_REFERENCE`, optional
`POCKET_LANGUAGE`, and `POCKET_METALLIB` (the built MLX `default.metallib` URL path
for the command-line test runner). The test runner needs an explicit metallib
path on this Xcode version; the normal executable locates its bundled library.
The fixture comparisons use identical latent inputs, isolating numerical parity
from independent sampling and accumulated autoregressive floating-point drift.

Validation reports are in [Validation](Validation/). They cover real native
M3 Ultra renders, seven-language CPU/MLX parity and an ASR content screen. These
are not perceptual acceptance, all-voice qualification, or device endurance tests.

## Listening comparisons

See [the listening suite](../../Scripts/PocketTTS/LISTENING.md) to generate the
English/Spanish narrator auditions and a local review page. It compares voice,
temperature, adaptive phrasing and sampler steps in separate rounds, then checks
repeat takes. The page supports ratings, shortlists, notes and configuration
exports. These are auditions; no winner or new app default is selected.

Direct `synthesize`, `renderFrames` and the shared renderer default to **four steps**.
`PocketTTSSamplingOptions` carries temperature and sampler count through planning,
rendering and cache identities. It is Codable for host book/profile persistence:

```swift
// Default quality-first policy:
let sampling = PocketTTSSamplingOptions() // temperature 0.3, samplerSteps 4
// Pass pocketSampling: sampling to NarrationPipeline.plan(...).
// After measuring the actual target device, a host may explicitly select:
let deviceFallback = PocketTTSSamplingOptions(samplerSteps: 2)
```

Eight steps are available for a higher-compute listening comparison. Two and one
are explicit performance fallbacks, not automatic device-name guesses. A render
error never retries at lower quality. Hosts should measure sustained generation
throughput, startup latency, memory and thermal behavior on the target device
before reducing the selected setting. Preparation can tolerate slower generation
than live playback; do not downgrade merely because a one-off timing is slower.

Include `NarrationModel.pocket.renderIdentity(for: unit)` in the prepared-audio
key: it includes resolved sampling options and the new quality-first runtime
revision. Stored one-step audio cannot masquerade as the new default. This is an
SDK policy, not a shipped Librox app change. An app may explicitly select eight
steps for its new Max profile without changing the SDK’s four-step default.
