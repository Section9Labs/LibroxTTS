# Chatterbox 8-bit alternatives and the phone-build gate

Checked29October2026 against publisher model cards and exact Hugging Face API
revisions. This is a source audit, not our runtime or listening qualification.
Only metadata/cards were fetched; no duplicate model downloads or phone work.

| Publisher/model | Pinned revision | Evidence and limitation |
| --- | --- | --- |
| [mlx-community/chatterbox-8bit](https://huggingface.co/mlx-community/chatterbox-8bit) | `9617d61b596a03d1bed766a28c341680e993a1b9` | MLX-Audio0.2.7 conversion with multilingual/cloning examples. Card does not provide iPhone full-pipeline, sustained narration or EN/ES listening qualification. A Python MLX package is not a Core ML export or a validated Swift runtime. |
| [iliasaz/chatterbox-multilingual-coreml](https://huggingface.co/iliasaz/chatterbox-multilingual-coreml) | `295edc75a44a4ac22ef8344780a1ec06b63a0d0b` | V3,8-bit palettized T3 with Core ML acoustic/voice encoders. Publisher reports Russian listening on iPhone17ProMax; other-language checks are plausible output length. This is already the exact artifact revision in our vendor provenance, not a newly discovered fix. |
| [FluidInference/chatterbox-multilingual-coreml](https://huggingface.co/FluidInference/chatterbox-multilingual-coreml) | `b79c3e48e44e12cac4f280dc647941ca332c2930` | V2 FP16 export with numerical checks and English end-to-end examples. Not8-bit; different model/runtime contract. Voice-cloning encoders and watermark stage are not included in that export. It cannot replace our full private-voice pipeline unchanged. |
| [groxaxo/Chatterbox-Multilingual-es-mx-latam-MLX-8bit](https://huggingface.co/groxaxo/Chatterbox-Multilingual-es-mx-latam-MLX-8bit) | `5b709c52d98b51d07fe54f1110e2dccb8b953a51` | Regional Spanish V3 checkpoint. Publisher reports native Mac Metal speech generation and saturation checks after a runtime correction. Human listening, pronunciation, speaker similarity, original-audio equivalence and separate strict matmul checks remain unqualified. A possible isolated Spanish comparison, not a proven iPhone replacement. |
| [groxaxo/Chatterbox-Multilingual-es-mx-latam-MLX-8bit-HQ](https://huggingface.co/groxaxo/Chatterbox-Multilingual-es-mx-latam-MLX-8bit-HQ) | `46ce70510b40ab98ae57c1578b6e3fd800ac03a4` | Selectively quantized group32 version protecting first/last blocks. Publisher reports CPU conversion/load/transformer checks and explicitly no waveform, listening or Apple Metal benchmark. HQ is a storage-policy name, not a perceptual-quality result. |

The checked releases do not establish a drop-in8-bit package already accepted for
our English, Spanish, saved voices and sustained iPhone narration. Do not treat
publisher claims as local validation, weight error as an audio-quality score, or
file size as peak device memory. The linked smdesai artifact also remains excluded
from hybrid use: its different frontend/norm/head tensors cannot be mixed with
our canonical V3 components to produce a legitimate quality comparison.

Primary-source card snapshots, exact revisions and hashes are retained in owned
SSD `runs/chatterbox-quantization-evaluation-v01/alternative-model-metadata-2026-10-29/manifest.json`.

## Required before a further app build

1. Independently qualified decoder arithmetic and complete frozen EN/ES tests,
   with unchanged precision/top1 criteria. Old failed profiles remain immutable.
2. Actual library path: text planning, grouping, immutable voice conditioning,
   decoder, acoustic synthesis, waveform validation, successful watermark and
   cache/playback acknowledgements. Include repeated passages, cancellation,
   voice changes, memory pressure and rate-aware buffer accounting.
3. Matched Standard/candidate stock and authorized local reference-voice audio:
   same text, scalar options and sampling/acoustic-noise controls. Preserve raw
   and level-matched audio; report clipping/limiter activity without masking
   malformed outputs. No external audio judge or quality claim from loss alone.
4. Report complete audio timing, memory, stage costs and underruns. Full5x means
   RTF<=0.20 at1x including acoustics and watermark, not decoder tokens/second.
   A Mac pass is preliminary and does not prove iPhone speed, battery or sound.
5. Send T3 an exact reviewed SDK/artifact contract only after these library gates.
   T3 owns integration, document text/settings, playback/UI and OS lifecycle.
   No speculative diagnostic app build, silent profile fallback or gate changes.

Physical device qualification still needs a concrete reviewed signed artifact,
fresh device availability and MAIN ownership coordination. Actual user-made
conditioning stays private on the phone. Matt remains the listening acceptance
gate. Preserve saved voices, recordings, books, downloads and reading place.
No TestFlight upload, merge or release is authorized by this validation work.
