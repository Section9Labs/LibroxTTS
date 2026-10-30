#!/usr/bin/env python3
"""Tiny compiled MLP live-state/lifetime qualification, no pretrained weights or audio."""
import hashlib,json,os,pathlib,shutil,subprocess,sys,time
import owned_process as owner
import native_resources
ROOT=pathlib.Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01/compiled-decode-mlp-toy-v01')
def digest(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def write(p,d):p.write_text(json.dumps(d,indent=2)+'\n')
def run(expected):
    receipt=ROOT/'supervisor-result.json';assert not receipt.exists()
    result={'state':'failed','owned_child_joined':False,'pretrained_weights_loaded':False,'audio_generated':False,'automatic_restart':False}
    write(receipt,result);owner.install_signal_handlers();began=time.monotonic();child=None
    def guard():
        owner.check_stop()
        if time.monotonic()-began>60:raise RuntimeError('Deadline')
        host();r=native_resources.shared()
        if r.available_bytes()<4*1024**3 or shutil.disk_usage(ROOT).free<2*1024**3:raise RuntimeError('Memory/storage')
        if child is not None and child.poll() is None:
            try:rss=r.rss(child.pid)
            except RuntimeError:
                if child.poll() is None:raise
            else:
                if rss>2*1024**3:raise RuntimeError('RSS')
    try:
        host=owner.HostGuard();m=json.loads((ROOT/'manifest.json').read_text());assert digest(ROOT/'manifest.json')==expected
        assert m['stage']==ROOT.name and not (ROOT/'qualification.json').exists()
        for x in m['files']:guard();assert digest(x['path'])==x['sha256']
        env=dict(os.environ,MLX_ENABLE_TF32='0',CHATTERBOX_TOY_METALLIB=str(ROOT/'default.metallib'),CHATTERBOX_COMPILED_MLP_TEST_REPORT=str(ROOT/'qualification.json'))
        with open(ROOT/'stdout.log','xb') as log:
            child=subprocess.Popen([m['swift'],'test','-c','release','--scratch-path',m['scratch_path'],'--skip-build','--filter','CompiledDecodeMLPTests'],stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,env=env,start_new_session=True,cwd=m['package_root'])
            while child.poll() is None:
                guard()
                try:child.wait(timeout=.25)
                except subprocess.TimeoutExpired:pass
            guard();assert child.returncode==0 and not owner.group_alive(child.pid)
        d=json.loads((ROOT/'qualification.json').read_text());assert d['completed'] is True
        assert all(d[x] is True for x in ['sameBitsBeforeUpdate','sameBitsAfterUpdate','outputChanged','ownerReleased','childReleased'])
        for x in m['files']:guard();assert digest(x['path'])==x['sha256']
        result.update(state='complete_live_weights_and_lifetime',report_sha256=digest(ROOT/'qualification.json'),manifest_sha256=expected)
    except BaseException as error:result.update(failure=type(error).__name__+': '+str(error))
    finally:
        if child is not None:
            try:owner.terminate_owned(child);result['owned_child_joined']=child.poll() is not None and not owner.group_alive(child.pid)
            except BaseException as error:result.update(state='failed',cleanup_failure=str(error))
            result['exit_code']=child.poll()
        if not result['owned_child_joined']:result['state']='failed'
        result['elapsed_seconds']=time.monotonic()-began;write(receipt,result)
    print(json.dumps(result));return 0 if result['state']=='complete_live_weights_and_lifetime' else 1
if __name__=='__main__':sys.exit(run(sys.argv[1]))
