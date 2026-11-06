#!/usr/bin/env python3
"""Verify full Core ML text/duration conversion at attention and range boundaries."""
import argparse
import json
import pathlib
import coremltools as ct
import numpy as np
import onnxruntime as ort

p = argparse.ArgumentParser()
p.add_argument('assets', type=pathlib.Path)
p.add_argument('models', type=pathlib.Path)
p.add_argument('fixtures', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
a = p.parse_args()
assert not a.output.exists()
layout = json.loads((a.fixtures / 'layout.json').read_text())
def tensor(name):
    spec = layout[name]
    return np.fromfile(a.fixtures / (name + '.bin'), dtype=spec['dtype']).reshape(spec['shape'])

options = ort.SessionOptions()
options.intra_op_num_threads = 4
rows = []
for component in ['duration_predictor', 'text_encoder', 'text_encoder_early']:
    native = ct.models.MLModel(str(a.models / (component + '.mlpackage')), compute_units=ct.ComputeUnit.CPU_ONLY)
    reference = ort.InferenceSession(str(a.assets / 'onnx' / (component + '.onnx')), options, providers=['CPUExecutionProvider'])
    style = 'style_dp' if component == 'duration_predictor' else 'style_ttl'
    for length in [8, 9, 10, 16, 17, 31, 32, 63, 64, 127, 128, 191, 192, 199, 256, 280, 384, 511, 512]:
        for masked in [False, True]:
            mask = np.ones((1, 1, length), np.float32)
            if masked:
                mask[..., -min(3, length // 4):] = 0
            feed = {'text_ids': np.resize(tensor('text_ids'), (1, length)),
                    'text_mask': mask, style: tensor(style)}
            expected = reference.run(None, feed)[0]
            actual = next(iter(native.predict({k: v.astype(np.int32) if v.dtype == np.int64 else v for k, v in feed.items()}).values()))
            assert actual.shape == expected.shape and np.isfinite(actual).all()
            delta = actual.astype(np.float64) - expected.astype(np.float64)
            energy, error = float(np.sum(expected.astype(np.float64) ** 2)), float(np.sum(delta ** 2))
            row = {'component': component, 'length': length, 'maskedTail': masked,
                   'maxAbsoluteError': float(np.max(np.abs(delta))),
                   'snrDB': 999 if error == 0 else float(10 * np.log10(energy / error))}
            print(row, flush=True)
            rows.append(row)
            assert row['maxAbsoluteError'] < 0.001 and row['snrDB'] > 95, row
a.output.write_text(json.dumps(rows, indent=2) + '\n')
print('PASS', len(rows), 'component checks', flush=True)
