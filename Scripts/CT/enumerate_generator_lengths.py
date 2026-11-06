#!/usr/bin/env python3
"""Enumerate exact latent lengths; pad only masked text, never speech latents.

The source must use fixed 512-token text inputs and a flexible latent axis.
Each group contains at most 128 lengths, Core ML's per-function limit.
"""
import argparse
import pathlib
import coremltools as ct

p = argparse.ArgumentParser()
p.add_argument('source', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--first', type=int, required=True)
p.add_argument('--last', type=int, required=True)
a = p.parse_args()
assert 1 <= a.first <= a.last <= 431 and a.last - a.first < 128
assert not a.output.exists()
m = ct.models.MLModel(str(a.source), skip_model_load=True)
s = m.get_spec()
for inp in s.description.input:
    t = inp.type.multiArrayType
    if inp.name in ['text_ids', 'text_mask', 'text_emb']:
        assert t.shape[-1] == 512 and not t.HasField('shapeRange')
    if inp.name in ['noisy_latent', 'latent_mask']:
        dims = list(t.shape)
        t.ClearField('shapeRange')
        t.ClearField('enumeratedShapes')
        default = max(a.first, min(a.last, 178))
        t.shape[-1] = default
        # Match EnumeratedShapes: the preferred/preallocated shape comes first.
        for length in [default] + [n for n in range(a.first, a.last + 1) if n != default]:
            t.enumeratedShapes.shapes.add().shape.extend(dims[:-1] + [length])
out = ct.models.MLModel(s, weights_dir=m.weights_dir, skip_model_load=True)
out.user_defined_metadata['ct.textCapacity'] = '512'
out.user_defined_metadata['ct.latentRange'] = f'{a.first}:{a.last}'
a.output.parent.mkdir(parents=True, exist_ok=True)
out.save(str(a.output))
print(a.output)
