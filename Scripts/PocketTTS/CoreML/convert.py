#!/usr/bin/env python3
"""Convert Max's pinned original tensors; no quantization, retraining or sampler change."""
import argparse, copy, hashlib, json, pathlib, subprocess, sys
import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
import yaml
from pocket_tts import TTSModel
from vendor.mimi import TraceableMimiDecoder, MIMI_STATE_SPEC

SNAPSHOT = "a7056f505a4a8ca72d8b5fb1440071d6f1a35739"

class Transformer(torch.nn.Module):
    """Growing, non-wrapping KV cache. Same tanh GELU and fp32 math as Max."""
    def __init__(self, flow, kind):
        super().__init__()
        self.flow = flow
        self.kind = kind

    def forward(self, value, position, *caches):
        if self.kind == "text":
            x = self.flow.conditioner.embed(value)
        else:
            x = self.flow.input_linear(value)
        T = x.shape[1]
        P = caches[0].shape[2]
        positions = torch.arange(T, dtype=torch.float32) + position
        freqs = torch.exp(torch.arange(32, dtype=torch.float32) * (-np.log(10000.0) * 2 / 64))
        angles = positions[:, None] * freqs[None, :]
        co, si = angles.cos()[None, :, None, :], angles.sin()[None, :, None, :]
        mask = (torch.arange(P + T)[None, :] <= (position + torch.arange(T))[:, None])
        updated = []
        for i, layer in enumerate(self.flow.transformer.layers):
            qkv = layer.self_attn.in_proj(layer.norm1(x)).reshape(1, T, 3, 16, 64)
            q, k, v = qkv[:, :, 0], qkv[:, :, 1], qkv[:, :, 2]
            def rotate(a):
                pairs = a.reshape(1, T, 16, 32, 2)
                re, im = pairs[..., 0], pairs[..., 1]
                return torch.stack((re * co - im * si, re * si + im * co), -1).reshape(1, T, 16, 64)
            q, k = rotate(q).transpose(1, 2), rotate(k).transpose(1, 2)
            k = torch.cat((caches[2*i], k), dim=2)
            v = torch.cat((caches[2*i+1], v.transpose(1, 2)), dim=2)
            score = (q @ k.transpose(-1, -2)) * 0.125
            score = score.masked_fill(~mask[None, None], -1e9)
            attn = (score.softmax(-1) @ v).transpose(1, 2).reshape(1, T, 1024)
            x = x + layer.self_attn.out_proj(attn)
            x = x + layer.linear2(F.gelu(layer.linear1(layer.norm2(x)), approximate="tanh"))
            updated.extend((k, v))
        out = self.flow.out_norm(x[:, -1:, :])
        return (out, self.flow.out_eos(out), *updated)

class Flow(torch.nn.Module):
    def __init__(self, flow, steps):
        super().__init__(); self.net = flow.flow_net; self.steps = steps
    def forward(self, condition, noise):
        z = noise
        for i in range(self.steps):
            s = torch.tensor([[i / self.steps]], dtype=torch.float32)
            t = torch.tensor([[(i + 1) / self.steps]], dtype=torch.float32)
            z = z + self.net(condition, s, t, z) / self.steps
        return z

class Mimi(torch.nn.Module):
    """Exclude unchanged/empty states from Core ML's external interface."""
    def __init__(self, model):
        super().__init__(); self.decoder = TraceableMimiDecoder.from_tts_model(model)
        self.active = [(i, n, sh) for i, (n, sh) in enumerate(MIMI_STATE_SPEC) if 0 not in sh and not n.endswith('_first')]
    def forward(self, latent, *state):
        full = []
        it = iter(state)
        for n, sh in MIMI_STATE_SPEC:
            full.append(torch.ones(sh) if n.endswith('_first') else torch.zeros(sh) if 0 in sh else next(it))
        result = self.decoder(latent, *full)
        return (result[0], *(result[i+1] for i, _, _ in self.active))

def sha(path):
    with open(path, 'rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser(); p.add_argument('--assets',type=pathlib.Path,required=True); p.add_argument('--output',type=pathlib.Path,required=True)
    p.add_argument('--language',default='en'); p.add_argument('--stages',nargs='+',default=['text','latent','flow4','flow8','mimi']); a=p.parse_args()
    root=a.assets/a.language; out=a.output/a.language; out.mkdir(parents=True,exist_ok=True)
    cfg=json.loads((root/'config.json').read_text()); assert cfg['snapshot_revision']==SNAPSHOT
    catalog=pathlib.Path(__file__).resolve().parents[3]/'Sources/KokoroCatalog/PocketTTS'/f'{a.language}.json'
    for item in json.loads(catalog.read_text())['installedFiles']:
        path=a.assets/item['path']; assert sha(path)==item['sha256'], str(path)
    for key in ['model_type','tokenizer_name','temp','lsd_decode_steps','upstream_revision','snapshot_revision','language']: cfg.pop(key,None)
    cfg['mimi'].pop('encoder_enabled',None); cfg['mimi'].pop('gelu',None); cfg['flow_lm']['transformer'].pop('gelu',None)
    cfg['weights_path']=str(root/'model.safetensors'); cfg['weights_path_without_voice_cloning']=str(root/'model.safetensors')
    cfg['flow_lm']['lookup_table']['tokenizer_path']=str(root/'tokenizer.json')
    config=out/'source.yaml'; config.write_text(yaml.safe_dump(cfg))
    model=TTSModel.load_model(config=config,temp=.3,lsd_decode_steps=4).eval()
    assert len(model.flow_lm.transformer.layers)==6
    assert not cfg.get('conditioners'), 'Additional conditioning requires an explicit conversion'
    torch.set_num_threads(2); torch.manual_seed(42)
    manifest={'schema':1,'snapshot':SNAPSHOT,'weightsSHA256':sha(root/'model.safetensors'),'precision':'float32','gelu':'tanh','sampleRate':24000,'mimiCacheCapacity':512,'stages':{}}
    if (out/'manifest.json').exists(): manifest=json.loads((out/'manifest.json').read_text())
    model.flow_lm.bos_emb.detach().numpy().astype('float32').tofile(out/'bos.bin')
    for stage in a.stages:
        print('CONVERT',stage,flush=True)
        if stage in ('text','latent'):
            wrapper=Transformer(model.flow_lm,stage).eval()
            value=torch.tensor([[1,2,3,4]],dtype=torch.int32) if stage=='text' else torch.randn(1,4,32)
            caches=tuple(torch.randn(1,16,8,64) for _ in range(12)); examples=(value,torch.tensor([8.0]),*caches)
            t=ct.RangeDim(1,512,default=4); past=ct.RangeDim(1,4096,default=8)
            shape=(1,t) if stage=='text' else (1,t,32)
            inputs=[ct.TensorType(name='value',shape=shape,dtype=np.int32 if stage=='text' else np.float32)]
            inputs += [ct.TensorType(name='position',shape=(1,),dtype=np.float32)]
            inputs += [ct.TensorType(name=f'cache{i}',shape=(1,16,past,64),dtype=np.float32) for i in range(12)]
            names=['hidden','eos']+[f'next{i}' for i in range(12)]
        elif stage.startswith('flow'):
            wrapper=Flow(model.flow_lm,int(stage[4:])).eval(); examples=(torch.randn(1,1024),torch.randn(1,32))
            inputs=[ct.TensorType(name=n,shape=tuple(t.shape),dtype=np.float32) for n,t in zip(['condition','noise'],examples)];names=['latent']
        else:
            wrapper=Mimi(copy.deepcopy(model)).eval()
            examples=(torch.randn(1,32),*(torch.zeros(sh) for _,_,sh in wrapper.active))
            inputs=[ct.TensorType(name=n,shape=tuple(t.shape),dtype=np.float32) for n,t in zip(['latent']+[n for _,n,_ in wrapper.active],examples)]
            names=['audio']+[f'next_{n}' for _,n,_ in wrapper.active]
        with torch.no_grad(): traced=torch.jit.trace(wrapper,examples,check_trace=False)
        ml=ct.convert(traced,inputs=inputs,outputs=[ct.TensorType(name=n,dtype=np.float32) for n in names],minimum_deployment_target=ct.target.iOS18,compute_precision=ct.precision.FLOAT32,compute_units=ct.ComputeUnit.CPU_AND_GPU)
        package=out/f'{stage}.mlpackage'; ml.save(str(package))
        feed={inp.name:t.detach().numpy() for inp,t in zip(inputs,examples)}
        got=ml.predict(feed)
        with torch.no_grad(): ref=wrapper(*examples)
        if isinstance(ref,torch.Tensor): ref=(ref,)
        errors={n:float(np.max(np.abs(got[n]-r.numpy()))) for n,r in zip(names,ref)}
        print('PARITY',stage,errors,flush=True)
        assert max(errors.values())<0.003, (stage,errors)
        subprocess.run(['xcrun','coremlc','compile',str(package),str(out)],check=True)
        manifest['stages'][stage]={'errors':errors,'inputs':{i.name:list(t.shape) for i,t in zip(inputs,examples)},'outputs':names}
        (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('COMPLETE',out,flush=True)
if __name__=='__main__': main()
