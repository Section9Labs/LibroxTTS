#!/usr/bin/env python3
"""Pin current Kyutai language snapshots and prepare reproducible GitHub assets.
Run with the pinned upstream checkout and Python environment documented in README.
No weight quantization or acoustic fine-tuning is performed.
"""
import ast
import argparse, concurrent.futures, hashlib, json, pathlib, shutil, urllib.request
import yaml

UPSTREAM = '28770c06f7deb1b65617834e60a6add7a4ff5b6d'
SNAPSHOT = 'a7056f505a4a8ca72d8b5fb1440071d6f1a35739'
REPOSITORY = 'kyutai/pocket-tts-without-voice-cloning'
LANGUAGES = dict(en='english', fr='french', de='german', pt='portuguese', it='italian', es='spanish', nl='dutch')
DEFAULTS = dict(en='alba', fr='estelle', de='alba', pt='alba', it='giovanni', es='lola', nl='daan')
RELEASE = 'pocket-tts-mlx-2026-11-07-v2'
# Explicit allowlist: unknown/new voices must be reviewed before distribution.
# Cosette/Jean are noncommercial; Juergen/Rafael have undocumented source rights.
VOICE_LICENSES = dict.fromkeys(
    'alba anna azelma charles daan eponine eve fantine george jane mary michael paul vera'.split(), 'CC-BY-4.0')
VOICE_LICENSES.update(dict.fromkeys(
    'bill_boerst caro_davy estelle giovanni javert lola marius peter_yearsley stuart_bell'.split(), 'CC0-1.0'))

def voice_credit(name, source):
    license = VOICE_LICENSES[name]
    if '/vctk/' in source:
        credit = 'CSTR VCTK Corpus — Junichi Yamagishi, Christophe Veaux and Kirsten MacDonald'
        evidence = 'https://huggingface.co/kyutai/tts-voices#vctk'
    elif name == 'daan':
        credit = 'CML-TTS Dataset — CEIA, Federal University of Goias; Dutch speaker 11290'
        evidence = 'https://openslr.org/146/'
    elif name in {'giovanni', 'lola'}:
        credit = 'Mozilla Common Voice contributors; source clip identified by Kyutai filename'
        evidence = 'https://www.mozillafoundation.org/en/blog/common-voice-18-dataset-release/'
    elif name == 'alba':
        credit = 'Alba MacKenna — Casual'
        evidence = 'https://huggingface.co/kyutai/tts-voices#alba-mackenna'
    else:
        credit = {'estelle': 'Kyutai / Unmute', 'javert': 'Unmute voice donor Butter',
                  'marius': 'Unmute voice donor Selfie'}.get(name, name.replace('_', ' ').title() + ' — Voice-Zero / LibriVox')
        evidence = 'https://huggingface.co/kyutai/tts-voices'
    return dict(source=source, recordingLicense=license, attribution=credit,
                licenseURL='https://creativecommons.org/' + ('licenses/by/4.0/' if license == 'CC-BY-4.0' else 'publicdomain/zero/1.0/'),
                licenseEvidence=evidence)

def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

def fetch(path, target, expected):
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        tmp=target.with_suffix(target.suffix+'.download')
        urllib.request.urlretrieve(f'https://huggingface.co/{REPOSITORY}/resolve/{SNAPSHOT}/{path}', tmp)
        tmp.rename(target)
    digest=sha(target)
    lfs=expected.get('lfs')
    if target.stat().st_size != expected['size'] or (lfs and digest != lfs['sha256']):
        raise ValueError(f'Upstream content mismatch: {path}')
    if not lfs:
        payload=target.read_bytes()
        if hashlib.sha1(b'blob '+str(len(payload)).encode()+b'\0'+payload).hexdigest()!=expected['blobId']:
            raise ValueError(f'Upstream Git blob mismatch: {path}')
    return target

def main():
    p=argparse.ArgumentParser();p.add_argument('--upstream',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--catalog',type=pathlib.Path,required=True);p.add_argument('--languages',nargs='+',default=list(LANGUAGES));a=p.parse_args()
    import subprocess
    if subprocess.check_output(['git','-C',str(a.upstream),'rev-parse','HEAD'],text=True).strip()!=UPSTREAM: raise ValueError('Upstream revision mismatch')
    meta=json.load(urllib.request.urlopen(f'https://huggingface.co/api/models/{REPOSITORY}/revision/{SNAPSHOT}?blobs=true'))
    metadata={x['rfilename']:x for x in meta['siblings']}
    siblings=list(metadata)
    a.catalog.mkdir(parents=True,exist_ok=True)
    for code in a.languages:
        name=LANGUAGES[code];dest=a.output/code;dest.mkdir(parents=True,exist_ok=True)
        cfg=yaml.safe_load((a.upstream/'pocket_tts/config'/f'{name}.yaml').read_text())
        cfg.update(model_type='pocket_tts',tokenizer_name='tokenizer.json',temp=cfg.get('default_temperature',0.3),lsd_decode_steps=1)
        cfg['mimi']['encoder_enabled']=False
        cfg['mimi']['transformer'].setdefault('max_period',10000.0)
        cfg['flow_lm']['transformer']['gelu']='tanh'
        cfg['mimi']['gelu']='tanh'
        cfg['upstream_revision']=UPSTREAM;cfg['snapshot_revision']=SNAPSHOT;cfg['language']=code
        (dest/'config.json').write_text(json.dumps(cfg,indent=2,ensure_ascii=False)+'\n')
        prefix=f'languages/{name}/'
        selected=[x for x in siblings if x.startswith(prefix) and (x.endswith('model.safetensors') or x.endswith('tokenizer.json') or ('/embeddings/' in x and pathlib.Path(x).stem in VOICE_LICENSES))]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda path:fetch(path,dest/path.removeprefix(prefix),metadata[path]),selected))
        for existing in (dest/'embeddings').glob('*.safetensors'):
            if existing.stem not in VOICE_LICENSES: existing.unlink()
        tree=ast.parse((a.upstream/'pocket_tts/utils/utils.py').read_text())
        origins=next(ast.literal_eval(n.value) for n in tree.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='_ORIGINS_OF_PREDEFINED_VOICES' for t in n.targets))
        if not set(VOICE_LICENSES).issubset(origins): raise ValueError('Missing voice provenance')
        voice_credits={k:voice_credit(k,origins[k]) for k in sorted(VOICE_LICENSES)}
        (dest/'VOICE-CREDITS.json').write_text(json.dumps(voice_credits,indent=2)+'\n')
        notice={'model':'Pocket TTS by Kyutai','modelLicense':'CC-BY-4.0','modelSource':f'https://huggingface.co/{REPOSITORY}/tree/{SNAPSHOT}', 'codeSource':f'https://github.com/kyutai-labs/pocket-tts/tree/{UPSTREAM}', 'modifications':'Original tensors; native Swift MLX layout conversion at load. No fine-tuning.','voicesLicenseSource':'https://huggingface.co/kyutai/tts-voices','voiceSource':'Kyutai supplied language-specific voice states; retain source speaker credits.'}
        (dest/'NOTICE.json').write_text(json.dumps(notice,indent=2)+'\n')
        shutil.copy(a.upstream/'LICENSE',dest/'LICENSE-Kyutai.txt')
        files=[]
        for path in sorted(dest.rglob('*')):
            if not path.is_file():continue
            relative=code+'/'+str(path.relative_to(dest))
            files.append(dict(path=relative,size=path.stat().st_size,sha256=sha(path),sourceURL=f'https://github.com/Section9Labs/LibroxTTS/releases/download/{RELEASE}/'+relative.replace('/','--')))
        manifest=dict(repository='Section9Labs/LibroxTTS',revision=RELEASE,files=files,installedFiles=files)
        (a.catalog/f'{code}.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print(code,len(files),sum(f['size'] for f in files),flush=True)
if __name__=='__main__':main()
