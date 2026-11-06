#!/usr/bin/env python3
"""Screen all 431 exact latent lengths against ONNX, including text/mask edges.
One step for every length plus full frozen trajectories in the native probe.
This checks mathematical parity, not listener acceptance or hardware counters.
"""
import argparse, gc, json, pathlib, time
import numpy as np
import coremltools as ct
import onnxruntime as ort

p=argparse.ArgumentParser()
p.add_argument('source',type=pathlib.Path)
p.add_argument('model',type=pathlib.Path)
p.add_argument('fixtures',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
p.add_argument('--minimum-length', type=int, default=1)
p.add_argument('--short-functions',action='store_true')
a=p.parse_args()
assert not a.output.exists()
opts=ort.SessionOptions();opts.intra_op_num_threads=4
reference=ort.InferenceSession(str(a.source),opts,providers=['CPUExecutionProvider'])
layout=json.loads((a.fixtures/'layout.json').read_text())
def tensor(n):
    s=layout[n];return np.fromfile(a.fixtures/(n+'.bin'),dtype=s['dtype']).reshape(s['shape'])
rng=np.random.default_rng(6192026)
rows=[]
groups = ([(n,n) for n in range(1,16)] + [(16,128)] if a.short_functions else [(1,128)]) + [(129,256),(257,384),(385,431)]
for lo,hi in groups:
    if hi < a.minimum_length: continue
    start=time.perf_counter()
    name = f'latent_{lo}' if lo == hi else f'latent_{lo}_{hi}'
    model=ct.models.MLModel(str(a.model),function_name=name,compute_units=ct.ComputeUnit.CPU_AND_GPU)
    print('loaded',lo,hi,time.perf_counter()-start,flush=True)
    for length in range(max(lo,a.minimum_length),hi+1):
        textLength=[8,17,32,63,127,192,199,256,280,511,512][(length-1)%11]
        textMask=np.ones((1,1,textLength),np.float32)
        if length%3==0:textMask[...,-min(3,textLength-1):]=0
        feed={'noisy_latent':rng.standard_normal((1,144,length)).astype(np.float32),
            'text_emb':rng.standard_normal((1,256,textLength)).astype(np.float32)*.3,
            'text_ids':np.resize(tensor('text_ids'),(1,textLength)),
            'text_mask':textMask,'latent_mask':np.ones((1,1,length),np.float32),
            'style_ttl':tensor('style_ttl'),'current_step':np.array([length%10],np.float32),
            'total_step':np.array([10],np.float32)}
        expected=reference.run(None,feed)[0]
        padded={k:np.pad(v,[(0,0)]*(v.ndim-1)+[(0,512-textLength)])
                if k in ['text_ids','text_mask','text_emb'] else v for k,v in feed.items()}
        start=time.perf_counter()
        actual=next(iter(model.predict({k:v.astype(np.int32) if v.dtype==np.int64 else v for k,v in padded.items()}).values()))
        elapsed=time.perf_counter()-start
        assert actual.shape==expected.shape
        d=actual.astype(np.float64)-expected.astype(np.float64)
        snr=float(10*np.log10(np.sum(expected.astype(np.float64)**2)/np.sum(d*d))) if np.any(d) else 999
        row={'latentLength':length,'textLength':textLength,'masked':length%3==0,
             'snrDB':snr,'maxAbsoluteError':float(abs(d).max()),'firstShapeSeconds':elapsed}
        rows.append(row)
        a.output.write_text(json.dumps(rows,indent=2)+'\n')
        assert np.isfinite(actual).all() and snr>80 and row['maxAbsoluteError']<.001,row
        if length%16==0 or length==hi:print(row,flush=True)
    del model;gc.collect()
print('PASS',len(rows),'minimum SNR',min(r['snrDB'] for r in rows),flush=True)
