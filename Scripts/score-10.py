#!/usr/bin/env python3
"""Turn completed 1.0 receipts into an explicit goal scorecard; retain missed goals."""
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--evidence',type=Path,default=Path('docs/architecture-10'));a=p.parse_args()
def read(name):return json.loads((a.evidence/name).read_text())
targets=read('targets.json');prep=read('preparation-abba.json');backend=read('backend-abba.json');profile=read('profile-abba.json');audio=read('audio-matrix.json');plus=read('plus-audio.json');basic=read('basic-audio.json')
coreml=read('backend-coreml-final.json') if (a.evidence/'backend-coreml-final.json').exists() else backend
device=read('device-final.json') if (a.evidence/'device-final.json').exists() else None
assert audio['complete'] and audio['exactPCMAndEvents'] and plus['exactPCM'] and backend['exactPCMAndEvents'] and profile['exactWAV'] and basic['exactPCM'] and coreml['exactPCMAndEvents']
if device:assert device['complete'] and device['exactPCMAndEvents']
rows={r['case']:r for r in prep['summary'] if r['probe']=='Planning10'}
long=[rows[x] for x in ['ctPlusV1-case0','ctPlusV1-case1','pocketTTSV1-case0','pocketTTSV1-case1']]
dictionaries=[r for r in prep['summary'] if r['probe']=='Dictionary10'];assert len(dictionaries)==2
cold=next(r for r in coreml['summary'] if r['backend']=='coreml' and r['name']=='cold')['firstAcceptedFrameSeconds']
values={'max-throughput':profile['summary']['warmSpeedup'],
 'cold-first-audio':device['summary']['freshColdRatio'] if device else None,
 'peak-memory':profile['summary']['footprintRatio'],
 'contextual-planning':min(r['speedup'] for r in long),
 'cold-dictionary':min(r['speedup'] for r in dictionaries)}
goals=[]
for target in targets['targets']:
 value=values[target['id']];lower=target['id'] in ['cold-first-audio','peak-memory']
 row=dict(**target,observed=value,status='pending' if value is None else ('met' if (value<=target['goal'] if lower else value>=target['goal']) else 'missed'))
 if target['id']=='cold-first-audio':row['measurementScope']='Fresh physical iPad setup plus first accepted audio; original design requires all preparation. Installed/prepared-pack Mac process startup is supplemental.'
 goals.append(row)
result=dict(baseline=targets['baseline'],goals=goals,
 exactMacRecordings=sum(len(r['rows']) for r in audio['runs'] if r['revision']=='candidate')+len(plus['runs'][1]['rows'])+len(basic['rows']),
 exactMacSamples=sum(x['samples'] for r in audio['runs'] if r['revision']=='candidate' for x in r['rows'])+sum(x['samples'] for x in plus['runs'][1]['rows'])+sum(x['samples'] for x in basic['rows']),
 installedPackMacColdRatio=cold['candidate']/cold['baseline'],
 coreMLTimingReceipt='backend-coreml-final.json' if (a.evidence/'backend-coreml-final.json').exists() else 'backend-abba.json',
 preparationControls=[r for r in prep['summary'] if r['probe']=='Planning10' and r not in long],
 warmPronunciation=read('pronunciation-abba.json'),
 indexedResourceBytes=sum(p.stat().st_size for p in Path('Sources/PronunciationEnglish/Resources').glob('*.lxt')),
 limitations=['Measured workloads only; no universal throughput or memory claim','Shared Mac timing, two process trials per revision; descriptive medians','Cold release goal counts fresh physical-device preparation; installed/prepared-pack Mac process startup is supplemental','Sampled process footprint, not allocation high-water','Goals are unchanged; missing a goal does not permit changing audio or contracts'])
if (a.evidence/'device-qualification.json').exists():result['device']=read('device-qualification.json')['summary']
(a.evidence/'scorecard.json').write_text(json.dumps(result,indent=2)+'\n')
for row in goals:print(row['id'],row['status'],round(row['observed'],3) if row['observed'] is not None else None,'goal',row['goal'])
