# DK Core ML preview

This page records the original accepted F1/M1 preview. The current candidate
adds all ten presets; see [the shared-feature audit](SHARED-MODEL-FEATURE-AUDIT.md)
for its new asset identity, validation and remaining scope.

This branch integrates the frozen DK early encoder into the native Plus pipeline.
It is a local listening candidate, not a published SDK or model download. SDK
0.3.0 and TestFlight 1.9.3 (243) still use the previous CT model.

## Identity and conversion

- Base SDK: `b5d58b27b7204428ee62476058d13df51e87d7ef`.
- Candidate model: `librox-plus-dk-coreml-v1`.
- Reserved, unpublished asset tag: `plus-dk-coreml-preview-v1`.
- Frozen source manifest SHA256: `a7c2685ef1ac72dda6a06839c03639fabffac4fa2cc94c79dc8b7d3413679098`.
- DK early-encoder ONNX source SHA256: `3b7eddb46b84d4a01a18a17d2346b1bd3f838af8121fc3d368e001fa48b89efc`.
- Native manifest: 24 files, 440,066,585 bytes; includes pinned F1 and M1 styles.
- Delivery identity: `dk-delivery-v1:native44100:source-boundaries:native-dynamics`.

`Scripts/CT/convert_dk_coreml.py` verifies every frozen source file, translates
the modified early encoder, and validates Core ML output against the encoder
export graph. ONNX is the source format only; there is no ONNX Runtime audio
generation. Duration, late encoder, generator and vocoder retain the CT assets.
The DK encoder adds masked passage-summary conditioning at two style projections.

The initial English/Spanish encoder comparisons had maximum absolute error
below 0.000007. Further F1/M1 checks at lengths 8, 33, 192 and 512 stayed below
0.000014. Changing masked token IDs had zero effect. Changing total padded
length can change valid output (observed up to approximately 0.36), so production
text encoding must continue to use actual input length. These checks validate
conversion, not full-waveform equivalence or listening quality.

## Native listening path

```sh
swift build -c release --product narration-pipeline-probe
.build/release/narration-pipeline-probe --native ASSETS OUTPUT en plus-f1-en-v1 PASSAGE.txt
```

Use `plus-m1-en-v1`, `plus-f1-es-v1` or `plus-m1-es-v1` for the other comparisons.
The output directory must not already exist. The runner uses
`NarrationPipeline` → `NarrationRenderer` → `CTEngine` with foreground GPU-heavy
execution and the existing native-dynamics delivery at 44.1 kHz. It uses real
production random noise, not a deterministic seed parity claim. Voice selection
loads the pinned style without reloading the synthesis graphs and preserves the
selected style when Automatic changes language.

There is no ASR, extra audition gain, pitch/time processing or acting markup.
The planner retains paragraphs within its production limits. Renderer duration
overflow can still require bounded fragments; a planner unit count alone is not
proof that every longer passage stayed unsplit inside the renderer.

Local evidence lives at `/Users/matt/Code/swift/librox-dk-native-assets-v1`:

- `coreml/text_encoder_early-conversion.json`: conversion checks.
- `encoder-padding-validation.json`: length and masked-token checks.
- `model`: candidate assets verified against the SDK manifest.
- `native-listening-v1/manifest.json`: binary/source hashes and exact implementation snapshot.
- `native-listening-v1/{en,es}-continuity-{F1,M1}/native.wav`: four native recordings.
- Each recording has `receipt.json` with model, text, voice, delivery and audio hashes.

The four continuity examples each have one planned paragraph unit: English
16.230748 seconds and Spanish 17.275646 seconds. Their receipts bind the source
snapshot used before this documentation and preview-distribution test update.
Matt accepted these four recordings as meeting the basic voice-quality bar,
as relayed by the research chat on November 6, 2026:
"These new male and female voices sound good and meet the bar continue improving them using coreML sdk."
This accepts F1/M1 English/Spanish basic voice quality, not human-level emotion,
DL pacing, or device qualification. The accepted runtime source is commit
`fc1a614d4d702e2416f8e94c8742f0c02f39cf42`; the original receipts retain their
pre-commit implementation snapshot and must not be rewritten.

| Accepted recording | WAV SHA256 |
| --- | --- |
| en-continuity-F1 | `19af74f8fdac17361660fc1697ed964faecfa4757fee02cd5892211d0c548b72` |
| en-continuity-M1 | `bcb0d338a16518bd877842ac731a3b9cc10c3ada2c722cd4e8c08966204592ab` |
| es-continuity-F1 | `6d211e6c85a1cec8943dcde57752ed66c328239f2ce90d6d3bdabb289a888ccb` |
| es-continuity-M1 | `b144dd08f5aec88cb16ad91533ff9f7ddaa5accc8ee0b8999a98cafacf6edee0` |

## Remaining release scope

DL Spanish pacing is not implemented here. The accepted offline version depended
on ASR word timing to place silence at verified boundaries; the native engine
does not currently expose equivalent alignment. This candidate uses native DK
pacing and must not be described as DK+DL parity.

Context-aware emotion control is also unfinished. Story metadata attached to
fields the renderer does not consume cannot establish acoustic expression.
M1 is a pretrained style choice, not a new emotion-control system. The accepted
examples use its inherited delivery gain; broad loudness calibration remains
outside those four listening examples.

Native DK has not yet been qualified on iPhone/iPad, for memory/cold start or
background handoff. Previous CT device results do not qualify the changed model.
The existing bounded vocoder and ten-step generator are retained.

Download availability is deliberately false for Plus on this preview branch.
A future release needs immutable published assets, an SDK release and app
integration. Existing CT installations must remain usable until a new version
is verified and prepared, then selected atomically for a new playback session.
Different model/delivery identities must invalidate rendered PCM. Reuse unchanged
files where supported; do not replace old public assets in place or claim that
the current app already supports this model-update workflow.
