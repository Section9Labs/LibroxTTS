#!/usr/bin/env python3
"""Export a reviewable release index; applications must use the SDK manifest APIs."""
import argparse, copy, json, pathlib

LANGUAGES = ['en', 'fr', 'de', 'pt', 'it', 'es', 'nl']

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--version', required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    a = p.parse_args()
    catalog = pathlib.Path(__file__).resolve().parents[2] / 'Sources/KokoroCatalog/PocketTTS'
    result = dict(schema=1, sdkVersion=a.version,
        note='Integration receipt only. Use SDK manifests for install, validation and platform selection.',
        platformBackend={'iOS': 'coreML', 'macOS': 'mlx', 'macCatalyst': 'mlx'},
        defaultMax=dict(voice='caro_davy', style='calm', temperature=0.3, samplerSteps=4, chunking='carefulReading'),
        languages={})
    for lang in LANGUAGES:
        mlx = json.loads((catalog / f'{lang}.json').read_text())
        graphs = json.loads((catalog / f'coreml-{lang}.json').read_text())
        styles = json.loads((catalog / f'delivery-{lang}.json').read_text())
        core = copy.deepcopy(graphs)
        for key in ['files', 'installedFiles']:
            shared = [f for f in mlx[key] if not f['path'].endswith('/model.safetensors')]
            core[key] = shared + graphs[key]
        entries = {}
        for name, base in [('mlx', mlx), ('coreML', core)]:
            narrator = copy.deepcopy(base)
            narrator['revision'] += ':' + styles['revision']
            for key in ['files', 'installedFiles']:
                narrator[key] += [f for f in styles[key] if '/embeddings/' not in f['path'] or f['path'].endswith('/caro_davy__calm.safetensors')]
            entries[name] = dict(base=base, defaultNarrator=narrator,
                baseDownloadBytes=sum(f['size'] for f in base['files']),
                defaultNarratorDownloadBytes=sum(f['size'] for f in narrator['files']))
        entries['optionalDelivery'] = styles
        result['languages'][lang] = entries
        assert not any(f['path'].endswith('/model.safetensors') for f in core['files'])
        assert any(f['path'].endswith('/model.safetensors') for f in mlx['files'])
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(result, indent=2) + '\n')
    print(a.output)

if __name__ == '__main__':
    main()
