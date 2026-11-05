# LibroxTTS

Offline speech synthesis and book narration for iPhone, iPad and Mac. The Kokoro renderer provides **54 voices across eight languages**, with shared pronunciation, narration planning and voice cleanup. Basic and Enhanced use the same pronunciation corrections. The Kokoro path requires no Python, MLX or eSpeak runtime.

[![Swift](https://github.com/Section9Labs/LibroxTTS/actions/workflows/swift.yml/badge.svg)](https://github.com/Section9Labs/LibroxTTS/actions/workflows/swift.yml)

The development branch also includes the native [Librox Companion menu bar app](Apps/LibroxCompanion/README.md), its Chatterbox Multilingual Mac worker, and the concrete private-iCloud reader service. See the [iOS integration handoff](docs/LIBROX-IOS-INTEGRATION-PROMPT.md) for connecting the phone app.

## Install

The repository is now `https://github.com/Section9Labs/LibroxTTS`. The module rename and narration improvements are currently unreleased. To test this checkout, add it as a local package in Xcode, or use:

```swift
.package(path: "../LibroxTTS")
```

Core products: `LibroxTTS` (synthesis), `KokoroCatalog` (voices/assets), and `KokoroPronunciation` (text to model phonemes). Swift 6 is required. This development package targets **iOS/Catalyst 18+ and macOS 15+** and resolves additional dependencies for its optional Chatterbox integrations and companion app. Apple system language facilities are required, so Linux is not supported.

The development branch also provides `KokoroNarration` (book planning and persistent cast metadata) and `KokoroAudio` (bounded voice enhancement). They are opt-in. The historical v0.1.0 tag still uses the old module name and does not include this development API; it must not be used with the examples below. Remote consumers should pin a reviewed commit containing the rename once it is published. Neither module changes the default synthesis engine or silently enables effects.

See [the narrator integration API](docs/book-planning.md), [casting rules](docs/story-narrator.md), and [enhancement API and validation limits](docs/audio-enhancement.md). The optional, separately imported `QwenANE` product retains the Qwen renderer work; its existence does not establish device eligibility or sustained background performance. No MLX dependency is added to these library products. Rejected model auditions are not app dependencies.

## Speak

```swift
import Foundation
import LibroxTTS

let directory = URL.applicationSupportDirectory.appending(path: "KokoroModels")
// Explicit one-time download (~499 MB; ~538 MB installed).
try await ModelAssets.download(to: directory)

let engine = KokoroEngine(
    modelDirectory: directory,
    pronunciationPolicy: .independent,
    rendererPolicy: .fixedSize(directory: directory.appending(path: "decoder"))
)
let audio = try await engine.synthesize("Capítulo XII. La historia continúa.", voiceID: "ef_dora")
// audio.samples contains mono Float32 PCM at audio.sampleRate (24,000 Hz).
// Schedule it using your application's audio player.
await engine.unload()
```

This explicit configuration uses the polished frontend and original-weight decoder. The default initializer retains the older `.established` pronunciation and renderer for compatibility. See the [runnable iOS demo](Examples/KokoroDemo) for downloading, voice selection and audio playback.

Weights are fetched from a pinned public GitHub release, verified against archive and installed-file SHA-256 hashes, and kept outside the source repository. [Model provenance](THIRD_PARTY_NOTICES.md) and the [asset manifest](Sources/KokoroCatalog/Assets.json) identify the exact distribution. No network is used during synthesis.

## Pronunciation without a model

```swift
import KokoroPronunciation

let frontend = PronunciationEngine() // Keep one instance inside an actor.
let result = try frontend.phonemize("Capítulo XII", language: .spanish)
print(result.normalizedText) // Roman numeral expanded as doce.
print(result.phonemes)
print(result.diagnostics)
```

The frontend includes context-aware Roman numerals, bounded number/date/time/currency expansion, paragraph boundaries, punctuation handling and language-specific pronunciation. It exposes diagnostics for approximations or unsupported input. It does not interpret SSML or instruction prompts such as “read like an audiobook.” Preserve the author's punctuation.

| Language | Voices | Example voice |
| --- | ---: | --- |
| English (American and British) | 28 | `af_heart` |
| Spanish | 3 | `ef_dora` |
| French | 1 | `ff_siwis` |
| Hindi | 4 | `hf_alpha` |
| Italian | 2 | `if_sara` |
| Japanese | 5 | `jf_alpha` |
| Mandarin Chinese | 8 | `zf_xiaobei` |
| Brazilian Portuguese | 3 | `pf_dora` |

Use `Voice.all`, `Voice.named(_:)`, `Voice.preferred(for:)`, and `Language.allCases`. A voice selects its pronunciation language. See [frontend details and limitations](docs/pronunciation/README.md).

## Memory and background audio

`KokoroEngine` serializes inference in an actor and defaults to CPU-only execution. The fixed renderer retains one decoder, caps each decoder window at 160 frames, and segments inputs at the model's 510-token boundary. Cancellation is checked between predictions; an active Core ML prediction cannot be interrupted.

These bounds do not cap total process memory. Synthesis returns the complete audio for its input, so feed sentences or short paragraphs rather than entire books. The independent frontend rejects inputs above 16,384 Unicode scalars. French/English dictionaries and Apple language resources also consume memory.

The app owns playback, the audio session, reading position and remote commands. For background listening, enable the audio background mode, activate an `AVAudioSession` playback category, and maintain real playback. CPU-only inference does not grant unlimited background execution. Verify sustained and locked-screen behavior on your target iPhone; Mac results are not device acceptance.

## Develop

```sh
swift test
swift test -c release
swift run pronunciation-probe es 'Capítulo XII. Son las 14:01.'
python3 Scripts/download-models.py /path/to/models
swift run -c release kokoro-probe /path/to/models \
  --independent --fixed-decoder /path/to/models/decoder --all-voices
```

Ordinary tests need no model download. Opt-in inference tests use local assets. See [validation](docs/VALIDATION.md), [model export](Scripts/ModelExport/README.md), and [contributing](CONTRIBUTING.md).

## License

**Original Section9Labs code is dual-licensed under Apache-2.0 OR MIT, at your option.** See [LICENSE](LICENSE), [LICENSE-APACHE](LICENSE-APACHE), and [LICENSE-MIT](LICENSE-MIT).

This choice does not relicense third-party components. The reused English frontend and other Apache components remain Apache-2.0; dictionary data retains its own notices. Model weights and voices are separate Apache-2.0 assets. The French lexicon's upstream provenance limitation is documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This project does not claim ownership of upstream code, dictionaries or models.

Applications can show `KokoroAttribution.text` in their acknowledgements to include the bundled notices and license texts.
