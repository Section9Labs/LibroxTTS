#!/usr/bin/env python3
"""Paired fixed Caro/Calm Core ML profile; exact WAV bytes and stage receipts."""
import argparse,hashlib,json,os,platform,statistics,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path)
p.add_argument('--assets',type=Path,required=True);p.add_argument('--models',type=Path,required=True)
p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.work.mkdir(parents=True,exist_ok=False)
request=dict(backend='coreml-cpu',language='en',repetitions=3,steps=4,temperature=.3,seed=42,
 text='She rested her hand against the door. For a moment, she could almost hear his voice again. It was the small things she remembered: the way he folded the newspaper, the sound of his keys on the table, and the cup he always left beside the window. She waited. Nobody came.',voiceID='pocket-caro_davy-en-v1',style='calm')
request_path=a.work/'request.json';request_path.write_text(json.dumps(request)+'\n')
runs=[];reference=None
for index,rev in enumerate(['baseline','candidate','candidate','baseline']):
 products=getattr(a,rev).resolve();out=a.work/f'{index}-{rev}'
 env=dict(os.environ,POCKET_METALLIB=str(products/'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'))
 with (a.work/f'{index}-{rev}.log').open('w') as log:
  subprocess.run([str(products/'pocket-backend-benchmark'),str(request_path),str(a.assets.resolve()),str(a.models.resolve()),str(out)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
 report=json.loads((out/'report.json').read_text());assert report['complete'] and len(report['rows'])==4
 wavs=[hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(out.glob('trial-*.wav'))]
 if reference is None:reference=wavs
 assert wavs==reference,'Audio changed'
 stages=[json.loads((out/f'stages-{i}.json').read_text()) for i in range(4)]
 runs.append(dict(revision=rev,report=report,stages=stages,wavSHA256=wavs))
 print(rev,statistics.median(r['renderSeconds'] for r in report['rows'][1:]),flush=True)
summary={}
for rev in ['baseline','candidate']:
 group=[r['report'] for r in runs if r['revision']==rev]
 summary[rev]=dict(warmMedianSeconds=statistics.median(x['renderSeconds'] for r in group for x in r['rows'][1:]),
  firstAudioIncludingLoadSeconds=statistics.median(r['loadSeconds']+r['rows'][0]['firstAudioSeconds'] for r in group),
  peakSampledFootprint=statistics.median(max(x['peakPhysicalFootprintBytes'] for x in r['rows']) for r in group))
summary['warmSpeedup']=summary['baseline']['warmMedianSeconds']/summary['candidate']['warmMedianSeconds']
summary['footprintRatio']=summary['candidate']['peakSampledFootprint']/summary['baseline']['peakSampledFootprint']
a.output.write_text(json.dumps(dict(order='ABBA',exactWAV=True,summary=summary,runs=runs,os=platform.platform(),
 limitations=['Shared Mac; descriptive repeated measurements','External prepared model directory, shared assets verified on load; installed-pack cold startup is measured separately','Three warmed repetitions per process; sampled footprint, not allocation high-water'],
 binarySHA256={r:hashlib.sha256((getattr(a,r)/'pocket-backend-benchmark').read_bytes()).hexdigest() for r in ['baseline','candidate']}),indent=2)+'\n')
