#!/usr/bin/env python3
"""Build identical preparation probes against two product directories; run ABBA."""
import argparse, hashlib, json, os, platform, statistics, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path)
p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.work.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parents[1]
for rev in ['baseline','candidate']:
    products=getattr(a,rev).resolve(); out=a.work/rev;out.mkdir(exist_ok=True)
    for bundle in products.glob('LibroxTTS_*.bundle'):
        target=out/bundle.name
        if not target.exists():target.symlink_to(bundle)
    for probe,modules in [('Dictionary10',['PronunciationEnglish']),('Planning10',['KokoroNarration','KokoroPronunciation','PronunciationEnglish','KokoroCatalog','LibroxCTNative'])]:
        subprocess.run(['swiftc','-O','-I',str(products),str(root/'docs'/f'{probe}.swift'),*[str(products/(m+'.o')) for m in modules],'-o',str(out/probe)],check=True)
runs=[]
for rev in ['baseline','candidate','candidate','baseline']:
    for probe in ['Dictionary10','Planning10']:
        rows=json.loads(subprocess.check_output([str((a.work/rev/probe).resolve())],text=True))
        runs.append(dict(revision=rev,probe=probe,rows=rows))
        print(rev,probe,flush=True)
summary=[]
for probe in ['Dictionary10','Planning10']:
    group=[r for r in runs if r['probe']==probe]
    for i in range(len(group[0]['rows'])):
        rows=[r['rows'][i] for r in group]
        if probe=='Planning10':
            assert len({(r['model'],r['planSHA256'],r['units']) for r in rows})==1, rows
        else:assert len({r['probe'] for r in rows})==1
        field='coldSeconds' if probe=='Dictionary10' else 'medianSeconds'
        old=statistics.median([rows[0][field],rows[3][field]])
        new=statistics.median([rows[1][field],rows[2][field]])
        summary.append(dict(probe=probe,case=rows[0].get('model',str(rows[0].get('british'))),baselineSeconds=old,candidateSeconds=new,speedup=old/new))
        print(summary[-1],flush=True)
a.output.write_text(json.dumps(dict(order='ABBA',runs=runs,summary=summary,os=platform.platform(),binarySHA256={r:{p:hashlib.sha256((a.work/r/p).read_bytes()).hexdigest() for p in ['Dictionary10','Planning10']} for r in ['baseline','candidate']}),indent=2)+'\n')
