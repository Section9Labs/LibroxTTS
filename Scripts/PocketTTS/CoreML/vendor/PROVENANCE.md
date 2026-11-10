`mimi.py` is adapted from FluidInference/mobius, Apache-2.0, commit
`210d6b6d21177115babfece0de5e1795cffec2a2`, file
`models/tts/pocket_tts/coreml/convert_models/traceable/traceable_mimi_decoder.py`.
The license is retained beside it.

Local changes for the pinned Max / Pocket TTS 4.0.1 checkpoint:

- Accept the current attention `attn_mask` parameter and omit its unused
  batch-one `pad` state from the exported interface.
- Pass denormalized `[B,T,32]` latents to the current Mimi decoder, which applies
  quantization internally. Never quantize twice.
- Use a 512-position ring, covering the complete 250-token context plus the
  sixteen tokens decoded together. A 256-position ring overwrites some keys
  still needed by early queries in the next block.

The outer exporter removes unchanged `first` flags and empty convolution states
from the Core ML interface. Max's convolution padding is constant. Float32
compute and tanh GELU are retained. Independent validation compares 70 frames
(two ring wraps) against the original, unpatched Kyutai decoder.
