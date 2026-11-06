#!/usr/bin/env python3
"""Test whether fixed shape padding preserves the frozen generator trajectory."""
import argparse, json, pathlib, time
import numpy as np
import onnxruntime as ort
p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--isolate',action='store_true');a=p.parse_args()
root=a.root;output=a.output
assert not output.exists()
opts=ort.SessionOptions();opts.intra_op_num_threads=4
model=ort.InferenceSession(str(root/'CTAssets/onnx/vector_estimator.onnx'),opts,providers=['CPUExecutionProvider'])
def metrics(a,b):
 d=a.astype(np.float64)-b.astype(np.float64)
 return {'maxAbsoluteError':float(abs(d).max()),'snrDB':float(10*np.log10(np.sum(b.astype(np.float64)**2)/np.sum(d*d))) if np.any(d) else 999}
rows=[]
for case in ['en-return-relief','es-return-dread']:
 folder=root/'Fixtures'/case;layout=json.loads((folder/'layout.json').read_text())
 def tensor(n):
  s=layout[n];return np.fromfile(folder/(n+'.bin'),dtype=s['dtype']).reshape(s['shape'])
 shapes=[(256,tensor('initial_latent').shape[-1]),(tensor('text_ids').shape[-1],256)] if a.isolate else [(256,256),(512,448)]
 for textSize,latentSize in shapes:
  def pad(a,n):
   return np.pad(a,[(0,0)]*(a.ndim-1)+[(0,n-a.shape[-1])])
  latent=pad(tensor('initial_latent'),latentSize);text=tensor('text_ids');length=tensor('initial_latent').shape[-1]
  feed={'text_ids':pad(text,textSize),'text_mask':pad(tensor('text_mask'),textSize),'latent_mask':pad(tensor('latent_mask'),latentSize),'style_ttl':tensor('style_ttl'),'total_step':np.array([10],np.float32)}
  steps=[];start=time.perf_counter()
  for step in range(10):
   feed.update(noisy_latent=latent,text_emb=pad(tensor('text_emb_early' if step<3 else 'text_emb_late'),textSize),current_step=np.array([step],np.float32))
   latent=model.run(None,feed)[0]
   steps.append(metrics(latent[...,:length],tensor('latent_after_step_'+str(step))))
  row={'case':case,'shape':[textSize,latentSize],'steps':steps,'seconds':time.perf_counter()-start}
  rows.append(row);print(json.dumps(row),flush=True)
output.write_text(json.dumps(rows,indent=2)+'\n')
