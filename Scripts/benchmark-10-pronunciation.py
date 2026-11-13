#!/usr/bin/env python3
"""Warm English pronunciation control, identical probes in ABBA order."""
import argparse,hashlib,json,statistics,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path);p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
for rev in ['baseline','candidate']:
    products=getattr(a,rev).resolve();out=(a.work/rev).resolve();out.mkdir(parents=True,exist_ok=True)
    for bundle in products.glob('LibroxTTS_*.bundle'):
        target=out/bundle.name
        if not target.exists():target.symlink_to(bundle)
    subprocess.run(['swiftc','-O','-I',str(products),str(root/'docs/Pronunciation10.swift'),*[str(products/(m+'.o')) for m in ['KokoroPronunciation','PronunciationEnglish']],'-o',str(out/'pronunciation')],check=True)
runs=[]
for rev in ['baseline','candidate','candidate','baseline']:
    row=json.loads(subprocess.check_output([str((a.work/rev/'pronunciation').resolve())],text=True));row['revision']=rev;runs.append(row)
assert len({r['sha256'] for r in runs})==1
old=statistics.median([runs[0]['seconds'],runs[3]['seconds']]);new=statistics.median([runs[1]['seconds'],runs[2]['seconds']])
a.output.write_text(json.dumps(dict(exact=True,baselineSeconds=old,candidateSeconds=new,speedup=old/new,runs=runs),indent=2)+'\n')
print(old,new,old/new)
