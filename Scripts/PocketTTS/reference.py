#!/usr/bin/env python3
"""Produce deterministic CPU reference audio/token/chunk fixtures from pinned Kyutai."""
import argparse,json,pathlib,time,yaml
import numpy as np
import scipy.io.wavfile
from pocket_tts import TTSModel
from pocket_tts.models.text_chunking import split_into_best_sentences,prepare_text_prompt
from safetensors.torch import save_file

p=argparse.ArgumentParser();p.add_argument('--assets',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--language',default='en');p.add_argument('--voice',default='alba');p.add_argument('--text',default='The library was quiet. Beyond the window, rain drifted through the evening light.');a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
cfg=json.loads((a.assets/a.language/'config.json').read_text())
for key in ['model_type','tokenizer_name','temp','lsd_decode_steps','upstream_revision','snapshot_revision','language']:cfg.pop(key,None)
cfg['mimi'].pop('encoder_enabled',None)
cfg['mimi'].pop('gelu',None)
cfg['flow_lm']['transformer'].pop('gelu',None)
cfg['weights_path']=str(a.assets/a.language/'model.safetensors')
cfg['flow_lm']['lookup_table']['tokenizer_path']=str(a.assets/a.language/'tokenizer.json')
config_file=a.output/'reference.yaml';config_file.write_text(yaml.safe_dump(cfg))
model=TTSModel.load_model(config=config_file,temp=0)
voice=model.get_state_for_audio_prompt(a.assets/a.language/'embeddings'/f'{a.voice}.safetensors')
trace={};step=[0]
model.max_decoder_frames_per_call=1
decode=model.mimi.decode_from_latent
decode_step=[0]
def record_decode(latent,state):
    audio=decode(latent,state)
    i=decode_step[0];decode_step[0]+=1
    if i<16:
        trace[f'decoder_latent_{i}']=latent.detach().clone().contiguous()
        trace[f'decoder_audio_{i}']=audio.detach().clone().contiguous()
    return audio
model.mimi.decode_from_latent=record_decode
def record(module,inputs,output):
 i=step[0];step[0]+=1
 if i<16:
  trace[f'latent_{i}']=output[0].detach().contiguous();trace[f'eos_{i}']=output[1].detach().contiguous()
hook=model.flow_lm.register_forward_hook(record)
t=time.monotonic();audio=model.generate_audio(voice,a.text,teacher_force_previous_chunk=True)
scipy.io.wavfile.write(a.output/'reference.wav',model.sample_rate,audio.numpy())
save_file(trace,a.output/'trace.safetensors')
report={'voice':a.voice,'text':a.text,'tokens':model.flow_lm.conditioner.tokenizer.encode(a.text),'chunks':split_into_best_sentences(model.flow_lm.conditioner.tokenizer,a.text,25,False,cfg.get('remove_semicolons',False),replace_characters=cfg.get('replace_characters')),'sample_count':audio.numel(),'seconds':time.monotonic()-t}
(a.output/'reference.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print(report)
