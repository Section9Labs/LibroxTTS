#!/usr/bin/env python3
"""Run the 0.9 sidecar XCTest in ABBA order; require exact PCM and event records."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline_products', type=Path)
p.add_argument('candidate_products', type=Path)
p.add_argument('--coreml-assets', type=Path, required=True)
p.add_argument('--mlx-assets', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--backends', nargs='+', default=['coreml','cpu','gpu'], choices=['coreml','cpu','gpu'])
a = p.parse_args()
a.work.mkdir(parents=True, exist_ok=False)
runs = []
for backend in a.backends:
    baseline = None
    for index, revision in enumerate(['baseline','candidate','candidate','baseline']):
        products = getattr(a, revision+'_products').resolve()
        destination = a.work / f'{backend}-{index}-{revision}'
        env = dict(os.environ, LIBROX_09_BACKEND=backend, LIBROX_09_ASSETS=str((a.coreml_assets if backend=='coreml' else a.mlx_assets).resolve()),
                   LIBROX_09_OUTPUT=str(destination.resolve()), POCKET_METALLIB=str(products/'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'))
        if baseline: env['LIBROX_09_BASELINE'] = str(baseline.resolve())
        with (a.work/f'{backend}-{index}.log').open('w') as log:
            subprocess.run(['xcrun','xctest','-XCTest','PocketTTSCoreMLTests.Release09BenchmarkTests',str(products/'PocketTTSCoreMLTests.xctest')],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        rows = json.loads((destination/'report.json').read_text())
        assert [r['name'] for r in rows] == ['cold','preview','warm-0','warm-1','book','voice-switch','language-switch','slow-receiver']
        if baseline:
            old = json.loads((baseline/'report.json').read_text())
            for x,y in zip(old,rows):
                assert (x['name'],x['samples'],x['sha256'],x['events']) == (y['name'],y['samples'],y['sha256'],y['events'])
        else: baseline = destination
        runs.append(dict(backend=backend,revision=revision,rows=rows))
        print(f'{backend} {revision} {sum(r["wallSeconds"] for r in rows):.3f}s',flush=True)
summary = []
for backend in a.backends:
    group = [r for r in runs if r['backend']==backend]
    for name in [r['name'] for r in group[0]['rows']]:
        metrics = {}
        for field in ['wallSeconds','firstAcceptedFrameSeconds','frameServiceP50','frameServiceP95','sampledPeakFootprint']:
            vals = {rev: statistics.median([next(row[field] for row in run['rows'] if row['name']==name) for run in group if run['revision']==rev]) for rev in ['baseline','candidate']}
            metrics[field] = vals
        metrics['wallSpeedup'] = metrics['wallSeconds']['baseline']/metrics['wallSeconds']['candidate']
        summary.append(dict(backend=backend,name=name,**metrics))
report = dict(order='ABBA per backend',exactPCMAndEvents=True,runs=runs,summary=summary,
              machine=platform.machine(),os=platform.platform(),
              binarySHA256={rev:hashlib.sha256((getattr(a,rev+'_products')/'PocketTTSCoreMLTests.xctest/Contents/MacOS/PocketTTSCoreMLTests').read_bytes()).hexdigest() for rev in ['baseline','candidate']},
              limitations=['Shared Mac, two process runs per revision per backend; descriptive measurements, not a statistical performance guarantee',
                           'Sampled process footprint is not allocation high-water or system-wide Core ML memory',
                           'Short fixed excerpts; no long-form listening, physical-device, energy or sustained thermal qualification'])
a.output.write_text(json.dumps(report,indent=2)+'\n')
