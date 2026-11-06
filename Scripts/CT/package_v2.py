#!/usr/bin/env python3
"""Package the independently verified full Core ML v2 candidate.

V1 assets are read-only. Output and manifest paths must be new; adopting the
resulting manifest in the isolated v2 SDK is a separate explicit step.
"""
import argparse
import hashlib
import json
import pathlib
import shutil

def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            value.update(block)
    return value.hexdigest()

p = argparse.ArgumentParser()
p.add_argument('hybrid', type=pathlib.Path)
p.add_argument('converted', type=pathlib.Path)
p.add_argument('shape_report', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
a = p.parse_args()
assert not a.output.exists(), 'Output must be new'
v1 = json.loads((a.hybrid / 'manifest.json').read_text())
assert v1['referenceManifestSHA256'] == '8bbf2b6c453d386b905a3c99f6a77ab9705d26a3b76e09dcf29addf16cea9b62'
for item in v1['files']:
    source = a.hybrid / item['path']
    assert source.stat().st_size == item['bytes'] and digest(source) == item['sha256']
checks = json.loads(a.shape_report.read_text())
assert len(checks) == 114 and all(c['snrDB'] > 95 and c['maxAbsoluteError'] < .001 for c in checks)
for component in ['text_encoder', 'text_encoder_early', 'duration_predictor']:
    result = json.loads((a.converted / (component + '-conversion.json')).read_text())
    assert result['precision'] == 'fp32'
    assert result['coreml']['maxAbsoluteError'] < .001
    assert result['alternateCoreML']['maxAbsoluteError'] < .001
a.output.mkdir(parents=True)
for item in v1['files']:
    name = item['path']
    if name.endswith('.onnx'):
        continue
    target = a.output / name.replace('onnx/', 'config/')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(a.hybrid / name, target)
for component in ['text_encoder', 'text_encoder_early', 'duration_predictor']:
    shutil.copytree(a.converted / (component + '.mlpackage'), a.output / 'coreml' / (component + '.mlpackage'))
files = [{'path': str(path.relative_to(a.output)), 'bytes': path.stat().st_size, 'sha256': digest(path)}
         for path in sorted(a.output.rglob('*')) if path.is_file()]
manifest = {'identity': 'librox-plus-ct-f1-coremlfp32-v2',
            'referenceManifestSHA256': v1['referenceManifestSHA256'],
            'parameterCount': v1['parameterCount'], 'files': files}
(a.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
assert not list(a.output.rglob('*.onnx'))
print(json.dumps({'identity': manifest['identity'], 'files': len(files), 'bytes': sum(f['bytes'] for f in files)}))
