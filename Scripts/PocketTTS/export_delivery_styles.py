#!/usr/bin/env python3
"""Prepare pinned Voice-Zero references and model-specific Pocket voice states.

Requires authorized access to kyutai/pocket-tts for export. Never substitutes
another model/encoder or treats TTS 1.6B embeddings as Pocket states. Outputs are
audition candidates; this command does not publish a release or edit the SDK.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import urllib.request

from prepare_assets import LANGUAGES, UPSTREAM, SNAPSHOT, sha

SOURCE = '490cfbee850a6d409076f477c766f567000a79b6'
IDENTITY = 'pocket-delivery-voicezero-490cfbee-v1'
VOICES = ['bill_boerst', 'caro_davy', 'peter_yearsley', 'stuart_bell']
STYLES = ['neutral', 'calm', 'happy', 'sad', 'worried', 'surprised', 'anger',
          'confused', 'enthused', 'excited', 'frustrated', 'shout', 'tired']


def references(output):
    tree = json.load(urllib.request.urlopen(
        f'https://api.github.com/repos/OwenTyme/voice-zero/git/trees/{SOURCE}?recursive=1'))
    entries = {entry['path']: entry for entry in tree['tree']}
    if tree.get('truncated'):
        raise ValueError('Incomplete source inventory')
    paths = ['README.md', 'voices/README.md', 'voices-emotion/README.md', 'LICENSE.md']
    paths += [f'voices-emotion/{voice}/{style}.flac' for voice in VOICES for style in STYLES]
    result = {}
    for path in paths:
        target = output / 'references' / path
        target.parent.mkdir(parents=True, exist_ok=True)
        url = f'https://raw.githubusercontent.com/OwenTyme/voice-zero/{SOURCE}/{path}'
        data = target.read_bytes() if target.exists() else urllib.request.urlopen(url).read()
        blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if blob != entries[path]['sha']:
            raise ValueError(f'Source Git blob mismatch: {path}')
        target.write_bytes(data)
        result[path] = dict(url=url, sha256=sha(target), gitBlob=blob)
    (output / 'references.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def verify_model(model, base_path):
    """Require all shipped inference weights to match the exporting checkpoint."""
    import torch
    from safetensors import safe_open
    from pocket_tts.utils.utils import download_if_necessary
    checkpoint = download_if_necessary(model.config.weights_path)
    with safe_open(str(base_path), framework='pt') as base, safe_open(str(checkpoint), framework='pt') as source:
        source_keys = set(source.keys())
        count = 0
        for key in base.keys():
            # The public preset model intentionally zeros/removes audio prompting.
            if 'speaker_proj_weight' in key or key.startswith(('mimi.encoder.', 'mimi.encoder_transformer.', 'mimi.downsample.')):
                continue
            if key not in source_keys or not torch.equal(base.get_tensor(key), source.get_tensor(key)):
                raise ValueError(f'Export checkpoint does not match shipped model: {key}')
            count += 1
        if count < 100:
            raise ValueError('Incomplete checkpoint comparison')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=pathlib.Path, required=True)
    parser.add_argument('--base-assets', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--languages', nargs='+', choices=LANGUAGES, default=['en'])
    parser.add_argument('--references-only', action='store_true')
    args = parser.parse_args()
    if subprocess.check_output(['git', '-C', str(args.upstream), 'rev-parse', 'HEAD'], text=True).strip() != UPSTREAM:
        raise ValueError('Upstream checkout revision mismatch')
    args.output.mkdir(parents=True, exist_ok=True)
    refs = references(args.output)
    print(f'Verified {len(VOICES) * len(STYLES)} pinned emotional references', flush=True)
    if args.references_only:
        return
    if not args.base_assets:
        parser.error('--base-assets is required for export')
    import pocket_tts
    if pathlib.Path(pocket_tts.__file__).resolve().parent != (args.upstream / 'pocket_tts').resolve():
        raise ValueError('Python must import the pinned upstream checkout')
    from pocket_tts import TTSModel, export_model_state
    from safetensors import safe_open
    import torch
    manifests = args.output / 'manifests'
    manifests.mkdir(exist_ok=True)
    for code in args.languages:
        config = json.loads((args.base_assets / code / 'config.json').read_text())
        if config['snapshot_revision'] != SNAPSHOT or config['upstream_revision'] != UPSTREAM:
            raise ValueError('Base language pack revision mismatch')
        model = TTSModel.load_model(language=LANGUAGES[code])
        if not model.has_voice_cloning:
            raise RuntimeError('Authorized cloning-enabled weights are required; accept Kyutai terms and log in with hf auth login.')
        verify_model(model, args.base_assets / code / 'model.safetensors')
        files, credits = [], {}
        language_dir = args.output / 'assets' / code
        (language_dir / 'embeddings').mkdir(parents=True, exist_ok=True)
        for voice in VOICES:
            for style in STYLES:
                name = f'{voice}__{style}'
                reference = f'voices-emotion/{voice}/{style}.flac'
                target = language_dir / 'embeddings' / (name + '.safetensors')
                with torch.inference_mode():
                    state = model.get_state_for_audio_prompt(args.output / 'references' / reference, truncate=False)
                    export_model_state(state, target)
                with safe_open(str(target), framework='pt') as exported:
                    for layer in range(config['flow_lm']['transformer']['num_layers']):
                        prefix = f'transformer.layers.{layer}.self_attn/'
                        offset = exported.get_tensor(prefix + 'offset').item()
                        cache = exported.get_tensor(prefix + 'cache')
                        if not (0 < offset <= 512 and offset <= cache.shape[2]) or not torch.isfinite(cache[:, :, :offset]).all():
                            raise ValueError(f'Invalid exported state: {name}, layer {layer}')
                credits[name] = dict(voice=voice, style=style, source=refs[reference], sourceLicense='CC0-1.0',
                    modelLicense='CC-BY-4.0', synthetic=True,
                    processing='Voice-Zero Chatterbox emotional variant, Resemble Enhance; encoded with pinned Kyutai Pocket TTS',
                    basePack='pocket-tts-mlx-2026-11-07-v2', upstreamRevision=UPSTREAM,
                    checkpoint=str(model.config.weights_path), listeningAccepted=False)
                files.append(target)
                print(code, name, flush=True)
        notice = language_dir / 'DELIVERY-CREDITS.json'
        notice.write_text(json.dumps(credits, indent=2) + '\n')
        files.append(notice)
        for relative in ['README.md', 'voices/README.md', 'voices-emotion/README.md', 'LICENSE.md']:
            target = language_dir / ('DELIVERY-SOURCE-' + relative.replace('/', '-'))
            target.write_bytes((args.output / 'references' / relative).read_bytes())
            files.append(target)
        entries = []
        for path in files:
            relative = path.relative_to(args.output / 'assets').as_posix()
            entries.append(dict(path=relative, size=path.stat().st_size, sha256=sha(path),
                sourceURL=f'https://github.com/Section9Labs/LibroxTTS/releases/download/{IDENTITY}/' + relative.replace('/', '--')))
        (manifests / f'delivery-{code}.json').write_text(json.dumps(dict(repository='Section9Labs/LibroxTTS',
            revision=IDENTITY, files=entries, installedFiles=entries), indent=2) + '\n')
        del model
    print('Candidate exports only. Audition before copying manifests into the SDK and publishing.', flush=True)


if __name__ == '__main__':
    main()
