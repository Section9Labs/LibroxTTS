#!/usr/bin/env python3
import argparse,json,pathlib,subprocess,os
from audition import TEXTS,VOICES
p=argparse.ArgumentParser();p.add_argument('--assets',required=True);p.add_argument('--output',type=pathlib.Path,required=True);p.add_argument('--metallib',required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
results=[]
for language,text in TEXTS.items():
 out=a.output/language
 reference=subprocess.run([os.sys.executable,str(pathlib.Path(__file__).with_name('reference.py')),'--assets',a.assets,'--output',str(out),'--language',language,'--voice',VOICES[language],'--text',text],capture_output=True,text=True)
 (a.output/f'{language}-reference.log').write_text(reference.stdout+reference.stderr)
 if reference.returncode:raise RuntimeError(reference.stderr)
 env=dict(os.environ,POCKET_ASSETS=a.assets,POCKET_REFERENCE=str(out),POCKET_LANGUAGE=language,POCKET_METALLIB=a.metallib)
 test=subprocess.run(['swift','test','--skip-build','--filter','referenceLatents|referenceDecoder'],env=env,capture_output=True,text=True)
 (a.output/f'{language}-swift.log').write_text(test.stdout+test.stderr)
 results.append(dict(language=language,exitCode=test.returncode))
 print(results[-1],flush=True)
(a.output/'results.json').write_text(json.dumps(results,indent=2)+'\n')
if any(r['exitCode'] for r in results):raise SystemExit(1)
