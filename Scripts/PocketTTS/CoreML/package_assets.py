#!/usr/bin/env python3
"""Stage portable, hash-pinned Core ML-only packs. Does not publish assets.
Shared assets retain their original immutable URLs; no MLX model weights are copied.
"""
import argparse, hashlib, json, pathlib, shutil

IDENTITY = 'pocket-tts-coreml-2026-11-10-v1'
STAGES = ['text', 'latent', 'flow4', 'flow8', 'flowstep', 'mimi']

def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--assets', type=pathlib.Path, required=True)
    p.add_argument('--models', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--languages', nargs='+', default=['en', 'fr', 'de', 'pt', 'it', 'es', 'nl'])
    a = p.parse_args()
    catalog = pathlib.Path(__file__).resolve().parents[3] / 'Sources/KokoroCatalog/PocketTTS'
    # A fresh staging root is mandatory; never mutate an existing installation.
    a.output.mkdir(parents=True, exist_ok=False)
    receipts = []
    for lang in a.languages:
        original = json.loads((catalog / f'{lang}.json').read_text())
        root = a.models / lang
        manifest = json.loads((root / 'manifest.json').read_text())
        weights = next(f for f in original['installedFiles'] if f['path'] == f'{lang}/model.safetensors')
        assert manifest['weightsSHA256'] == weights['sha256']
        assert manifest['precision'] == 'float32' and manifest['gelu'] == 'tanh'
        assert set(STAGES) <= set(manifest['stages'])
        assert (root / 'independent-parity.json').exists(), f'Validate {lang} first'
        shared = [f for f in original['installedFiles'] if f['path'] != weights['path']]
        for f in shared:
            src = a.assets / f['path']
            assert src.stat().st_size == f['size'] and sha(src) == f['sha256']
            dst = a.output / f['path']; dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        target = a.output / lang / 'coreml'; target.mkdir(parents=True)
        for stage in STAGES:
            shutil.copytree(root / f'{stage}.mlpackage', target / f'{stage}.mlpackage')
        for name in ['bos.bin', 'manifest.json']:
            shutil.copy2(root / name, target / name)
        files = []
        for path in sorted(target.rglob('*')):
            if path.is_file():
                relative = path.relative_to(a.output).as_posix()
                files.append(dict(path=relative, size=path.stat().st_size, sha256=sha(path),
                    sourceURL=f'https://github.com/Section9Labs/LibroxTTS/releases/download/{IDENTITY}/' + relative.replace('/', '--')))
        pack = dict(repository='Section9Labs/LibroxTTS', revision=IDENTITY, files=files, installedFiles=files)
        (catalog / f'coreml-{lang}.json').write_text(json.dumps(pack, indent=2) + '\n')
        receipts.append(dict(language=lang, sharedBytes=sum(f['size'] for f in shared),
                             coreMLBytes=sum(f['size'] for f in files), originalWeightBytes=weights['size'],
                             originalWeightsIncluded=False, independentParity=json.loads((root / 'independent-parity.json').read_text())))
    (a.output / 'packaging-receipt.json').write_text(json.dumps(receipts, indent=2) + '\n')
    print(json.dumps([{k:v for k,v in r.items() if k != 'independentParity'} for r in receipts], indent=2))

if __name__ == '__main__':
    main()
