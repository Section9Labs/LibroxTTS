#!/usr/bin/env python3
"""One frozen full-quality Mac narration candidate, finite and fail closed."""
import hashlib,json,math,os,pathlib,shutil,subprocess,sys,time
import owned_process as owner
import native_resources

ROOT=pathlib.Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01')

REQUIRED_SOURCES = ('Experiments/MacNativeAcoustics/native_resources.py', 'Experiments/MacNativeAcoustics/owned_process.py', 'Experiments/MacNativeAcoustics/supervise_narration.py', 'Integrations/Chatterbox/Sources/LibroxChatterbox/BookDirector.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/BookSession.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/CacheIdentity.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/ChatterboxNarrator.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/LookaheadCache.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/NarrationBridge.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/Resources/Chatterbox-Perth-LICENSE.txt', 'Integrations/Chatterbox/Sources/LibroxChatterbox/VoiceCreation.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/VoiceStore.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCLI/main.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AcousticTimings.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AudioIO.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AudioOutput.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/BatchPipeline.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/CanonicalMTLPrefillPacker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ChatterboxCoreMLModel.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ChunkPipeline.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/CondBlockBuilder.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Conditionals.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ConditioningBlockCache.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Constants.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/DecodeStepTimings.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Errors.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/GenerationOptions.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Log.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MLMultiArray+Helpers.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLPrefillAssembler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLT3LMRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLTextTokenizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ModelRepository.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MultilingualPromptBuilder.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/NPYFloat32.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Perceiver.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/PredictionTrap.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/PrefillAssembler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/RuAccentStress.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Sampler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/SpeechEmbedding.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/SynthRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/T3Backend.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/T3LMRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TextChunker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TextTokenizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TokenSynthesizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/VoiceCloner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/VoiceFileValidation.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Watermarker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxExceptionTrap/CBXExceptionTrap.m', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxExceptionTrap/include/CBXExceptionTrap.h', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/Backbone.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/BackboneConfiguration.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/ChatterboxMLXRenderer.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/DenseCache.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/SpeechDecoder.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticCheckpointAsset.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticInventory.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticKeyMapping.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticRuntimeAsset.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/ConformerEncoder.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/FlowMatching.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/HiFTGenerator.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/LICENSE', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticModel.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticProcessLease.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticRuntime.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticSynthesizer.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAudioExport.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/PROVENANCE.md', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticProbe/main.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacNarrationProbe/main.swift', 'Package.resolved', 'Package.swift')
FRONTEND_NAMES = ('tokenizer.json', 'tokenizer_config.json', 'config.json', 'special_tokens_map.json', 'added_tokens.json', 'vocab.json', 'merges.txt', 'speech_emb.npy', 'speech_pos_emb.npy', 'text_emb.npy', 'text_pos_emb.npy', 'spkr_enc_weight.npy', 'spkr_enc_bias.npy', 'emotion_adv_fc_weight.npy', 'perceiver_query.npy', 'perceiver_norm_weight.npy', 'perceiver_norm_bias.npy', 'perceiver_to_q_weight.npy', 'perceiver_to_q_bias.npy', 'perceiver_to_k_weight.npy', 'perceiver_to_k_bias.npy', 'perceiver_to_v_weight.npy', 'perceiver_to_v_bias.npy', 'perceiver_proj_out_weight.npy', 'perceiver_proj_out_bias.npy', 'chat_template.jinja', 'chat_template.json')

def require(value,message):
    if not value:raise ValueError(message)
def read(path,limit):
    with open(path,'rb') as f:
        data=f.read(limit+1);require(len(data)<=limit and not f.read(1),'Oversized input');return data
def digest(path,check=lambda:None):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):check();h.update(b)
    return h.hexdigest()
def write(path,value):
    tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(value,indent=2)+'\n');tmp.replace(path)

def run(manifest_path,sha):
    manifest_path=pathlib.Path(manifest_path).resolve();root=manifest_path.parent
    require(root.parent==ROOT.resolve() and root.name=='native-full-narration-v02','Unowned program')
    receipt=root/'supervisor-result.json';require(not receipt.exists(),'Existing terminal program; no restart')
    result={'state':'failed','owned_child_joined':False,'automatic_restart':False,'quality_approved':False,'cloud_upload_measured':False}
    write(receipt,result);owner.install_signal_handlers()
    started=time.monotonic();child=None;peak=0;next_check=0;host=None
    def guard():
        nonlocal peak,next_check
        owner.check_stop();now=time.monotonic();require(now-started<360,'Whole-program deadline')
        if now>=next_check:
            host();r=native_resources.shared()
            require(r.available_bytes()>=4*1024**3,'Available-memory guard')
            require(shutil.disk_usage(root).free>=2*1024**3,'Storage guard')
            if child is not None and child.poll() is None:
                try:rss=r.rss(child.pid)
                except RuntimeError:
                    require(child.poll() is not None,'Unknown owned child memory')
                else:
                    peak=max(peak,rss);require(rss<=6*1024**3,'Combined Mac renderer RSS guard')
            next_check=now+1
    try:
        host=owner.HostGuard();raw=read(manifest_path,1024*1024)
        require(hashlib.sha256(raw).hexdigest()==sha,'Changed manifest');result['manifest_sha256']=sha;m=json.loads(raw)
        require(m['stage']=='native-full-narration-v02' and m['deadline_seconds']==360 and m['rss_limit_bytes']==6*1024**3,'Wrong declared scope')
        require(m['automatic_restart'] is False and m['scope']=='stock-EN-ES-fullpipeline-no-cloud','Wrong scope')
        sources=m['source_files']
        require(len(sources)==len(REQUIRED_SOURCES),'Incomplete source binding')
        require(len({f['path'] for f in sources})==len(sources),'Duplicate source binding')
        require({str(pathlib.Path(f['path']).resolve().relative_to(root/'source')) for f in sources}==set(REQUIRED_SOURCES),'Wrong explicit source inventory')
        for f in sources:
            path=pathlib.Path(f['path']).resolve();require(path.is_relative_to(root/'source'),'Unowned frozen source')
            require(digest(path,guard)==f['sha256'],'Changed source')
        bypath={pathlib.Path(f['path']).resolve():f['sha256'] for f in sources}
        for f in [pathlib.Path(__file__).resolve(),pathlib.Path(owner.__file__).resolve(),pathlib.Path(native_resources.__file__).resolve()]:
            require(f in bypath and digest(f,guard)==bypath[f],'Unbound running watchdog source')
        binary=pathlib.Path(m['executable']['path']).resolve();config=pathlib.Path(m['configuration']['path']).resolve()
        require(binary.parent==root and config.parent==root,'Unowned executable/config')
        require(digest(binary,guard)==m['executable']['sha256'],'Changed executable')
        config_raw=read(config,65536);require(hashlib.sha256(config_raw).hexdigest()==m['configuration']['sha256'],'Changed configuration')
        c=json.loads(config_raw);require(c['variant']=='native' and c['watermark']=='disabled-1','Wrong candidate/output policy')
        require(c['outputDirectory']==str(root/'output') and not (root/'output').exists(),'Existing output')
        require(SetKeys(c['texts'])=={'en','es'},'Wrong languages')
        require(c['overlap'] is False and c['grouped'] is False,'Unreviewed initial scheduling')
        frontend=m['frontend_assets'];require(set(frontend)==set(FRONTEND_NAMES),'Incomplete frontend binding')
        frontend_root=pathlib.Path(c['modelDirectory']).resolve()
        def verify_frontend():
            for name,expected in frontend.items():
                path=frontend_root/name
                if expected is None:require(not path.exists(),'Optional frontend appeared')
                else:require(path.is_file() and digest(path,guard)==expected,'Changed frontend')
        verify_frontend()
        metal=pathlib.Path(c['metallib']).resolve();require(metal.parent==root and digest(metal,guard)=='282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f','Changed shared runtime')
        with open(root/'stdout.log','xb') as log:
            owner.check_stop()
            child=subprocess.Popen([str(binary),str(config)],stdin=subprocess.DEVNULL,
                stdout=log,stderr=subprocess.STDOUT,start_new_session=True,
                env=dict(os.environ,MLX_ENABLE_TF32='0',CHATTERBOX_SYNTH_SEED='42'))
            # Signal handler only sets a flag; assignment cannot lose ownership.
            owner.check_stop();write(root/'status.json',{'state':'running','pid':child.pid,'scope':m['scope']})
            while child.poll() is None:
                guard()
                try:child.wait(timeout=.1)
                except subprocess.TimeoutExpired:pass
            guard();require(child.returncode==0 and not owner.group_alive(child.pid),'Terminal render or unexpected descendants')
        report_path=root/'output/report.json';report_raw=read(report_path,4*1024**2);r=json.loads(report_raw)
        require(r['state']=='complete' and r['variant']=='native' and r['watermark']=='disabled-1','Incomplete/wrong render')
        require(r['userListeningApproved'] is False and r['cloudUploadMeasured'] is False,'False quality/cloud acceptance')
        require([x['language'] for x in r['results']]==['en','es'],'Missing language output')
        require(r['grouped']==c['grouped'] and r['overlap']==c['overlap'],'Wrong scheduling receipt')
        require(r['decoderWeightsSHA256']=='3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0' and r['acousticCheckpointSHA256']=='e702f2c441e040bd360e59a86c85d462539759d665e41cfd1938adadd74187a3' and r['stockSHA256']=='5fef40319194272ac3ca10f02cd02e69b51ccb587f9b33357901a04605cdb68d','Wrong models')
        verify_frontend()
        exports=[]
        for language in r['results']:
            for key in ['audioSeconds','renderSeconds','completeWarmSeconds','completeWarmRTF','playbackMultiple']:
                require(math.isfinite(language[key]) and language[key]>0,'Invalid timing')
            require(language['text']==c['texts'][language['language']],'Wrong text')
            require(language['passages'] and 0<language['audioSeconds']<=120,'Unbounded/empty audio')
            require(len(language['exports'])==2,'Missing complete export')
            expected={(str(root/'output'/ (language['language']+'.wav')),'WAV-F32'),(str(root/'output'/ (language['language']+'-lossless.m4a')),'ALAC-24bit')}
            require({(e['path'],e['codec']) for e in language['exports']}==expected,'Wrong or duplicate exports')
            for e in language['exports']:
                p=pathlib.Path(e['path']).resolve();require(p.parent==root/'output' and e['frameCountMatches'] is True,'Unverified/unowned export')
                require(p.stat().st_size==e['bytes'] and digest(p,guard)==e['sha256'],'Changed output bytes')
                exports.append(e)
        require(digest(binary,guard)==m['executable']['sha256'] and read(config,65536)==config_raw and read(manifest_path,1024*1024)==raw,'Changed program identity')
        for f in sources:require(digest(f['path'],guard)==f['sha256'],'Changed frozen source after rendering')
        result.update(state='complete_candidate_listening_unapproved',report_sha256=hashlib.sha256(report_raw).hexdigest(),exports=exports)
    except BaseException as e:result.update(state='failed',failure=type(e).__name__+': '+str(e))
    finally:
        if child is not None:
            try:
                owner.terminate_owned(child)
                result['owned_child_joined']=child.poll() is not None and not owner.group_alive(child.pid)
            except BaseException as e:result.update(state='failed',cleanup_failure=str(e))
            result['exit_code']=child.poll()
        result.update(elapsed_seconds=time.monotonic()-started,peak_observed_rss_bytes=peak)
        try:
            write(root/'status.json',{'state':result['state'],'owned_child_joined':result['owned_child_joined'],'automatic_restart':False})
            if result['state']=='complete_candidate_listening_unapproved':
                next_check=0;guard();require(result['owned_child_joined'],'Unjoined render process')
        except BaseException as e:result.update(state='failed',failure='final guard: '+str(e))
        write(receipt,result)
    print(json.dumps(result))
    return 0 if result['state']=='complete_candidate_listening_unapproved' else 1

def SetKeys(value):return set(value) if isinstance(value,dict) else set()
if __name__=='__main__':sys.exit(run(sys.argv[1],sys.argv[2]))
