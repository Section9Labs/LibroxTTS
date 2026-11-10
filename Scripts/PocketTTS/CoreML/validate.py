#!/usr/bin/env python3
"""Independent parity against unmodified Kyutai, across dynamic shapes and codec wrap."""
import argparse, copy, json, pathlib
import coremltools as ct
import numpy as np
import torch
from pocket_tts import TTSModel
from pocket_tts.modules.stateful_module import init_states, increment_steps

def main():
    p=argparse.ArgumentParser();p.add_argument('--models',type=pathlib.Path,required=True);p.add_argument('--assets',type=pathlib.Path,required=True);p.add_argument('--language',default='en');a=p.parse_args()
    root=a.models/a.language
    m=TTSModel.load_model(config=root/'source.yaml',temp=.3,lsd_decode_steps=4).eval()
    torch.set_num_threads(2); torch.manual_seed(123)
    voice=m.get_state_for_audio_prompt(a.assets/a.language/'embeddings/caro_davy.safetensors')
    # Give the original linear cache ample capacity without changing its prefix.
    state=init_states(m.flow_lm,1,4096)
    for name,s in voice.items():
        n=int(s['offset'][0]);state[name]['cache'][:,:,:n]=s['cache'][:,:,:n];state[name]['offset']=s['offset'].clone()
    def cache_feed():
        result={}
        for i,layer in enumerate(m.flow_lm.transformer.layers):
            s=layer.self_attn.get_state(state);n=int(s['offset'][0])
            for j in range(2):result[f'cache{2*i+j}']=s['cache'][j,:,:n].permute(0,2,1,3).numpy().copy()
        return result
    text=ct.models.MLModel(str(root/'text.mlpackage'),compute_units=ct.ComputeUnit.CPU_AND_GPU)
    latent=ct.models.MLModel(str(root/'latent.mlpackage'),compute_units=ct.ComputeUnit.CPU_AND_GPU)
    errors=[]
    running=cache_feed()
    with torch.no_grad():
        for kind,T in [('text',17)]+[('latent',1)]*12+[('latent',43),('text',7),('latent',1)]:
            value=torch.randint(0,4000,(1,T),dtype=torch.int32) if kind=='text' else torch.randn(1,T,32)
            feed=dict(running);feed['value']=value.numpy();feed['position']=np.array([running['cache0'].shape[2]],np.float32)
            got=(text if kind=='text' else latent).predict(feed)
            x=m.flow_lm.conditioner.embed(value) if kind=='text' else m.flow_lm.input_linear(value)
            ref=m.flow_lm.out_norm(m.flow_lm.transformer(x,state)[:,-1:])
            increment_steps(m.flow_lm,state,T)
            running={f'cache{i}':got[f'next{i}'].copy() for i in range(12)}
            error=float(np.max(np.abs(ref.numpy()-got['hidden'])))
            errors.append(dict(kind=kind,tokens=T,hiddenMaxError=error))
            print(errors[-1], {n:float(np.max(np.abs(v-running[n]))) for n,v in cache_feed().items()}, flush=True)
            assert error<2e-4,errors[-1]
        # Native, unpatched Mimi reference: full cache vs converted ring cache.
        mimi=ct.models.MLModel(str(root/'mimi.mlpackage'),compute_units=ct.ComputeUnit.CPU_ONLY)
        refstate=init_states(m.mimi,1,2048)
        cstate={i.name:np.zeros(tuple(i.type.multiArrayType.shape),np.float32) for i in mimi.get_spec().description.input if i.name!='latent'}
        pcm_error=0.0
        for frame in range(70):
            z=torch.randn(1,32)*.25
            ref=m.mimi.decode_from_latent((z*m.flow_lm.emb_std+m.flow_lm.emb_mean).unsqueeze(1),refstate)
            increment_steps(m.mimi,refstate,16)
            got=mimi.predict(dict(cstate,latent=z.numpy()))
            cstate={n:got['next_'+n] for n in cstate}
            error=float(np.max(np.abs(ref.numpy()-got['audio'])))
            pcm_error=max(error,pcm_error)
            assert error<2e-4,(frame,error)
    report=dict(transformer=errors,mimiFrames=70,mimiMaxPCMError=pcm_error,passed=True)
    (root/'independent-parity.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
