#!/usr/bin/env python3
"""Measure a component on each backend, with explicit reference error and warmups."""
import argparse,json,pathlib,statistics,time
import coremltools as ct
import numpy as np
p=argparse.ArgumentParser();p.add_argument('models',type=pathlib.Path);p.add_argument('fixtures',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--component',default='vector_estimator');p.add_argument('--units',default='CPU_ONLY,CPU_AND_NE,CPU_AND_GPU');p.add_argument('--fast-prediction',action='store_true');a=p.parse_args()
assert not a.output.exists()
layout=json.loads((a.fixtures/'layout.json').read_text())
def tensor(n):
 s=layout[n];return np.fromfile(a.fixtures/(n+'.bin'),dtype=s['dtype']).reshape(s['shape'])
def metrics(x,y):
 d=x.astype(np.float64)-y.astype(np.float64)
 return {'maxAbsoluteError':float(abs(d).max()),'snrDB':float(10*np.log10(np.sum(y.astype(np.float64)**2)/np.sum(d*d))) if np.any(d) else 999}
reports={}
for backend in a.units.split(','):
 try:
  hints={'reshapeFrequency':ct.ReshapeFrequency.Infrequent,'specializationStrategy':ct.SpecializationStrategy.FastPrediction} if a.fast_prediction else None
  start=time.perf_counter();model=ct.models.MLModel(str(a.models/(a.component+'.mlpackage')),compute_units=getattr(ct.ComputeUnit,backend),optimization_hints=hints);load=time.perf_counter()-start
  capacity=int(model.get_spec().description.metadata.userDefined.get('ct.textCapacity','0'))
  def padded(n,arr):
   if capacity and n in ['text_ids','text_mask','text_emb']:
    return np.pad(arr,[(0,0)]*(arr.ndim-1)+[(0,capacity-arr.shape[-1])])
   return arr
  feed={}
  for inp in model.get_spec().description.input:
   n=inp.name
   if n=='current_step':arr=np.array([0],np.float32)
   elif n=='total_step':arr=np.array([10],np.float32)
   else:arr=tensor({'noisy_latent':'initial_latent','text_emb':'text_emb_early','latent':'latent_after_step_9'}.get(n,n))
   feed[n]=padded(n,arr.astype(np.int32) if arr.dtype==np.int64 else arr)
  expected=tensor({'vector_estimator':'latent_after_step_0','vocoder':'waveform','text_encoder':'text_emb_late','text_encoder_early':'text_emb_early','duration_predictor':'duration'}[a.component])
  timings=[]
  for i in range(7):
   start=time.perf_counter();actual=next(iter(model.predict(feed).values()));timings.append(time.perf_counter()-start)
  row={'loadSeconds':load,'coldPredictionSeconds':timings[0],'warmSeconds':timings[2:],'warmMedianSeconds':statistics.median(timings[2:]),'reference':metrics(actual.reshape(expected.shape),expected)}
  if a.component=='vector_estimator':
   trajectory=[];latent=feed['noisy_latent'];start=time.perf_counter()
   for step in range(10):
    feed.update(noisy_latent=latent,current_step=np.array([step],np.float32),text_emb=padded('text_emb',tensor('text_emb_early' if step<3 else 'text_emb_late')))
    latent=next(iter(model.predict(feed).values()))
    trajectory.append(metrics(latent,tensor('latent_after_step_'+str(step))))
   row['tenStepSeconds']=time.perf_counter()-start;row['trajectory']=trajectory
   np.save(a.output.with_name(a.output.stem+'-'+backend+'-latent.npy'),latent)
  reports[backend]=row
 except Exception as e:reports[backend]={'error':str(e)}
 a.output.write_text(json.dumps({'model':str(a.models),'component':a.component,'fixture':a.fixtures.name,'fastPrediction':a.fast_prediction,'backends':reports},indent=2)+'\n')
 print(backend,json.dumps(reports[backend]),flush=True)
