#!/usr/bin/env python3
"""Write direct WAV comparisons of installed Max delivery presets.

Requires the candidate SDK probe and its bundled, installed style manifests.
Results are listening material, not automatic quality rankings.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess

from export_delivery_styles import STYLES, VOICES
from listening_suite import TEXTS, POLICIES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=pathlib.Path, required=True)
    parser.add_argument('--assets', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--voices', nargs='+', choices=VOICES, default=VOICES)
    parser.add_argument('--styles', nargs='+', choices=['original'] + STYLES,
                        default=['original', 'neutral', 'calm'])
    parser.add_argument('--languages', nargs='+', choices=TEXTS, default=['en'])
    parser.add_argument('--passages', nargs='+', choices=TEXTS['en'], default=list(TEXTS['en']))
    parser.add_argument('--temperature', type=float, default=0.3)
    parser.add_argument('--steps', type=int, choices=range(1, 9), default=4)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    probe_hash = hashlib.sha256(args.probe.read_bytes()).hexdigest()
    rows = []
    for language in args.languages:
        for voice in args.voices:
            for style in args.styles:
                # Always require the actual state; no substitution or placeholder clips.
                state_name = voice if style == 'original' else f'{voice}__{style}'
                state = args.assets / language / 'embeddings' / f'{state_name}.safetensors'
                state_hash = hashlib.sha256(state.read_bytes()).hexdigest()
                for passage, text in TEXTS[language].items():
                    if passage not in args.passages:
                        continue
                    name = f'{language}-{voice}-{style}-{passage}'
                    wav = args.output / (name + '.wav')
                    request = dict(assets=str(args.assets.resolve()), output=str(wav.resolve()),
                        voiceID=f'pocket-{voice}-{language}-v1', text=text,
                        deliveryStyle=style, temperature=args.temperature,
                        samplerSteps=args.steps, seed=42, chunking=POLICIES['balanced'],
                        role='dialogue' if passage == 'dialogue' else 'narration')
                    request_file = args.output / (name + '.request.json')
                    request_file.write_text(json.dumps(request, indent=2, ensure_ascii=False) + '\n')
                    result = subprocess.run([str(args.probe.resolve()), '--trial', str(request_file.resolve())],
                                            capture_output=True, text=True)
                    (args.output / (name + '.log')).write_text(result.stdout + result.stderr)
                    result.check_returncode()
                    if not wav.exists() or wav.stat().st_size < 100:
                        raise RuntimeError(f'Missing audition audio: {name}')
                    rows.append(dict(name=name, wav=str(wav.resolve()), request=request,
                        probeSHA256=probe_hash, stateSHA256=state_hash,
                        audioSHA256=hashlib.sha256(wav.read_bytes()).hexdigest(), listeningAccepted=False))
                    (args.output / 'auditions.json').write_text(json.dumps(rows, indent=2, ensure_ascii=False) + '\n')
                    print(wav, flush=True)


if __name__ == '__main__':
    main()
