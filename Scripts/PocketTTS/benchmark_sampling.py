#!/usr/bin/env python3
"""Measure sampler computation separately from the listening-generation batch."""
import argparse
import hashlib
import json
import pathlib
import statistics
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--suite', type=pathlib.Path, required=True)
p.add_argument('--probe', type=pathlib.Path, required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
manifest = json.loads((a.suite / 'manifest.json').read_text())
if hashlib.sha256(a.probe.read_bytes()).hexdigest() != manifest['probeSHA256']:
    raise SystemExit('Probe binary differs from the generated suite; rebuild/regenerate or use its exact binary.')
measurements = []
with tempfile.TemporaryDirectory(prefix='librox-pocket-compute-') as temporary:
    directory = pathlib.Path(temporary)
    for repeat in range(3):
        for language, voice in [('en', 'alba'), ('es', 'lola')]:
            for steps in ([8, 4, 2, 1] if repeat % 2 == 0 else [1, 2, 4, 8]):
                row = next(r for r in manifest['samples'] if
                           r['language'] == language and r['voice'] == voice and
                           r['passage'] == 'reflective' and r['policy'] == 'balanced' and
                           r['temperature'] == 0.3 and r['seed'] == 42 and r['samplerSteps'] == steps)
                request = json.loads((a.suite / row['request']).read_text())
                wav = directory / 'trial.wav'
                request['output'] = str(wav)
                request_path = directory / 'request.json'
                request_path.write_text(json.dumps(request))
                result = subprocess.run([str(a.probe.resolve()), '--trial', str(request_path)],
                                        capture_output=True, text=True, check=True, timeout=120)
                metrics = json.loads(result.stdout)
                duration = metrics['samples'] / metrics['sampleRate']
                measurement = dict(language=language, voice=voice, samplerSteps=steps, repeat=repeat,
                                   renderSeconds=metrics['renderSeconds'], audioSeconds=duration,
                                   realTimeFactor=metrics['renderSeconds'] / duration,
                                   audioSHA256=hashlib.sha256(wav.read_bytes()).hexdigest())
                measurements.append(measurement)
                print(json.dumps(measurement), flush=True)
summary = []
for language in ['en', 'es']:
    for steps in [8, 4, 2, 1]:
        rows = [r for r in measurements if r['language'] == language and r['samplerSteps'] == steps]
        median = statistics.median(r['realTimeFactor'] for r in rows)
        summary.append(dict(language=language, samplerSteps=steps, trials=len(rows),
                            medianRenderSeconds=statistics.median(r['renderSeconds'] for r in rows),
                            medianRealTimeFactor=median, medianTimesRealTime=1 / median,
                            identicalRepeatedAudio=len({r['audioSHA256'] for r in rows}) == 1))
report = dict(host=manifest['benchmarkHost'], probeSHA256=manifest['probeSHA256'],
              notes=['Three process-isolated trials per configuration, model load excluded from generation timing.',
                     'Run after synthesis, ASR, builds and tests complete; do not overlap agent GPU workloads.',
                     'Short-sample throughput is not target-device, long-book, thermal or memory qualification.',
                     'No automatic fallback or quality winner is selected from these measurements.'],
              summary=summary, measurements=measurements)
a.output.write_text(json.dumps(report, indent=2) + '\n')
