# Pocket TTS in LibroxTTS

Pocket TTS is an additional, explicitly selected narration model (`.pocket`).
It uses the latest pinned Kyutai reference, ported to **native Swift MLX**, with
local 24 kHz mono PCM output. Python is used only for preparation and validation.
Basic and Plus retain their existing model IDs and voices.

The SDK registers model identity, downloads, language/voice selection, text-native
planning, spoken dictionary readings, source ranges, persistent character casts,
rendering and prepared-audio identities. It does not change Librox app defaults or
ship an app update. MLX is now a pinned package dependency; existing Basic/Plus
inference still uses their own renderers.

## Voices and languages

| Language | Pack | Suggested starting voice |
| --- | --- | --- |
| English | `en` | Alba |
| French | `fr` | Estelle |
| German | `de` | Juergen |
| Portuguese | `pt` | Rafael |
| Italian | `it` | Giovanni |
| Spanish | `es` | Lola |
| Dutch | `nl` | Daan |

Each pack exposes 25 names (175 stable language/voice IDs). A language selects a
separate checkpoint/tokenizer; changing a voice does not turn an English model
into a multilingual model. IDs look like `pocket-alba-en-v1` and
`pocket-lola-es-v1`. Cross-language voice identity is available through the supplied
states, but accent and narration quality need listening review. Automatic speaker
attribution remains limited to the languages supported by Librox's attribution
layer. Pocket voice genders are unspecified rather than guessed from names.

The unfiltered upstream catalog has 27 voices. We omit Cosette and Jean because
of their noncommercial recording licenses. Model weights are CC BY 4.0; code is
MIT. See [provenance and credits](PROVENANCE.md).

## Integration

```swift
import LibroxTTS

// Explicit optional foreground download. One language is about 372 MB;
// omitting language installs all seven (about 2.60 GB).
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
throwing callback with backpressure. Stage output until success; cancellation or
EOS-limit failure must discard incomplete units. `synthesize` buffers a bounded
unit (maximum five minutes), never a whole book. Source input is capped at 16,384
Unicode scalars; normal pipeline groups are at most 1,200 scalars, then the
model's tokenizer splits them into smaller chunks.

The shared renderer rejects `.background` for Pocket GPU generation. Eligibility
currently admits Apple silicon Macs; iPhone/iPad generation remains unqualified.
Prepared PCM can use the app's existing background playback path. macOS build or
short-sample success does not establish locked-screen GPU permission on a phone.

## Reading behavior

Current Kyutai defaults are temperature **0.3** and one LSD sampler step. The port
uses 25-token target chunks, feeding each prior chunk's text and generated latents
into the next chunk and warming Mimi with its last 12 latent frames. This retains
local delivery continuity while keeping state bounded. Continuation resets at a
Librox unit/voice/paragraph boundary, making independent rendering and retries
safe; no hidden context from a previously played chapter enters the cache key.

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
