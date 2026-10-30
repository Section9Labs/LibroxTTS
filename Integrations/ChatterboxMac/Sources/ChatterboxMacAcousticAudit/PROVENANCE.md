# Acoustic-only native Swift inventory source

Pinned source: https://github.com/Blaizzy/mlx-audio-swift at
`d08558975ef219e5ed38c71fe2522cc03167899f`, MIT license in LICENSE.

Only regular S3Gen FlowMatching, ConformerEncoder and HiFTGenerator are reused.
Original SHA256 values: FlowMatching e523a367afb5c993d9e65478d8ca150a802036789ed0a7cebb20081eb66c2e0a;
ConformerEncoder 22c95064834b2bb9207bb34dc86eade6061f2b5db12bb361c6b1d8c113e592fb;
HiFTGenerator fb7f0efae2bfe9497a210caa08f7a86f449c01727041e23b1b603a1a179c7f55.
Name remappers are copied from that revision's ChatterboxModel.swift.

Local changes: macOS compilation guard; explicit MLXFFT import; remove the
speaker_encoder property/constructor. The seam requires an already prepared
stock x-vector, so it does not instantiate speaker extraction, a tokenizer or a
second decoder. Every excluded raw namespace has an explicit inventory reason.
No numeric operation or solver setting is changed. meanflow is explicitly false.

This target is an offline constructor/header inventory, not an exported library
product, strict weight loader, GPU runner or production renderer. Random
constructor parameters are inspected for metadata only and never used in a
forward. No audio/conditioning/private input is accepted. The original upstream
partial-cancellation behavior is not accepted for rendering: any later wrapper
must check cancellation before accepting a trajectory. No permissive loading or
peak normalization is copied. Rendering/quality/speed remain unqualified.

V04 preparation, based on preserved V03 real constructor report SHA
20ddc1347e30e10e7cc179b74550c31cf9686d3897dcdc77b5ea83af583bc83e:
regular encoder `encoders_N`/`up_encoders_N` prefixes map to Swift array paths.
All190 affected shapes/dtypes pair exactly. The Turbo-only `time_embed_mixer`
module is now optional and is not created in regular mode; its absent checkpoint
weight is never waived or replaced with a random value. No regular forward
operation is changed. Removing a random constructor changes later global RNG
side effects; a future renderer must freeze/reset independent request/vocoder
noise and never depend on constructor draw counts. Fixed CFM randNoise is created
before the estimator/mixer, so this removal does not change its existing recipe.
A fresh reviewed constructor gate is required; this is not runtime clearance.
