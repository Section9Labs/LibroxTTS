# Librox Plus CT F1 — Core ML v2

This is a modified derivative of Supertone Supertonic 3, distributed under the
included BigScience Open RAIL-M license, including all of its use restrictions.
It is not an official Supertone release and no endorsement is implied.

Section9Labs modifications comprise the CT early text encoder, CT generator
adaptation, conversion of all five graphs to Core ML FP32, exact-length generator
specializations sharing weights, and an equivalent short-length padding rewrite.
The early encoder is used for steps 0–2 and the original encoder for steps 3–9.
The public voice is the upstream F1 preset; only English and Spanish are qualified.
The Core ML conversion does not edit or quantize the frozen CT learned weights.
Every modified Core ML package carries this notice in its model metadata; its
associated weight blob is part of that modified model package.

The upstream config, Unicode index and F1 style are preserved. Model/voice assets
retain the model license. The helper adaptation retains the separate MIT license.
The SDK's Apache-2.0 OR MIT option does not relicense these model assets.

Use and redistribution of these models must comply with the complete included
model license, in particular paragraph 5 and Attachment A. Downstream applications
must pass on the license and require their users to comply with those restrictions.
