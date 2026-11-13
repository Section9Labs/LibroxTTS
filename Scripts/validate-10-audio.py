#!/usr/bin/env python3
"""Run identical opt-in exact-audio probes against 0.9 and candidate products."""
import argparse, json, os, subprocess, hashlib
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path)
p.add_argument('--coreml-assets',type=Path,required=True);p.add_argument('--mlx-assets',type=Path,required=True)
p.add_argument('--work',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--reuse-baseline',type=Path)
a=p.parse_args();a.work.mkdir(parents=True,exist_ok=False)
rows=[]
for backend in ['coreml','cpu','gpu']:
    for revision in ['baseline','candidate']:
        products=getattr(a,revision).resolve(); out=(a.work/f'{backend}-{revision}').resolve()
        if revision=='baseline' and a.reuse_baseline:
            out.symlink_to((a.reuse_baseline/f'{backend}-baseline').resolve(),target_is_directory=True)
            receipts=[json.loads(f.read_text()) for f in sorted(out.glob('*.json'))]
            assert len(receipts)==26
            rows.append(dict(backend=backend,revision=revision,rows=receipts))
            continue
        env=dict(os.environ,POCKET_METALLIB=str(products/'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'))
        if backend=='coreml':
            test='Release07AudioTests/testPocketPCMAndChunkContractAgainst062'
            env.update(LIBROX_07_POCKET_ASSETS=str(a.coreml_assets.resolve()),LIBROX_07_AUDIO_OUTPUT=str(out))
            if revision=='candidate':env['LIBROX_07_AUDIO_BASELINE']=str((a.work/f'{backend}-baseline').resolve())
        else:
            test='Release10MLXAudioTests/testPrivateExecutionPCMAndEventsAgainst09'
            env.update(LIBROX_10_MLX_ASSETS=str(a.mlx_assets.resolve()),LIBROX_10_BACKEND=backend,LIBROX_10_AUDIO_OUTPUT=str(out))
            if revision=='candidate':env['LIBROX_10_AUDIO_BASELINE']=str((a.work/f'{backend}-baseline').resolve())
        with (a.work/f'{backend}-{revision}.log').open('w') as log:
            subprocess.run(['xcrun','xctest','-XCTest','PocketTTSCoreMLTests.'+test,str(products/'PocketTTSCoreMLTests.xctest')],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        files=sorted(out.glob('*.json')); assert len(files)==26, len(files)
        receipt=[json.loads(f.read_text()) for f in files]
        rows.append(dict(backend=backend,revision=revision,rows=receipt))
        print(backend,revision,len(files),'recordings',flush=True)
        if revision=='candidate':
            for f in out.glob('*.f32'):assert f.read_bytes()==(a.work/f'{backend}-baseline'/f.name).read_bytes(), f
        a.output.write_text(json.dumps(dict(complete=False,runs=rows),indent=2)+'\n')
a.output.write_text(json.dumps(dict(complete=True,exactPCMAndEvents=True,runs=rows,binarySHA256={r:hashlib.sha256((getattr(a,r)/'PocketTTSCoreMLTests.xctest/Contents/MacOS/PocketTTSCoreMLTests').read_bytes()).hexdigest() for r in ['baseline','candidate']}),indent=2)+'\n')
