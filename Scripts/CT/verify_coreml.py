#!/usr/bin/env python3
"""Compare every converted component and the accumulated CT trajectory to frozen tensors."""
import argparse,json,pathlib,time
import numpy as np,coremltools as ct,onnxruntime as ort
p=argparse.ArgumentParser();p.add_argument('models',type=pathlib.Path);p.add_argument('fixtures',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--hybrid-assets',type=pathlib.Path);p.add_argument('--generator-models',type=pathlib.Path);p.add_argument('--generator-units',choices=['CPU_ONLY','CPU_AND_GPU','CPU_AND_NE','ALL'],default='CPU_ONLY');p.add_argument('--repeats',type=int,default=1);a=p.parse_args()
components=['vector_estimator','vocoder'] if a.hybrid_assets else ['duration_predictor','text_encoder_early','text_encoder','vector_estimator','vocoder']
models={n:ct.models.MLModel(str((a.generator_models if n=='vector_estimator' and a.generator_models else a.models)/(n+'.mlpackage')),compute_units=getattr(ct.ComputeUnit,a.generator_units) if n=='vector_estimator' else ct.ComputeUnit.CPU_ONLY) for n in components}
opts=ort.SessionOptions();opts.intra_op_num_threads=4
reference={n:ort.InferenceSession(str(a.hybrid_assets/'onnx'/(n+'.onnx')),opts,providers=['CPUExecutionProvider']) for n in ['duration_predictor','text_encoder_early','text_encoder']} if a.hybrid_assets else {}
def metrics(x,y):
 assert x.shape==y.shape,(x.shape,y.shape)
 d=x.astype(np.float64)-y.astype(np.float64);return {'maxAbsoluteError':float(abs(d).max()),'rmse':float(np.sqrt(np.mean(d*d))),'snrDB':float(10*np.log10(np.sum(y.astype(np.float64)**2)/np.sum(d*d))) if np.any(d) else 999}
a.output.mkdir(parents=True,exist_ok=False);reports=[]
for repetition in range(a.repeats):
 for case in json.loads((a.fixtures/'cases.json').read_text()):
  folder=a.fixtures/case['id'];layout=json.loads((folder/'layout.json').read_text())
  saved={n:np.fromfile(folder/(n+'.bin'),dtype=v['dtype']).reshape(v['shape']) for n,v in layout.items()}
  def run(n,feed):
   if n in reference:return reference[n].run(None,feed)[0]
   return next(iter(models[n].predict({k:v.astype(np.int32) if v.dtype==np.int64 else v for k,v in feed.items()}).values()))
  start=time.time()
  feed={k:saved[k] for k in ['text_ids','text_mask','style_ttl']}
  actual={'duration':run('duration_predictor',{k:saved[k] for k in ['text_ids','text_mask','style_dp']})}
  actual['text_emb_early']=run('text_encoder_early',feed);actual['text_emb_late']=run('text_encoder',feed)
  latent=saved['initial_latent']
  for step in range(10):
   latent=run('vector_estimator',dict(noisy_latent=latent,text_emb=actual['text_emb_early' if step<3 else 'text_emb_late'],style_ttl=saved['style_ttl'],text_mask=saved['text_mask'],latent_mask=saved['latent_mask'],text_ids=saved['text_ids'],current_step=np.array([step],np.float32),total_step=np.array([10],np.float32)))
   actual['latent_after_step_'+str(step)]=latent
  actual['waveform']=run('vocoder',{'latent':latent}).reshape(-1)
  report={'id':case['id'],'repetition':repetition,'generatorUnits':a.generator_units,'seconds':time.time()-start,'tensors':{n:metrics(v,saved[n]) for n,v in actual.items()}}
  reports.append(report);actual['waveform'].tofile(a.output/(case['id']+'-'+str(repetition)+'.f32'));print(report,flush=True)
(a.output/'parity.json').write_text(json.dumps(reports,indent=2)+'\n')
