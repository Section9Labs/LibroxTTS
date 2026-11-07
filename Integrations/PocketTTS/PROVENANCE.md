# Pocket TTS native MLX provenance

Reference: Kyutai Pocket TTS **4.0.1**, Git revision
`28770c06f7deb1b65617834e60a6add7a4ff5b6d` (latest main retrieved 2026-11-07).
[Source](https://github.com/kyutai-labs/pocket-tts/tree/28770c06f7deb1b65617834e60a6add7a4ff5b6d).
MIT license: `LICENSE-Kyutai`.

The initial Swift layers, Mimi codec components and SentencePiece implementation
were adapted from [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/tree/9d66d6f1da37a4a116c1655e321b167b3013a5cb),
revision `9d66d6f1da37a4a116c1655e321b167b3013a5cb`:
`Sources/MLXAudioTTS/Models/PocketTTS/*.swift`,
`Sources/MLXAudioCodecs/Mimi/{Conv,Seanet,Transformer}.swift`, and
`Sources/MLXAudioCore/SentencePieceTokenizer.swift`.
MIT license: `LICENSE-MLX-Audio` (Prince Canuma, 2025).
The focused `Runtime/KVCache.swift` is a local implementation, not a copy of
MLX Audio's general-purpose cache hierarchy. MLX Swift is pinned to 0.32.3.

Local migration changes relative to that starting point:

- Directly load current Kyutai language weights, remapping SEANet names/layouts.
  Exclude unused encoder/downsampler/projection tensors in this preset-voice runtime.
  Original model weights remain byte-identical on disk; no fine-tuning/quantization.
- Preserve current **tanh GELU**, BOS-before-voice parameter, model-specific
  prefilled KV voice states and language tokenizers. The hosted voice states
  already contain BOS and must not be prompted a second time.
- Port current text splitting, punctuation/decimal/title/quote rules, configured
  character replacements, 25-token continuation, previous-audio teacher forcing,
  12-frame decoder warm-up, six-frame minimum before EOS and 5 ms onset fade.
- Remove upstream implicit Hugging Face downloads and unchecked model Sendability.
  Native inference is owned by a Swift actor and uses verified local assets.
- Fail on generation exhaustion instead of silently accepting truncated audio;
  bound source inputs, output PCM and individual generation loops.

Model assets: Kyutai's public preset-voice snapshot
`kyutai/pocket-tts-without-voice-cloning` at
`a7056f505a4a8ca72d8b5fb1440071d6f1a35739` (CC BY 4.0).
English is the current `english_2026-10` default. The other packs are the current
standard French, German, Portuguese, Italian, Spanish and Dutch models.
Each download manifest pins sizes and SHA-256 hashes. Export tooling checks
upstream LFS SHA-256 or Git blob IDs before creating those manifests.

Each pack retains `NOTICE.json`, `VOICE-CREDITS.json` with original source URLs,
and Kyutai's software license. Credit **Kyutai — Pocket TTS** and the applicable
voice contributors, link to the upstream model and CC BY 4.0 license, and state
that execution was ported to Swift MLX. Voice source licenses are independent of
the model license; consult [Kyutai's voice credits](https://huggingface.co/kyutai/tts-voices).
**Cosette (Expresso) and Jean (EARS) are excluded** because their source recordings
are CC BY-NC 4.0. Juergen and Rafael are also withheld because Kyutai does not document the
licenses of their source recordings. These four IDs are rejected rather than
substituted silently. German and Portuguese default to Alba for new selections.
The release has 23 voices (161 language/voice IDs). See [the license inventory](VOICE-LICENSES.md).
The initial 25-voice development pack and its validation evidence remain historical;
the SDK release uses the superseding `pocket-tts-mlx-2026-11-07-v2` pack.

This port's hosted presets do not enable arbitrary reference-audio cloning.
Kyutai's separate cloning-enabled distribution has an access/consent gate; it is
not fetched or mirrored by this integration. The 24-layer previews, tiny English
variants and alternative sampler families are not advertised as qualified packs.

## Librox phrasing policy (runtime v2)

The upstream fixed-target splitter remains available for reference parity checks.
Production narration uses our adaptive sentence/paragraph chunker, configurable
through `PocketTTSChunkingOptions`. This is an intentional scheduling change, not
a weight change or claim of superior listening quality. The checkpoint, operator
math, voice states and hosted asset hashes remain unchanged.
