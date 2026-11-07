#!/usr/bin/env python3
"""ASR content screen. This is not native-listener or prosody acceptance."""
import argparse,json,pathlib
import mlx_whisper
p=argparse.ArgumentParser();p.add_argument('directory',type=pathlib.Path);a=p.parse_args()
report=[]
for row in json.loads((a.directory/'report.json').read_text()):
 if row['exitCode']:continue
 code=row['language'];result=mlx_whisper.transcribe(str(a.directory/f'{code}.wav'),path_or_hf_repo='mlx-community/whisper-large-v3-turbo',language=code,verbose=False)
 report.append(dict(language=code,expected=row['text'],transcript=result['text']));print(report[-1],flush=True)
(a.directory/'asr.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
