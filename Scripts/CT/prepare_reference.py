#!/usr/bin/env python3
"""Verify frozen research assets, then copy only mobile assets and export raw fixtures.
Never writes to the research bundle. Requires numpy for fixture conversion only.
"""
import argparse, hashlib, json, pathlib, shutil
import numpy as np
p=argparse.ArgumentParser();p.add_argument('bundle',type=pathlib.Path);p.add_argument('fixtures',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args()
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
m=json.loads((a.bundle/'manifest.json').read_text());v=json.loads((a.fixtures/'verification.json').read_text())
assert sha(a.bundle/'manifest.json')==v['bundleManifestSHA256']=='8bbf2b6c453d386b905a3c99f6a77ab9705d26a3b76e09dcf29addf16cea9b62'
a.output.mkdir(parents=True,exist_ok=False)
mobile=[]
for f in m['files']:
    src=a.bundle/f['path'];assert src.stat().st_size==f['bytes'] and sha(src)==f['sha256'],f['path']
    if f['path'].startswith(('onnx/','licenses/')) or f['path']=='voice_styles/F1.json':
        dst=a.output/'CTAssets'/f['path'];dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
        mobile.append({k:f[k] for k in ('path','bytes','sha256')})
manifest={'identity':'librox-plus-ct-f1-v1','referenceManifestSHA256':v['bundleManifestSHA256'],'parameterCount':108425399,'files':mobile}
(a.output/'CTAssets/manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
for c in v['checks']:
    npz=a.fixtures/c['fixtures'];assert sha(npz)==c['fixtureSHA256']
    arrays=np.load(npz);dest=a.output/'Fixtures'/c['id'];dest.mkdir(parents=True)
    layout={}
    for name,arr in arrays.items():
        arr=arr.astype(arr.dtype.newbyteorder('<'));data=arr.tobytes();(dest/(name+'.bin')).write_bytes(data)
        layout[name]={'shape':list(arr.shape),'dtype':str(arr.dtype),'sha256':hashlib.sha256(data).hexdigest()}
    (dest/'layout.json').write_text(json.dumps(layout,indent=2)+'\n')
(a.output/'Fixtures/cases.json').write_text(json.dumps(m['verificationCases'],indent=2)+'\n')
print(json.dumps({'verifiedFiles':len(m['files']),'mobileBytes':sum(f['bytes'] for f in mobile),'fixtures':len(v['checks']),'output':str(a.output)}))
