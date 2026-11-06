#!/usr/bin/env python3
"""Package a verified CT v2 bundle for public distribution without changing graphs.

Adds model-level modification/license metadata, preserves every weight byte,
and emits flattened GitHub assets plus SDK and host download manifests.
Requires coremltools only to edit protobuf metadata; no inference conversion runs.
"""
import argparse
import hashlib
import json
import pathlib
import shutil

from coremltools.proto import Model_pb2


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('reference', type=pathlib.Path, help='Frozen reference manifest')
parser.add_argument('output', type=pathlib.Path, help='New, non-existing output directory')
parser.add_argument('--release-tag', default='plus-coreml-v2-2026-11-06')
args = parser.parse_args()
manifest = json.loads((args.source / 'manifest.json').read_text())
assert digest(args.reference) == manifest['referenceManifestSHA256']
reference = json.loads(args.reference.read_text())
for item in manifest['files']:
    path = args.source / item['path']
    assert path.stat().st_size == item['bytes'] and digest(path) == item['sha256'], item['path']
args.output.mkdir(parents=True, exist_ok=False)
bundle = args.output / 'CTCoreMLV2GPUAssets'
shutil.copytree(args.source, bundle)
modification = (
    'Modified by Section9Labs: CT F1 derivative of Supertone Supertonic 3; '
    'Core ML FP32 conversion, exact-shape GPU specialization, edited early text '
    'encoder at steps 0-2 and CT generator adaptation. Conversion changes no '
    'learned weights from the frozen CT reference. See licenses/MODIFICATIONS.md '
    'and licenses/model-LICENSE, including its use restrictions.'
)
metadata_changes = []
for path in sorted(bundle.glob('coreml/*/Data/com.apple.CoreML/model.mlmodel')):
    original = Model_pb2.Model()
    original.ParseFromString(path.read_bytes())
    updated = Model_pb2.Model()
    updated.CopyFrom(original)
    metadata = updated.description.metadata
    metadata.author = 'Supertone Inc.; CT adaptation and Core ML conversion by Section9Labs'
    metadata.license = 'BigScience Open RAIL-M (2022-08-18); see licenses/model-LICENSE'
    metadata.shortDescription = modification
    metadata.userDefined['com.section9labs.modifications'] = modification
    metadata.userDefined['com.section9labs.referenceSHA256'] = manifest['referenceManifestSHA256']
    metadata.userDefined['com.section9labs.release'] = args.release_tag
    encoded = updated.SerializeToString()
    original.description.ClearField('metadata')
    updated.description.ClearField('metadata')
    assert original == updated, 'Only descriptive metadata may change'
    path.write_bytes(encoded)
    metadata_changes.append(str(path.relative_to(bundle)))
for item in manifest['files']:
    if item['path'] not in metadata_changes:
        assert digest(bundle / item['path']) == item['sha256'], item['path']

(bundle / 'licenses/MODIFICATIONS.md').write_text('''# Librox Plus CT F1 — Core ML v2

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
''')
write_json(bundle / 'provenance.json', {
    'identity': manifest['identity'], 'release': args.release_tag,
    'upstreamRepository': reference['model'], 'upstreamRevision': reference['revision'],
    'upstreamProject': 'https://huggingface.co/Supertone/supertonic-3',
    'referenceManifestSHA256': manifest['referenceManifestSHA256'],
    'sourceGraphs': [{k: f[k] for k in ('path', 'bytes', 'sha256')}
                     for f in reference['files'] if f['path'].endswith('.onnx')],
    'metadataOnlyChangesFromValidatedBundle': metadata_changes,
    'weightsUnchangedFromValidatedBundle': True,
    'license': 'BigScience Open RAIL-M (2022-08-18)',
    'modificationNotice': 'licenses/MODIFICATIONS.md',
    'languages': ['en', 'es'], 'voice': 'F1', 'steps': 10,
    'textEditSchedule': reference['textEditSchedule'],
})
files = [p for p in sorted(bundle.rglob('*')) if p.is_file() and p.name != 'manifest.json']
manifest['files'] = [{'path': str(p.relative_to(bundle)), 'bytes': p.stat().st_size,
                      'sha256': digest(p)} for p in files]
write_json(bundle / 'manifest.json', manifest)
assets = args.output / 'assets'
assets.mkdir()
download_files = []
for item in manifest['files']:
    name = item['path'].replace('/', '--')
    shutil.copy2(bundle / item['path'], assets / name)
    download_files.append({'path': item['path'], 'size': item['bytes'], 'sha256': item['sha256'],
        'sourceURL': f'https://github.com/Section9Labs/LibroxTTS/releases/download/{args.release_tag}/{name}'})
shutil.copy2(bundle / 'manifest.json', assets / 'CTCoreMLManifest.json')
write_json(assets / 'download-manifest.json', {'repository': 'Section9Labs/LibroxTTS',
    'revision': args.release_tag, 'files': download_files,
    'installedFiles': [{k: f[k] for k in ('path', 'size', 'sha256')} for f in download_files]})
(assets / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n'
    for p in sorted(assets.iterdir()) if p.is_file()))
print(json.dumps({'files': len(files), 'installedBytes': sum(f['bytes'] for f in manifest['files']),
                  'assets': str(assets), 'metadataOnlyModels': len(metadata_changes)}))
