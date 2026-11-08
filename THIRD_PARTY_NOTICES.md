# License scope

Original Section9Labs contributions: **Apache-2.0 OR MIT**. Upstream components below retain their own licenses; an MIT choice for our code does not remove Apache obligations for bundled dependencies.

| Paths | License / origin |
| --- | --- |
| `Sources/PronunciationEnglish/**` | Apache-2.0, kokoro-swift / Misaki; includes dictionaries |
| `Sources/KokoroKit/Pronunciation/{Chinese,Hindi,Japanese,Latin}Phonemizer.swift`, `PronunciationDicts.swift` | Apache-2.0, adapted speech-swift |
| `Sources/KokoroKit/Resources/dict_*.json` | speech-swift dictionary distribution; Apache-2.0 and preserved ipa-dict MIT attribution |
| `Sources/KokoroPronunciation/Resources/Romance/**` | ipa-dict French data, MIT with the documented provenance limitation |
| `Sources/KokoroKit/Resources/vocab.json`, `Scripts/ModelExport/backend.py` | Apache-2.0, Kokoro |
| `Benchmarks/Narration/vendor/**`, `Benchmarks/Narration/frontend.py` | Apache-2.0, Jud/kokoro-coreml and hexgrad/kokoro benchmark adapters; see vendor README |
| `Licenses/**`, notices and quoted license text | Original upstream terms and ownership |
| Downloaded weights and voice embeddings | Model-specific terms: Kokoro Apache-2.0, Plus Open RAIL-M, Pocket CC BY 4.0 plus recording-source terms; not covered by our MIT option |
| Other original code, tests and documentation | Apache-2.0 OR MIT |

# Third-party notices

LibroxTTS is an independent integration. It does not claim authorship of the original models, dictionaries, or phonemization algorithms, or endorsement by their authors.

## Code and dictionary sources

- **mweinbach/kokoro-swift**, revision `20bf04c506e913ff129d7d2229398180ba24c690`, Apache-2.0: the four Swift files and four dictionaries from `Packages/Misaki` now live in the `Sources/PronunciationEnglish` target. They moved from `Sources/KokoroMisaki` so there is only one bundled copy. Changes: module naming, package resource layout, attribution, and integration into actor-owned synthesis. No MLX or segmented model code is shipped. License: `Licenses/kokoro-swift-LICENSE`. Source: https://github.com/mweinbach/kokoro-swift
- **hexgrad/misaki**, the upstream English G2P and dictionaries ported by kokoro-swift, Apache-2.0. License copied from upstream at `fba1236595f2d2bf21d414ba6e57d25256afada3`: `Licenses/misaki-LICENSE`. Source: https://github.com/hexgrad/misaki
- **soniqo/speech-swift**, revision `511307a1dbb3b9abbba4d5a598bc1e9c503b63f7`, Apache-2.0: Japanese, Mandarin, Hindi and four Latin-language pronunciation algorithms; pronunciation dictionaries for French, Portuguese, Hindi, Spanish and Italian. Changes: standalone resource layout, internal visibility, removal of unsupported-language code, and routing/number normalization in a new phonemizer. License: `Licenses/speech-swift-LICENSE`. Source: https://github.com/soniqo/speech-swift
- **open-dict-data/ipa-dict**, copyright (c) 2016 dohliam, MIT: credited by speech-swift for pronunciation dictionary material. License: `Licenses/ipa-dict-LICENSE`. Source: https://github.com/open-dict-data/ipa-dict. This package does not incorporate its German, Finnish, Japanese, or British-English wordlists. British English is provided by the Misaki resources above.
- **Jud/kokoro-coreml**, inspected revision `6bfc02afb237a311caee927482e58c028edb6acb`, Apache-2.0: Core ML two-model feature contract, length-indexed binary voice format, and boundary-duration trimming approach. The small Swift model/voice adapters are rewritten for serial actor ownership and checked asset loading. License: `Licenses/kokoro-coreml-LICENSE`. Source: https://github.com/Jud/kokoro-coreml

The package uses Apple system frameworks and system zlib. It does not bundle eSpeak, Python, ONNX Runtime, MLX, or the original applications.

The opt-in `.independent` pronunciation route uses the `KokoroPronunciation` target; see the pronunciation provenance below for independently authored language rules, reused English components, and French data provenance. The `.established` route retains the speech-swift language providers listed above. Both routes share the single English component. The new package's declared-MIT French resource has an upstream provenance caveat documented in its notices.

## Model

Kokoro-82M v1.0 by hexgrad / rzvzn, with architecture based on StyleTTS 2 (Li et al.) and iSTFTNet. Model license: Apache-2.0, as declared at https://huggingface.co/hexgrad/Kokoro-82M. `LICENSE-APACHE` includes those terms. The model vocabulary is included in `Sources/KokoroKit/Resources/vocab.json`.

The pinned download combines Jud's `models-2026-03-23` Core ML frontend/backend and 54 voice embeddings with the original-weight fixed/short decoders exported below. Its exact archive and installed hashes are in `Assets.json`. Weights are not included in source control. No training audio is bundled.

Preserved training-data attribution from the Kokoro model card:

- Koniwa `tnc`: https://github.com/koniwa/koniwa, CC BY 3.0, https://creativecommons.org/licenses/by/3.0/deed.ja. Less than one hour used according to the model card.
- SIWIS French Speech Synthesis Database: https://datashare.ed.ac.uk/handle/10283/2353, CC BY 4.0; license https://datashare.ed.ac.uk/bitstream/handle/10283/2353/license_text. Less than eleven hours used according to the model card.

The model card, upstream license files and these acknowledgements retain their original ownership. Changes to this integration do not change those terms.

## Original-weight decoder exporter

`Scripts/ModelExport/backend.py` adapts the decoder/generator forward structure from **hexgrad/kokoro** (Apache-2.0). The real-valued inverse STFT preserves the original Hann-window overlap normalization. `export.py` exports original Kokoro-82M v1.0 weights pinned to Hugging Face revision `f3ff3571791e39611d31c381e3a41a3af07b4987`, checkpoint SHA-256 `496dba118d1a58f5f3db2efc88dbdc216e0483fc89fe6e47ee1f2c53f18ad1e4`. These are model derivatives under the original Apache terms, not newly authored model weights. Source: https://github.com/hexgrad/kokoro .

Export tooling is development-only; PyTorch, coremltools and comparison phonemizers are not runtime dependencies of the Swift package. The optional fixed/short assets are stored outside Git and retain the model attribution above. This changes the decoder, not the provenance of the existing frontend, dictionaries or voices.


# Third-party notices and provenance

The new Spanish, French-context, Italian, Brazilian Portuguese, Hindi, Japanese and Mandarin rule implementations were authored from linguistic knowledge and cited descriptions, not translated from eSpeak's implementation or copied rule tables. Their implementation agents were not given eSpeak source or reference output. Reference comparisons were generated separately after these implementations. This documents the procedure; it is not a formal legal clean-room certification.

Functional similarity is not by itself a claim of copied expression. Conversely, using an agent, another programming language, or a fresh file does not automatically remove obligations attached to copied code or data. The library does not claim to reproduce all eSpeak behavior, languages, or resources.

## English: reused Apache-2.0 component

`Sources/PronunciationEnglish` contains four Swift files and four JSON resources previously used in KokoroKit. They originated in `mweinbach/kokoro-swift`, revision `20bf04c506e913ff129d7d2229398180ba24c690`, `Packages/Misaki`, a Swift adaptation of hexgrad's Misaki. Source files/data moved without rewriting their phonological content. New work changes the package/module location, adds a common adapter and bounded dialect cache, and spells out an optional-Boolean switch case for older Swift 6 compilers without changing its results.

- https://github.com/mweinbach/kokoro-swift
- https://github.com/hexgrad/misaki
- [kokoro-swift license](Licenses/kokoro-swift-LICENSE)
- [Misaki license](Licenses/misaki-LICENSE), retained upstream revision `fba1236595f2d2bf21d414ba6e57d25256afada3`

This is attributed reuse, not independently authored English pronunciation data.

## French: declared-MIT lexicon

Only `fr_FR.txt` from `open-dict-data/ipa-dict`, revision `43c3570eb3553bdd19fccd2bd0091534889af023`, is transformed into the bundled `french-ipa.tsv`. Copyright (c) 2016 dohliam. Full MIT terms and attribution are bundled beside the data under `Sources/KokoroPronunciation/Resources/Romance/`.

Upstream declares French MIT. Its README also globally credits Aspell wordlists, without a per-entry origin map. The declared license was checked, but the complete underlying chain of title was not audited. Do not portray this as an unconditional legal clearance. No other ipa-dict language resources are imported. Checksums, transformations and reproduction instructions: [ROMANCE.md](docs/pronunciation/ROMANCE.md).

## System facilities and model interface

Apple Foundation, CoreFoundation and NaturalLanguage supply number spelling, English tagging, and contextual Japanese/Mandarin readings. They remain system facilities; Apple dictionaries are not extracted or redistributed. The package currently requires Apple platforms.

The model-alphabet adapter targets Kokoro v1.0, an Apache-2.0 model by hexgrad/rzvzn: https://huggingface.co/hexgrad/Kokoro-82M. No weights, voice embeddings or training audio are included here. A downstream model distributor must preserve its model/data notices separately.

## Benchmark boundary

The parent repository's B/C reference experiments use Python Misaki and eSpeak NG. Those are development reference tools outside this package, not linked dependencies or bundled resources. Their licenses remain applicable to their distribution. Do not bundle those environments into a release of this library. No reference-generated pronunciation dictionary is shipped.

The engineering distinction follows the Copyright Office's discussion of functionality versus expression ([Circular 61](https://www.copyright.gov/circs/circ61.pdf)); translated GPL code remains a modification under the [GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#TranslateCode). These references explain the chosen provenance process, not a project-specific legal opinion.

## Narration laboratory helpers

The optional larger-model narration experiments use Qwen3-TTS-12Hz-1.7B-VoiceDesign
weights (Apache-2.0) through MLX Community BF16 revision
`7d3824abff87e49756bb0f83fb5411de75d160c4` and 8-bit revision
`f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee`. Upstream:
https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign . The local Python
runner uses mlx-audio (MIT), not vendored into the Swift targets. Free
transcription checks use Whisper large-v3-turbo (MIT) via the MLX Community
conversion `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` and mlx-whisper (MIT).
These downloads remain external; our package license does not replace their
licenses. Runtime versions and weight hashes are recorded with benchmark results.
No larger-model output has been used to train or distill the shipped model.

The reference-anchored narration experiment additionally uses
`mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit`, revision
`e7dd0585652209fa0d7783659aad4e8a324de11c`, converted from
https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base (Apache-2.0).
Its reference voices are generated with the VoiceDesign checkpoint above,
using locally authored calibration sentences. No person's recording is used.
Weights and complete checkpoint notices remain in the external model cache;
this research runner does not bundle or redistribute them.

The round-three reference comparison also conditions Base on locally synthesized
Kokoro `ef_dora` audio. This is model-generated reference audio, not a human
recording. The optional `Benchmarks/Narration/harmonic_source.py` research export
adapts the Apache-2.0 Kokoro `SineGen`/`SourceModuleHnNSF` equations and the
attributed STFT helper below. Its code is Apache-2.0, not independently authored
pronunciation logic; the trained linear weights retain the Kokoro model terms.

The literary test texts are excerpts of Lewis Carroll's *Alice's Adventures in
Wonderland* (ebook 11) and Benito Pérez Galdós's *Tormento* (ebook 31465), listed
as public domain in the USA by Project Gutenberg. Exact source URLs, source
hashes and excerpt boundaries accompany the corpus. Narration is synthesized;
no human narrator recording is included. Project Gutenberg's surrounding
boilerplate and trademarks are not claimed as newly authored package content.

The optional local phonetic audit downloads two speech-recognition checkpoints outside the Swift package: [Cnam-LMSSC/wav2vec2-spanish-phonemizer](https://huggingface.co/Cnam-LMSSC/wav2vec2-spanish-phonemizer/tree/6e8a11b261acab0fb6ab6258b7082a2e88b4ed36), declared MIT, and [facebook/wav2vec2-xlsr-53-espeak-cv-ft](https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft/tree/2c733782da5604684829819a5eb744c193fe9398), declared Apache-2.0. Neither checkpoint nor its training data is redistributed or used to generate a library dictionary. The recognizers run on waveform samples only; no eSpeak executable or text phonemizer is called by the audit. The checkpoint names and output conventions do not establish error-free phonetic ground truth. See `Benchmarks/Narration/PHONETIC-AUDIT.md` for exact scope, provenance, controls and limitations.

`Benchmarks/Narration/vendor/{export_coreml,coreml_ops,reference}.py` are unmodified Apache-2.0 helpers from Jud/kokoro-coreml revision `6bfc02afb237a311caee927482e58c028edb6acb`. `frontend.py` adapts the Kokoro acoustic forward and those length-aware wrappers to export acoustic outputs without harmonic generation. The local converter adapter preserves PyTorch integer `rsqrt` promotion. These benchmark-only files are excluded from all Swift targets. See `Licenses/kokoro-coreml-LICENSE`, the original model notices above, and `Benchmarks/Narration/README.md`.

The medium-device harness uses `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit`,
revision `50f45ef0047cde7e84c2ef04326acb8ada2436a7`, converted from Qwen's
Apache-2.0 Base model. Its native runtime is `Blaizzy/mlx-audio-swift` (MIT),
revision `d302a5c6080d2bb97bae38c7418f82abb76013b6`, with MLX Swift 0.31.6
(MIT). These are dependencies of the standalone benchmark app, not the library.
The model manifest records byte counts and hashes; no weights, generated audio,
signing keys, device reports or provisioning profiles are committed.


## CMUdict English supplement

`Sources/PronunciationEnglish/Resources/us_cmudict.json` derives from the Carnegie Mellon Pronouncing Dictionary, revision `74790861f652b15e4ac49015a90074ad62a27690` at https://github.com/cmusphinx/cmudict. It adds 69,043 US fallback spellings; existing contextual dictionaries retain priority. The independently authored British name supplement is not derived from CMUdict.

CMUdict retains its own redistribution terms, reproduced below, rather than our Apache-2.0 OR MIT choice. The deterministic importer and exact source/output checksums are documented in `Sources/PronunciationEnglish/Resources/CMUdict/ENGLISH-SUPPLEMENT-NOTICE.md`.

Copyright (C) 1993-2015 Carnegie Mellon University. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
   The contents of this file are deemed to be source code.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in
   the documentation and/or other materials provided with the
   distribution.

This work was supported in part by funding from the Defense Advanced
Research Projects Agency, the Office of Naval Research and the National
Science Foundation of the United States of America, and by member
companies of the Carnegie Mellon Sphinx Speech Consortium. We acknowledge
the contributions of many volunteers to the expansion and improvement of
this dictionary.

THIS SOFTWARE IS PROVIDED BY CARNEGIE MELLON UNIVERSITY ``AS IS'' AND
ANY EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL CARNEGIE MELLON UNIVERSITY
NOR ITS EMPLOYEES BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


## UniDic Japanese pronunciation data

UniDic 2.1.2, Copyright (c) 2011-2013 The UniDic Consortium, is redistributed under its BSD-3-Clause alternative. This is a filtered, indexed derivative; no endorsement is implied. Source and modifications are documented in the bundled JapaneseUniDic/UNIDIC-NOTICE.txt and UNIDIC-COPYING.txt.

Copyright (c) 2011-2013, The UniDic Consortium
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

 * Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the
   distribution.

 * Neither the name of the UniDic Consortium nor the names of its
   contributors may be used to endorse or promote products derived
   from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


## Librox Plus CT F1 / Supertonic 3 (Core ML v2)

Plus model and voice assets are a modified derivative of Supertone Supertonic 3,
Copyright (c) Supertone Inc., distributed separately under the BigScience Open
RAIL-M License, dated August 18, 2022, including its use restrictions. They are
not relicensed under this repository's Apache-2.0 OR MIT option. The full license,
modification notice and MIT helper license are bundled under
`Integrations/CTNative/Sources/LibroxCTNative/Resources/` and accompany each model
download. Apps must pass on the model license and require their users to comply
with its use restrictions. `KokoroAttribution.text` includes these notices.

The Swift tokenizer adapts the Supertone MIT helper, Copyright (c) 2025 Supertone
Inc. Other original CT runtime code is Apache-2.0 OR MIT. See
[the Core ML v2 provenance and integration contract](docs/COREML-V2.md).

## Pocket TTS / native MLX integration

Pocket TTS by Kyutai: MIT implementation, CC BY 4.0 model weights. Native Swift
components adapted from MLX Audio Swift (MIT, Prince Canuma). See
[exact revisions, modifications and licenses](Integrations/PocketTTS/PROVENANCE.md).
Hosted language packs retain Kyutai attribution and per-voice source credits.
Cosette/Expresso and Jean/EARS are excluded from the commercial preset catalog.
MLX Swift and its transitive dependencies retain their own licenses.

Pocket source recordings are inventoried in [VOICE-LICENSES.md](Integrations/PocketTTS/VOICE-LICENSES.md). The SDK release retains 23 presets with CC BY 4.0 or CC0 source declarations; Cosette/Jean (noncommercial) and Juergen/Rafael (source rights undocumented) are excluded. Model weights and distributed voice states retain Kyutai attribution regardless of the recording license.
