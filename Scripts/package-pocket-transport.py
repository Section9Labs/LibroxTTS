#!/usr/bin/env python3
import argparse,pathlib,json,hashlib,zlib,concurrent.futures,subprocess,os,time
parser=argparse.ArgumentParser(description="Build lossless hash-pinned Max transport chunks; never publishes or changes installed manifests")
parser.add_argument('--assets',type=pathlib.Path,required=True)
parser.add_argument('--work',type=pathlib.Path,required=True)
parser.add_argument('--tag',default='pocket-transport-gzip-2026-11-13-v1')
a=parser.parse_args()
repo=pathlib.Path(__file__).resolve().parents[1];out=a.work;source=a.assets;tag=a.tag
out.mkdir(parents=True,exist_ok=True)
(out/'artifacts').mkdir(exist_ok=True);(out/'sources').mkdir(exist_ok=True)
files={f['sha256']:f for p in sorted((repo/'Sources/KokoroCatalog/PocketTTS').glob('*.json')) for f in json.loads(p.read_text())['files'] if f['size']>=65536}
def sha(p):
 with p.open('rb') as h:return hashlib.file_digest(h,'sha256').hexdigest()
def run(f):
 path=source/f['path'];record=out/'artifacts'/(f['sha256']+'.json')
 if record.exists():
  prior=json.loads(record.read_text())
  assert prior['sha256']==f['sha256'] and prior['size']==f['size']
  digest=hashlib.sha256();total=0
  for part in prior['parts']:
   assert part['url'].startswith(f'https://github.com/Section9Labs/LibroxTTS/releases/download/{tag}/')
   packed=out/'artifacts'/(part['sha256']+'.gz')
   assert packed.stat().st_size==part['size'] and sha(packed)==part['sha256']
   raw=zlib.decompress(packed.read_bytes(),31);assert len(raw)==part['decodedSize'];digest.update(raw);total+=len(raw)
  assert digest.hexdigest()==f['sha256'] and total==f['size']
  return prior
 if not path.exists():
  path=out/'sources'/f['sha256']
  if not path.exists():
   tmp=path.with_suffix('.download');subprocess.run(['curl','--fail','--location','--silent','--show-error','--retry','4','--output',str(tmp),f['sourceURL']],check=True);tmp.rename(path)
 assert path.stat().st_size==f['size'] and sha(path)==f['sha256'],f['path']
 parts=[]
 with path.open('rb') as h:
  while raw:=h.read(64*1024*1024):
   c=zlib.compressobj(6,zlib.DEFLATED,31);packed=c.compress(raw)+c.flush();digest=hashlib.sha256(packed).hexdigest();dest=out/'artifacts'/(digest+'.gz')
   assert zlib.decompress(packed,31)==raw
   if not dest.exists():dest.write_bytes(packed)
   parts.append(dict(url=f'https://github.com/Section9Labs/LibroxTTS/releases/download/{tag}/{digest}.gz',size=len(packed),sha256=digest,decodedSize=len(raw),encoding='gzip'))
 row=dict(sha256=f['sha256'],size=f['size'],parts=parts,path=f['path'])
 record.write_text(json.dumps(row));print(f['path'],f['size'],sum(p['size'] for p in parts),flush=True);return row
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:rows=list(pool.map(run,files.values()))
# Keep only beneficial compressed representations. Raw fallback is the legacy manifest.
rows=[r for r in rows if sum(p['size'] for p in r['parts'])<r['size']*0.99]
transport=dict(revision=tag,files=[{k:v for k,v in r.items() if k!='path'} for r in rows]);(out/'PocketTransfers-v1.json').write_text(json.dumps(transport,separators=(',',':'))+'\n');(out/'packaging.json').write_text(json.dumps(rows,indent=2)+'\n');print('COMPLETE',len(rows),'files',sum(len(r['parts']) for r in rows),'parts',flush=True)
