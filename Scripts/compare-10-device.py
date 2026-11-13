#!/usr/bin/env python3
"""Validate completed iPad fixtures and summarize sustained memory separately from speed."""
import argparse,json,statistics
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline-qualification',type=Path,required=True)
p.add_argument('--candidate-qualification',type=Path,required=True)
p.add_argument('--baseline-soak',type=Path,required=True)
p.add_argument('--candidate-soak',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args()
def read(path):
 assert (path/'complete.txt').read_text()=='complete',path
 return dict(environment=json.loads((path/'environment.json').read_text()),rows=json.loads((path/'report.json').read_text()))
old,new=read(a.baseline_qualification),read(a.candidate_qualification)
assert len(old['rows'])==len(new['rows'])==12
for x,y in zip(old['rows'],new['rows']):assert (x['name'],x['sha256'],x['samples'],x['events'])==(y['name'],y['sha256'],y['samples'],y['events'])
baseline,candidate=read(a.baseline_soak),read(a.candidate_soak)
reference=baseline['rows'][0]
for run in [baseline,candidate]:
 assert run['rows']
 for r in run['rows']:assert (r['sha256'],r['samples'],r['events'])==(reference['sha256'],reference['samples'],reference['events'])
count=len(baseline['rows']);matched=candidate['rows'][:count];assert len(matched)==count
peak=lambda rows:max(r['footprint'] for r in rows)
thermal=lambda rows:{str(n):sum(r['thermal']==n for r in rows) for n in sorted({r['thermal'] for r in rows})}
summary=dict(exactPCMAndEvents=True,qualificationSamples=sum(r['samples'] for r in old['rows']),
 baselineRenders=count,candidateRenders=len(candidate['rows']),candidateRenderSeconds=sum(r['seconds'] for r in candidate['rows']),
 baselinePeakBytes=peak(baseline['rows']),candidateMatchedCountPeakBytes=peak(matched),candidateFullSoakPeakBytes=peak(candidate['rows']),
 matchedCountFootprintRatio=peak(matched)/peak(baseline['rows']),candidateFinalHalfMinimumBytes=min(r['footprint'] for r in candidate['rows'][len(candidate['rows'])//2:]),
 candidateFinalHalfMaximumBytes=peak(candidate['rows'][len(candidate['rows'])//2:]),
 baselineThermal=thermal(baseline['rows']),candidateThermal=thermal(candidate['rows']))
a.output.write_text(json.dumps(dict(summary=summary,qualification=dict(baseline=old,candidate=new),soak=dict(baseline=baseline,candidate=candidate),
 limitations=['One physical M4 iPad, foreground CPU Core ML, English Caro/Calm, four steps; no iPhone qualification',
 'Baseline and candidate soak lengths and thermal histories differ: memory and repeated-audio evidence, not a paired throughput comparison',
 'No audio playback, background/lock test, battery/energy measurement or human listening acceptance',
 'Sampled process footprint, not allocation high-water']),indent=2)+'\n')
print(json.dumps(summary,indent=2))
