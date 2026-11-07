# Librox Plus DK — Core ML, ten native voice presets

This is a modified derivative of Supertone Supertonic 3, distributed under the
included BigScience Open RAIL-M license and its use restrictions. It is not an
official Supertone release; no endorsement is implied.

Section9Labs modifications include the CT early encoder and generator adaptation,
DK masked passage-summary projections in the early encoder, and Core ML FP32
conversion of all five synthesis graphs. Generator specializations share weights.
The DK early encoder is used for steps 0–2, the original encoder for steps 3–9.
Native duration, ten generation steps and bounded vocoder are retained.

The upstream F1–F5 and M1–M5 voice tables, config and Unicode index are preserved.
This bundle adds eight original voice presets to the earlier F1/M1 candidate;
all synthesis graphs and the existing F1/M1 tables are byte-identical to it.
Earlier embedded CT package metadata describes its original conversion; this
notice and the pinned manifest describe the DK bundle as distributed here.

F1/M1 English/Spanish native voice quality was accepted in listening. The other
presets are enabled at the user's request; technical rendering does not establish
perceptual acceptance. DL pacing and context/emotion controls are not included.

Model and voice assets retain the model license. Helper adaptations retain their
separate MIT license. The SDK Apache-2.0 OR MIT option does not relicense models.
Downstream redistribution must retain the complete included model license,
including paragraph 5 and Attachment A, and require compliance with restrictions.
