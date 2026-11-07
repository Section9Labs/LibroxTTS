#!/usr/bin/env python3
"""Upload a new immutable draft, verify GitHub's content digests, then publish.
Never overwrites an existing release or updates the repository's latest release.
"""
import argparse,hashlib,json,pathlib,subprocess,tempfile

def gh(*args):
 return subprocess.check_output(['gh',*args],text=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--assets',type=pathlib.Path,required=True);p.add_argument('--manifests',type=pathlib.Path,required=True);p.add_argument('--commit',required=True);p.add_argument('--notes',type=pathlib.Path,required=True);p.add_argument('--publish',action='store_true');a=p.parse_args()
 repo='Section9Labs/LibroxTTS';tag='pocket-tts-mlx-2026-11-07'
 files=[f for path in sorted(a.manifests.glob('*.json')) for f in json.loads(path.read_text())['files']]
 if len(files)!=len({f['path'] for f in files}):raise ValueError('Duplicate asset paths')
 for f in files:
  source=a.assets/f['path']
  with source.open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
  if source.stat().st_size!=f['size'] or digest!=f['sha256']:raise ValueError(f'Asset mismatch: {source}')
 with tempfile.TemporaryDirectory(prefix='librox-pocket-upload-') as tmp:
  links=[]
  for f in files:
   link=pathlib.Path(tmp)/f['path'].replace('/','--');link.symlink_to((a.assets/f['path']).resolve());links.append(str(link))
  gh('release','create',tag,'--repo',repo,'--target',a.commit,'--draft','--prerelease','--latest=false','--title','Pocket TTS native MLX — seven language packs','--notes-file',str(a.notes))
  try:
   gh('release','upload',tag,*links,'--repo',repo)
   release=json.loads(gh('api',f'repos/{repo}/releases/tags/{tag}'))
   remote={f['name']:f for f in release['assets']}
   for f in files:
    asset=remote[f['path'].replace('/','--')]
    if asset['size']!=f['size'] or asset.get('digest')!='sha256:'+f['sha256']:
     raise ValueError(f"Hosted content not verified: {f['path']}")
   print(f'Verified {len(files)} GitHub asset digests',flush=True)
   if a.publish:gh('release','edit',tag,'--repo',repo,'--draft=false','--prerelease','--latest=false')
  except Exception:
   print('Release remains a draft. Inspect it before retrying; no assets were overwritten.',flush=True)
   raise
 print(gh('release','view',tag,'--repo',repo,'--json','url'))
if __name__=='__main__':main()
