#!/usr/bin/env python3
import argparse,pathlib,json,hashlib,subprocess,concurrent.futures,time
parser=argparse.ArgumentParser(description="Publish immutable hash-verified Max transport artifacts")
parser.add_argument('--work',type=pathlib.Path,required=True)
parser.add_argument('--commit',required=True)
parser.add_argument('--publish',action='store_true')
a=parser.parse_args()
root=a.work;repo='Section9Labs/LibroxTTS';d=json.loads((root/'PocketTransfers-v1.json').read_text());tag=d['revision'];parts={p['sha256']:p for f in d['files'] for p in f['parts']}
def gh(*args):return subprocess.check_output(['gh',*args],text=True)
for key,p in parts.items():
 file=root/'artifacts'/(key+'.gz')
 with file.open('rb') as h:assert file.stat().st_size==p['size'] and hashlib.file_digest(h,'sha256').hexdigest()==key
existing=subprocess.run(['gh','release','view',tag,'--repo',repo,'--json','isDraft'],capture_output=True,text=True)
if existing.returncode:
 commit=a.commit
 notes=root/'asset-notes.md';notes.write_text('Lossless gzip transport for the existing seven-language Max model and delivery-style packs. Decompression reconstructs original catalog-pinned bytes. Installed model identities, audio and loudness are unchanged. Each chunk reconstructs at most 64 MiB. Used by the additive LibroxTTS 1.1 download API; old raw assets remain available.\n')
 notes.write_text(notes.read_text()+'\nModel attribution: Kyutai Pocket TTS, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), pinned [upstream snapshot](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/tree/a7056f505a4a8ca72d8b5fb1440071d6f1a35739). Original voice contributors, recording licenses and reference-style credits remain in the unchanged language manifests and credit files. Core ML conversion attribution remains in [PROVENANCE.md](https://github.com/Section9Labs/LibroxTTS/blob/v1.0.0/Scripts/PocketTTS/CoreML/vendor/PROVENANCE.md). The only modification in these transport artifacts is reversible gzip compression; model tensors and voice states are unchanged.\n')
 gh('release','create',tag,'--repo',repo,'--target',commit,'--draft','--prerelease','--latest=false','--title','Max lossless download transport v1','--notes-file',str(notes))
release=json.loads(gh('api',json.loads(gh('release','view',tag,'--repo',repo,'--json','apiUrl'))['apiUrl']));assets={a['name']:a for a in release['assets']};pending=[]
for key,p in parts.items():
 name=key+'.gz'
 if name in assets:
  assert assets[name]['size']==p['size'] and assets[name].get('digest')=='sha256:'+key
 else:pending.append(str(root/'artifacts'/name))
assert release['draft'] or not pending,'Never alter a published asset release'
batches=[pending[i:i+20] for i in range(0,len(pending),20)]
def upload(batch):
 subprocess.run(['gh','release','upload',tag,'--repo',repo,*batch],check=True,stdout=subprocess.DEVNULL)
 print('Uploaded',len(batch),'artifacts',flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(upload,batches))
release=json.loads(gh('api',json.loads(gh('release','view',tag,'--repo',repo,'--json','apiUrl'))['apiUrl']));assets={a['name']:a for a in release['assets']}
for key,p in parts.items():assert assets[key+'.gz']['size']==p['size'] and assets[key+'.gz'].get('digest')=='sha256:'+key
(root/'hosted-digests.json').write_text(json.dumps(dict(tag=tag,assets=[dict(name=a['name'],size=a['size'],digest=a.get('digest')) for a in assets.values()]),indent=2)+'\n')
if release['draft'] and a.publish:gh('release','edit',tag,'--repo',repo,'--draft=false','--prerelease','--latest=false')
print('VERIFIED',tag,len(parts),sum(p['size'] for p in parts.values()),flush=True)
