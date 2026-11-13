#!/usr/bin/env python3
"""Run isolated physical-device ABBA matrices and a completed foreground soak."""
import argparse,hashlib,json,plistlib,statistics,subprocess,time,uuid
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--device',required=True);p.add_argument('--baseline-app',type=Path,required=True);p.add_argument('--candidate-app',type=Path,required=True)
p.add_argument('--work',type=Path,required=True);p.add_argument('--soak-seconds',type=int,default=1800)
a=p.parse_args();a.work.mkdir(parents=True,exist_ok=False);prefix=uuid.uuid4().hex[:8]
def bundle(rev):return 'com.section9labs.libroxttsqualification10.'+rev
def command(args):
 return subprocess.run(['xcrun','devicectl','device',*args],capture_output=True,text=True)
def checked(args):
 r=command(args)
 if r.returncode:raise RuntimeError(r.stdout+r.stderr)
 return r
binaries={}
for rev in ['baseline','candidate']:
 app=getattr(a,rev+'_app').resolve();info=plistlib.loads((app/'Info.plist').read_bytes())
 assert info['CFBundleIdentifier']==bundle(rev),'Refusing to replace another application'
 binaries[rev]=hashlib.sha256((app/info['CFBundleExecutable']).read_bytes()).hexdigest()
 checked(['install','app','--device',a.device,str(app),'--timeout','120'])
 print('installed',rev,flush=True)
def launch(rev,label,seconds,fresh):
 args=['process','launch','--device',a.device,'--terminate-existing',bundle(rev),'--label',label,'--seconds',str(seconds)]
 if fresh:args+=['--fresh']
 r=command(args)
 if r.returncode:checked([x for x in args if x!='--terminate-existing'])
 print('started',label,flush=True)
def collect(rev,label,seconds):
 marker=a.work/(label+'-complete.txt');deadline=time.monotonic()+max(300,seconds+300)
 while time.monotonic()<deadline:
  r=command(['copy','from','--device',a.device,'--domain-type','appDataContainer','--domain-identifier',bundle(rev),'--source',f'Documents/{label}/complete.txt','--destination',str(marker),'--timeout','10'])
  if r.returncode==0:break
  time.sleep(10)
 else:raise RuntimeError('Incomplete qualification: '+label)
 assert marker.read_text()=='complete'
 out=a.work/label
 checked(['copy','from','--device',a.device,'--domain-type','appDataContainer','--domain-identifier',bundle(rev),'--source','Documents/'+label,'--destination',str(out),'--timeout','30'])
 return dict(path=str(out),environment=json.loads((out/'environment.json').read_text()),rows=json.loads((out/'report.json').read_text()))
def identity(r):return r['sha256'],r['samples'],r['events']
runs=[]
for kind in ['fresh','warm']:
 reference=None
 for i,rev in enumerate(['baseline','candidate','candidate','baseline']):
  label=f'final-{prefix}-{kind}-{i}-{rev}';duration=0 if kind=='fresh' else 30
  launch(rev,label,duration,kind=='fresh');result=collect(rev,label,duration)
  if kind=='fresh':
   assert len(result['rows'])==12
   values=[identity(r) for r in result['rows']]
  else:
   values=identity(result['rows'][0]);assert all(identity(r)==values for r in result['rows'])
  if reference is None:reference=values
  assert values==reference,'PCM or events differ'
  runs.append(dict(kind=kind,revision=rev,**result))
  (a.work/'progress.json').write_text(json.dumps(dict(binaries=binaries,runs=runs),indent=2)+'\n')
  print('completed',label,flush=True)
label=f'final-{prefix}-candidate-soak';launch('candidate',label,a.soak_seconds,False)
soak=collect('candidate',label,a.soak_seconds)
assert all(identity(r)==reference for r in soak['rows'])
summary={}
for rev in ['baseline','candidate']:
 fresh=[r for r in runs if r['kind']=='fresh' and r['revision']==rev]
 warm=[r for r in runs if r['kind']=='warm' and r['revision']==rev]
 summary[rev]=dict(freshSetupPlusFirstAudioSeconds=statistics.median(r['environment']['setupSeconds']+r['rows'][0]['firstFrameSeconds'] for r in fresh),
  freshSetupSeconds=statistics.median(r['environment']['setupSeconds'] for r in fresh),
  warmPassageMedianSeconds=statistics.median(x['seconds'] for r in warm for x in r['rows'][1:]),
  warmThermalStates=sorted({x['thermal'] for r in warm for x in r['rows'][1:]}))
summary['warmSpeedup']=summary['baseline']['warmPassageMedianSeconds']/summary['candidate']['warmPassageMedianSeconds']
summary['freshColdRatio']=summary['candidate']['freshSetupPlusFirstAudioSeconds']/summary['baseline']['freshSetupPlusFirstAudioSeconds']
report=dict(complete=True,exactPCMAndEvents=True,binaries=binaries,summary=summary,runs=runs,soak=soak,
 limitations=['Single M4 iPad foreground CPU Core ML, English Caro/Calm; no iPhone/background/playback/energy claim',
 'Fresh includes SDK source copy/preparation/compilation; OS/compiler global caches are not purged',
 'Shared thermal history is recorded; two process runs per revision, descriptive medians'])
(a.work/'report.json').write_text(json.dumps(report,indent=2)+'\n');print('complete final device qualification',json.dumps(summary),flush=True)
