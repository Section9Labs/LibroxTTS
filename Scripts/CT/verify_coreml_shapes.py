#!/usr/bin/env python3
"""Dynamic-shape component checks, separate from listener-reviewed speech fixtures."""
import argparse,json,pathlib
import numpy as np,onnxruntime as ort,coremltools as ct
p=argparse.ArgumentParser();p.add_argument('assets',type=pathlib.Path);p.add_argument('models',type=pathlib.Path);p.add_argument('fixtures',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args()
opts=ort.SessionOptions();opts.intra_op_num_threads=4
layout=json.loads((a.fixtures/'layout.json').read_text())
def tensor(n):return np.fromfile(a.fixtures/(n+'.bin'),dtype=layout[n]['dtype']).reshape(layout[n]['shape'])
rng=np.random.default_rng(1234);reports=[]
for name in ['vector_estimator','vocoder']:
 ml=ct.models.MLModel(str(a.models/(name+'.mlpackage')),compute_units=ct.ComputeUnit.CPU_ONLY)
 reference=ort.InferenceSession(str(a.assets/'onnx'/(name+'.onnx')),opts,providers=['CPUExecutionProvider'])
 for textLength,latentLength in [(32,16),(64,48),(128,96),(199,200),(280,300),(512,431)]:
  latent=rng.standard_normal((1,144,latentLength)).astype(np.float32)
  if name=='vocoder':feed={'latent':latent}
  else:feed={'noisy_latent':latent,'text_emb':rng.standard_normal((1,256,textLength)).astype(np.float32)*.3,
   'text_ids':np.resize(tensor('text_ids'),(1,textLength)),'text_mask':np.ones((1,1,textLength),np.float32),
   'latent_mask':np.ones((1,1,latentLength),np.float32),'style_ttl':tensor('style_ttl'),
   'current_step':np.array([2],np.float32),'total_step':np.array([10],np.float32)}
  expected=reference.run(None,feed)[0]
  output=next(iter(ml.predict({k:v.astype(np.int32) if v.dtype==np.int64 else v for k,v in feed.items()}).values()))
  assert output.shape==expected.shape,(name,output.shape,expected.shape)
  error=output.astype(np.float64)-expected.astype(np.float64)
  snr=float(10*np.log10(np.sum(expected.astype(np.float64)**2)/np.sum(error**2)))
  row={'component':name,'textLength':textLength,'latentLength':latentLength,'maxAbsoluteError':float(abs(error).max()),'snrDB':snr};reports.append(row);print(row,flush=True)
  assert np.isfinite(output).all() and snr>80,row
 assert len(reports)>0
assert not a.output.exists()
a.output.write_text(json.dumps(reports,indent=2)+'\n')
