#!/usr/bin/env python3
"""Finite CPU constructor inventory. No forward, GPU run or automatic restart."""
import hashlib,json,os,pathlib,re,shutil,signal,subprocess,sys,time
import owned_process as owner
import native_resources

ROOT=pathlib.Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01')
CHECKPOINT=pathlib.Path('/Volumes/T9.2025/LibroxTraining/models/chatterbox-multilingual-v3-mlx-evaluation-v01/model.safetensors')
SHA='e702f2c441e040bd360e59a86c85d462539759d665e41cfd1938adadd74187a3'
REQUIRED={'Package.swift','Package.resolved','AcousticInventory.swift','AcousticKeyMapping.swift',
          'FlowMatching.swift','HiFTGenerator.swift','ConformerEncoder.swift','PROVENANCE.md','LICENSE',
          'main.swift','supervise_inventory.py','owned_process.py','native_resources.py'}

def require(value,message):
    if not value:raise ValueError(message)

def digest(path,check=lambda:None):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):check();h.update(b)
    return h.hexdigest()

def capped_read(path,maximum):
    with open(path,'rb') as f:
        data=f.read(maximum+1)
        require(len(data)<=maximum and f.read(1)==b'','Oversized bounded input')
        return data

def write(path,value):
    tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(value,indent=2)+'\n');tmp.replace(path)

def available_bytes():
    return native_resources.shared().available_bytes()

def launch_owned(command,*,factory=subprocess.Popen,**kwargs):
    owner.check_stop();child=None
    try:
        child=factory(command,**kwargs)
        owner.check_stop()
        return child
    except BaseException:
        if child is not None:owner.terminate_owned(child)
        raise

def run(manifest_path,expected_sha):
    manifest_path=pathlib.Path(manifest_path).resolve();root=manifest_path.parent
    require(root.parent==ROOT.resolve() and root.name=='native-swift-acoustic-inventory-v02','Unowned stage')
    result_file=root/'supervisor-result.json'
    require(not result_file.exists(),'Terminal run exists; no restart')
    # Failure status exists before preflight or any child creation. Never leave a
    # successful receipt on parse/hash/cleanup/signal/resource failures.
    result={'state':'failed','automatic_restart':False,'owned_child_joined':False,
            'model_forwards':0,'rendering_or_quality_qualified':False}
    write(result_file,result)
    owner.install_signal_handlers()
    started=time.monotonic();child=None;peak=0;failure=None;code=None
    host=None;next_guard=0.0
    def guard_stage():
        nonlocal peak,next_guard
        owner.check_stop();now=time.monotonic()
        require(now-started<180,'Stage deadline')
        if now>=next_guard:
            host();require(shutil.disk_usage(root).free>=2*1024**3,'Storage guard')
            require(available_bytes()>=4*1024**3,'Available memory guard')
            if child is not None and child.poll() is None:
                try:
                    rss=native_resources.shared().rss(child.pid)
                    peak=max(peak,rss);require(rss<=3*1024**3,'Owned RSS guard')
                except RuntimeError:
                    require(child.poll() is not None,'Cannot query owned child RSS')
            next_guard=now+1
    try:
        host=owner.HostGuard()
        raw=capped_read(manifest_path,1_048_576)
        require(hashlib.sha256(raw).hexdigest()==expected_sha,'Changed consumed manifest')
        result['manifest_sha256']=expected_sha;m=json.loads(raw)
        require(m['stage']=='native-swift-acoustic-inventory-v02' and m['model_forwards_allowed']==0,'Wrong stage')
        require(m['deadline_seconds']==180 and m['cleanup_seconds']==2 and m['rss_limit_bytes']==3*1024**3,'Wrong guard bounds')
        require(m['checkpoint_sha256']==SHA and pathlib.Path(m['checkpoint']).resolve()==CHECKPOINT,'Wrong checkpoint')
        require(m['meanflow'] is False and m['automatic_restart'] is False,'Wrong acoustic/restart policy')
        require(m['constructor_noise_evaluations']==1,'Unbound constructor CPU noise evaluation')
        require(not (root/'report.json').exists(),'Existing child report; no restart')
        names=[pathlib.Path(f['path']).name for f in m['source_files']]
        require(set(names)==REQUIRED and len(names)==len(REQUIRED),'Incomplete/duplicate required source inventory')
        for f in m['source_files']:
            path=pathlib.Path(f['path']).resolve()
            require(path.parent==root/'source','Unowned source binding')
            require(digest(path,guard_stage)==f['sha256'],'Changed source')
        source_index={pathlib.Path(f['path']).name:f['sha256'] for f in m['source_files']}
        require(digest(__file__,guard_stage)==source_index['supervise_inventory.py'],'Wrong running supervisor')
        require(digest(owner.__file__,guard_stage)==source_index['owned_process.py'],'Wrong running lifecycle helper')
        require(digest(native_resources.__file__,guard_stage)==source_index['native_resources.py'],'Wrong running resource helper')
        binary=pathlib.Path(m['executable']['path']).resolve()
        require(binary.parent==root and digest(binary,guard_stage)==m['executable']['sha256'],'Changed/unowned binary')
        guard_stage()
        with open(root/'stdout.log','xb') as log:
            child=launch_owned([str(binary),str(CHECKPOINT),str(root/'report.json')],
                env=dict(os.environ,MLX_ENABLE_TF32='0'),stdin=subprocess.DEVNULL,
                stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            write(root/'status.json',{'state':'running','owned_pid':child.pid,'deadline_seconds':180})
            while child.poll() is None:
                guard_stage()
                try:child.wait(timeout=.1)
                except subprocess.TimeoutExpired:pass
            code=child.returncode;guard_stage()
            require(code==0 and not owner.group_alive(child.pid),'Terminal child or unexpected descendants')
        result['owned_child_joined']=True
        data=capped_read(root/'report.json',8*1024**2);r=json.loads(data)
        require(r['state']=='INVENTORY_MATCH_NO_FORWARD_CLEARANCE' and not r['errors'],'Rejected inventory')
        require(r['checkpointSHA256']==SHA and r['rawTensorCount']==2487,'Wrong child source/count')
        require(r['modelForwards']==0 and r['checkpointLoadedIntoModel'] is False and r['renderingQualified'] is False,'Wrong execution scope')
        require(r['constructorNoiseEvaluations']==1 and r['cpuModelConstructions']==1,'Wrong constructor scope')
        require(digest(binary,guard_stage)==m['executable']['sha256'],'Changed binary after child')
        for f in m['source_files']:require(digest(f['path'],guard_stage)==f['sha256'],'Changed source after child')
        require(capped_read(manifest_path,1_048_576)==raw,'Changed manifest after child')
        next_guard=0;guard_stage()
        result.update(state='inventory_complete_no_forward_clearance',report_sha256=hashlib.sha256(data).hexdigest(),source_binary_unchanged=True)
    except BaseException as e:
        failure=type(e).__name__+': '+str(e)
        result['state']='failed';result['failure']=failure
    finally:
        if child is not None:
            try:
                owner.terminate_owned(child)
                result['owned_child_joined']=child.poll() is not None and not owner.group_alive(child.pid)
            except BaseException as e:
                result['state']='failed';result['cleanup_failure']=type(e).__name__+': '+str(e)
            code=child.poll()
        result.update(exit_code=code,elapsed_seconds=time.monotonic()-started,peak_observed_rss_bytes=peak)
        try:
            write(root/'status.json',{'state':result['state'],'owned_child_joined':result['owned_child_joined'],'automatic_restart':False})
            if result['state']=='inventory_complete_no_forward_clearance':
                next_guard=0;guard_stage()
                require(result['owned_child_joined'],'Child not joined before acceptance')
        except BaseException as e:
            result['state']='failed';result['failure']='final status/guard: '+type(e).__name__+': '+str(e)
        # The authoritative receipt is the LAST durable publication. No fallible
        # status write follows it. The initialized failure survives write failure.
        write(result_file,result)
    print(json.dumps(result))
    return 0 if result['state']=='inventory_complete_no_forward_clearance' else 1

if __name__=='__main__':sys.exit(run(sys.argv[1],sys.argv[2]))
