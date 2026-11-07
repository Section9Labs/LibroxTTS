#!/usr/bin/env python3
"""Generate a controlled, resumable PocketTTS listening suite and offline review page."""
import argparse, hashlib, json, pathlib, subprocess, time

TEXTS = {
    'en': {
        'reflective': 'She rested her hand against the door. For a moment, she could almost hear his voice again. It was the small things she remembered: the way he folded the newspaper, the sound of his keys on the table, and the cup he always left beside the window. She waited. Nobody came.',
        'descriptive': 'By seven in the morning, the market was already awake. A baker lifted warm loaves from a wooden tray, and somewhere behind the stalls a radio played softly. The air smelled of oranges and rain. Across the square, a little girl counted three silver coins before choosing the largest apple she could find.',
        'dialogue': '“You came back,” she said. “I thought you had forgotten.” He put the old photograph on the table. “I tried to forget. But every road brought me here.” For a while, neither of them spoke. Then she pulled out the chair beside her. “Sit down,” she said. “There is still time.”',
    },
    'es': {
        'reflective': 'Apoyó la mano en la puerta. Por un momento, le pareció escuchar de nuevo su voz. Recordaba las cosas pequeñas: cómo doblaba el periódico, el sonido de sus llaves sobre la mesa y la taza que siempre dejaba junto a la ventana. Esperó en silencio. Nadie vino.',
        'descriptive': 'A las siete de la mañana, el mercado ya estaba despierto. Un panadero sacaba hogazas calientes de una bandeja de madera, y detrás de los puestos sonaba una radio. El aire olía a naranjas y a lluvia. Al otro lado de la plaza, una niña contó tres monedas antes de elegir la manzana más grande.',
        'dialogue': '«Has vuelto», dijo ella. «Pensé que te habías olvidado». Él dejó la vieja fotografía sobre la mesa. «Intenté olvidar. Pero todos los caminos me traían aquí». Durante un rato, ninguno de los dos habló. Entonces ella acercó la silla que tenía al lado. «Siéntate», dijo. «Todavía estamos a tiempo».',
    },
}
VOICES = {'en': ['alba', 'jane', 'vera', 'george', 'peter_yearsley', 'stuart_bell'],
          'es': ['lola', 'alba', 'jane', 'george']}
ANCHORS = {'en': ['alba', 'george'], 'es': ['lola', 'alba']}
POLICIES = {
    'short': dict(narrationTargetTokens=24, dialogueTargetTokens=16, shortSentenceTokens=0),
    'balanced': dict(narrationTargetTokens=48, dialogueTargetTokens=32, shortSentenceTokens=12),
    'flow': dict(narrationTargetTokens=72, dialogueTargetTokens=48, shortSentenceTokens=12),
}
for policy in POLICIES.values():
    policy.update(grouping='adaptive', maximumTokens=96, maximumUnitScalars=2400)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def page(output):
    data = (output / 'manifest.json').read_text().replace('<', '\\u003c')
    template = pathlib.Path(__file__).with_name('listening_suite.html').read_text()
    (output / 'index.html').write_text(template.replace('__SUITE_DATA__', data))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', type=pathlib.Path)
    parser.add_argument('--assets', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--page-only', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    if args.page_only:
        page(output)
        return
    if not args.probe or not args.assets:
        parser.error('--probe and --assets are required for generation')
    probe, assets = args.probe.resolve(), args.assets.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'audio').mkdir(exist_ok=True)
    (output / 'requests').mkdir(exist_ok=True)
    (output / 'metrics').mkdir(exist_ok=True)
    binary_hash = sha(probe)
    rows = []
    for language, voices in VOICES.items():
        for voice in voices:
            variants = [('balanced', 0.3, 1, 42, ['voices'])]
            if voice in ANCHORS[language]:
                variants[0][-1].extend(['temperature', 'phrasing', 'steps', 'repeat'])
                variants += [('balanced', temp, 1, 42, ['temperature']) for temp in [0.15, 0.45]]
                variants += [(policy, 0.3, 1, 42, ['phrasing']) for policy in ['short', 'flow']]
                variants += [('balanced', 0.3, steps, 42, ['steps']) for steps in [2, 4]]
                variants += [('balanced', 0.3, 1, 77, ['repeat'])]
            for policy, temperature, steps, seed, rounds in variants:
                for passage, text in TEXTS[language].items():
                    if seed == 77 and passage != 'reflective':
                        continue
                    clip_id = f'{language}-{voice}-{passage}-{policy}-t{temperature}-s{steps}-seed{seed}'
                    role = 'dialogue' if passage == 'dialogue' else 'narration'
                    request = dict(assets=str(assets), output=str(output/'audio'/f'{clip_id}.wav'),
                                   voiceID=f'pocket-{voice}-{language}-v1', text=text,
                                   temperature=temperature, samplerSteps=steps, seed=seed,
                                   chunking=POLICIES[policy], role=role)
                    request_path = output/'requests'/f'{clip_id}.json'
                    request_bytes = (json.dumps(request, indent=2, ensure_ascii=False)+'\n').encode()
                    fingerprint = hashlib.sha256(request_bytes + binary_hash.encode()).hexdigest()
                    request_path.write_bytes(request_bytes)
                    metrics_path = output/'metrics'/f'{clip_id}.json'
                    row = dict(id=clip_id, language=language, voice=voice, passage=passage,
                               policy=policy, temperature=temperature, samplerSteps=steps, seed=seed,
                               rounds=rounds, text=text, role=role, chunking=POLICIES[policy],
                               audio=f'audio/{clip_id}.wav', request=f'requests/{clip_id}.json')
                    audio_path = output/row['audio']
                    cached = json.loads(metrics_path.read_text()) if metrics_path.exists() else None
                    if cached and cached.get('fingerprint') == fingerprint and audio_path.exists() and cached.get('audioSHA256') == sha(audio_path):
                        metrics = cached
                    else:
                        started = time.monotonic()
                        result = subprocess.run([str(probe), '--trial', str(request_path)], capture_output=True, text=True)
                        if result.returncode:
                            raise RuntimeError(f'{clip_id}: {result.stderr[-3000:]}')
                        metrics = json.loads(result.stdout)
                        metrics.update(fingerprint=fingerprint, audioSHA256=sha(audio_path),
                                       processSeconds=time.monotonic()-started)
                        metrics_path.write_text(json.dumps(metrics, indent=2, ensure_ascii=False)+'\n')
                    row.update(metrics)
                    row['duration'] = metrics['samples']/metrics['sampleRate']
                    rows.append(row)
                    print(f'{len(rows):3}: {clip_id}  {row["duration"]:.2f}s / {len(row["chunks"])} chunks', flush=True)
    manifest = dict(title='PocketTTS narrator auditions', version=1,
                    assetRelease='pocket-tts-mlx-2026-11-07', probeSHA256=binary_hash,
                    baseCommit=subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
                    sourceDiffSHA256=hashlib.sha256(subprocess.check_output(['git','diff','HEAD'])).hexdigest(),
                    generated=time.strftime('%Y-%m-%dT%H:%M:%S%z'), samples=rows,
                    notes=['Single-narrator readings, including quoted dialogue; this suite does not test multi-character casting.',
                           'All comparison takes use seed 42; repeat takes use seed 77. Seed equality does not guarantee identical noise alignment after chunk boundaries change.',
                           'Sampler steps affect direct engine auditions; the shared renderer still defaults to one step.',
                           'No pitch, compression, loudness normalization, speed change or weight edits.',
                           'ASR is a screening aid; listen to verify words and narration quality. No winning configuration is automatically selected.'])
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False)+'\n')
    page(output)
    print(f'Generated {len(rows)} clips, {sum(r["duration"] for r in rows)/60:.1f} minutes: {output/"index.html"}')


if __name__ == '__main__':
    main()
