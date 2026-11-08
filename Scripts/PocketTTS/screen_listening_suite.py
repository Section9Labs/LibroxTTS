#!/usr/bin/env python3
"""Screen words, without scoring narration quality; retains raw transcripts for review."""
import argparse, difflib, json, pathlib, re
import mlx_whisper
from listening_suite import page

p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);a=p.parse_args()
root=a.directory.resolve();manifest=json.loads((root/'manifest.json').read_text())
cache=root/'asr';cache.mkdir(exist_ok=True)
for index,row in enumerate(manifest['samples'],1):
    target=cache/f'{row["id"]}.json'
    existing=json.loads(target.read_text()) if target.exists() else None
    if existing and existing.get('audioSHA256')==row['audioSHA256']:
        result=existing
    else:
        text=mlx_whisper.transcribe(str(root/row['audio']),path_or_hf_repo='mlx-community/whisper-large-v3-turbo',language=row['language'],verbose=False)['text']
        expected=re.findall(r'\w+',row['text'].casefold());heard=re.findall(r'\w+',text.casefold())
        differences=[]
        for tag,i,j,k,l in difflib.SequenceMatcher(a=expected,b=heard,autojunk=False).get_opcodes():
            if tag!='equal':differences.append(f'{tag}: [{" ".join(expected[i:j])}] → [{" ".join(heard[k:l])}]')
        result=dict(audioSHA256=row['audioSHA256'],model='mlx-community/whisper-large-v3-turbo',
                    transcript=text,wordsMatch=expected==heard,differences='; '.join(differences))
        target.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    row['asr']=result
    print(f'{index}/{len(manifest["samples"])} {row["id"]}: {"match" if result["wordsMatch"] else result["differences"]}',flush=True)
manifest['screening']={'method':'Whisper large-v3-turbo, case/punctuation-normalized word sequences',
                       'exactMatches':sum(r['asr']['wordsMatch'] for r in manifest['samples']),
                       'total':len(manifest['samples']),
                       'qualification':'ASR mismatches are review flags, not confirmed synthesis errors; exact matches are not narration-quality approval.'}
(root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
page(root)
print(json.dumps(manifest['screening']))
