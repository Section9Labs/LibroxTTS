#!/usr/bin/env python3
"""Stage a new v2 bundle only after every exact latent length passes reference checks."""
import argparse, hashlib, json, pathlib, shutil
p=argparse.ArgumentParser()
p.add_argument('baseline',type=pathlib.Path);p.add_argument('generator',type=pathlib.Path)
p.add_argument('report',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args()
assert not a.output.exists()
checks=json.loads(a.report.read_text())
assert {r['latentLength'] for r in checks} == set(range(1,432)) and len(checks)==431
assert all(r['snrDB']>80 and r['maxAbsoluteError']<.001 for r in checks)
original=json.loads((a.baseline/'manifest.json').read_text())
def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as stream:
        for b in iter(lambda:stream.read(1_048_576),b''):h.update(b)
    return h.hexdigest()
for item in original['files']:
    path=a.baseline/item['path'];assert path.stat().st_size==item['bytes'] and digest(path)==item['sha256']
shutil.copytree(a.baseline,a.output)
target=a.output/'coreml/vector_estimator.mlpackage';shutil.rmtree(target);shutil.copytree(a.generator,target)
(a.output/'manifest.json').unlink()
files=[{'path':str(f.relative_to(a.output)),'bytes':f.stat().st_size,'sha256':digest(f)}
       for f in sorted(a.output.rglob('*')) if f.is_file()]
manifest={**original,'identity':'librox-plus-ct-f1-coremlgpu-v2','files':files}
(a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'identity':manifest['identity'],'files':len(files),'bytes':sum(f['bytes'] for f in files)}))
