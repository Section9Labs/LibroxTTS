#!/usr/bin/env python3
"""Numeric Standard decoder profile; no acoustic model or exported audio."""
import hashlib,json,math,os,pathlib,shutil,struct,subprocess,sys,time
import owned_process as owner
import native_resources
ROOT=pathlib.Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01')
REQUIRED_SOURCES=('Experiments/MacNativeAcoustics/native_resources.py', 'Experiments/MacNativeAcoustics/owned_process.py', 'Experiments/MacNativeAcoustics/supervise_book_expression.py', 'Experiments/MacNativeAcoustics/supervise_decoder_profile.py', 'Experiments/MacNativeAcoustics/supervise_narration.py', 'Experiments/MacNativeAcoustics/supervise_resident_controls.py', 'Integrations/Chatterbox/Sources/LibroxChatterbox/BookDirector.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/BookSession.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/CacheIdentity.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/ChatterboxNarrator.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/LookaheadCache.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/NarrationBridge.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/PerformanceDirections.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/Resources/Chatterbox-Perth-LICENSE.txt', 'Integrations/Chatterbox/Sources/LibroxChatterbox/VoiceCreation.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/VoiceStore.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCLI/main.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AcousticTimings.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AudioIO.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AudioOutput.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/BatchPipeline.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/CanonicalMTLPrefillPacker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ChatterboxCoreMLModel.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ChunkPipeline.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/CondBlockBuilder.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Conditionals.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ConditioningBlockCache.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Constants.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/DecodeStepTimings.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Errors.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/GenerationOptions.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Log.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MLMultiArray+Helpers.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLPrefillAssembler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLT3LMRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLTextTokenizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ModelRepository.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MultilingualPromptBuilder.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/NPYFloat32.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Perceiver.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/PredictionTrap.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/PrefillAssembler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/RuAccentStress.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Sampler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/SpeechEmbedding.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/SynthRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/T3Backend.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/T3LMRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TextChunker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TextTokenizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TokenSynthesizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/VoiceCloner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/VoiceFileValidation.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Watermarker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxExceptionTrap/CBXExceptionTrap.m', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxExceptionTrap/include/CBXExceptionTrap.h', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/Backbone.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/BackboneConfiguration.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/ChatterboxMLXRenderer.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/DenseCache.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/SpeechDecoder.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticCheckpointAsset.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticInventory.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticKeyMapping.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticRuntimeAsset.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/ConformerEncoder.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/FlowMatching.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/HiFTGenerator.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/LICENSE', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticModel.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticProcessLease.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticRuntime.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticSynthesizer.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAudioExport.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/PROVENANCE.md', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticProbe/main.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacNarrationProbe/CodecBenchmark.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacNarrationProbe/DecodeProfileBenchmark.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacNarrationProbe/main.swift', 'Package.resolved', 'Package.swift', 'Sources/KokoroNarration/BookNarrationContext.swift', 'Sources/KokoroNarration/BookNarrationPlanner.swift', 'Sources/KokoroNarration/BookNarrationUnit+TextNative.swift', 'Sources/KokoroNarration/ConversationCadence.swift', 'Sources/KokoroNarration/DialogueTiming.swift', 'Sources/KokoroNarration/EnhancedNarrationDelivery.swift', 'Sources/KokoroNarration/NarrationDelivery.swift', 'Sources/KokoroNarration/NarrationDeliveryOptions.swift', 'Sources/KokoroNarration/NarrationExpression.swift', 'Sources/KokoroNarration/NarrationExpressionLexicon.swift', 'Sources/KokoroNarration/NarrationMood.swift', 'Sources/KokoroNarration/NarrationPerformance.swift', 'Sources/KokoroNarration/NarrationProfile.swift', 'Sources/KokoroNarration/SpanishFinalVocative.swift', 'Sources/KokoroNarration/StageDialogueStructure.swift', 'Sources/KokoroPronunciation/AsianPhonemizers.swift', 'Sources/KokoroPronunciation/BookVoiceCast.swift', 'Sources/KokoroPronunciation/CharacterContext.swift', 'Sources/KokoroPronunciation/EnglishIslandLexicon.swift', 'Sources/KokoroPronunciation/ForeignLatinSpelling.swift', 'Sources/KokoroPronunciation/InternationalNames.swift', 'Sources/KokoroPronunciation/JapaneseMappedLexicon.swift', 'Sources/KokoroPronunciation/LoanwordReadings.swift', 'Sources/KokoroPronunciation/MixedLanguage.swift', 'Sources/KokoroPronunciation/MultilingualLexicon.swift', 'Sources/KokoroPronunciation/NarrationPlanner.swift', 'Sources/KokoroPronunciation/NarrativeText.swift', 'Sources/KokoroPronunciation/NumberReadings.swift', 'Sources/KokoroPronunciation/Pronunciation.swift', 'Sources/KokoroPronunciation/Resources/ENGLISH-ISLANDS-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/UNIDIC-BSD.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/UNIDIC-COPYING.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/UNIDIC-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/japanese-unidic-manifest.json', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/japanese-unidic.dat', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/japanese-unidic.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/CC-BY-SA-4.0.txt', 'Sources/KokoroPronunciation/Resources/Multilingual/MULTILINGUAL-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-419.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-419.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-419.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-AR.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-AR.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-AR.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-fr.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-fr.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-fr.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-hi.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-hi.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-hi.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-it.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-it.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-it.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-pt-BR.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-pt-BR.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-pt-BR.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-zh.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-zh.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-zh.json', 'Sources/KokoroPronunciation/Resources/README.txt', 'Sources/KokoroPronunciation/Resources/Romance/FRENCH-DATA-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/Romance/IPA-DICT-LICENSE.txt', 'Sources/KokoroPronunciation/Resources/Romance/french-ipa.tsv', 'Sources/KokoroPronunciation/Resources/english-islands.json', 'Sources/KokoroPronunciation/RomanceLexicon.swift', 'Sources/KokoroPronunciation/RomancePhonemizers.swift', 'Sources/KokoroPronunciation/SpanishLexicon.swift', 'Sources/KokoroPronunciation/SpanishPhonemizer.swift', 'Sources/KokoroPronunciation/SpeakerAttributor.swift', 'Sources/KokoroPronunciation/StoryNarration.swift', 'Sources/KokoroPronunciation/StructuredNumbers.swift', 'Sources/KokoroPronunciation/TextNormalizer.swift')
FRONTEND_NAMES=('tokenizer.json', 'tokenizer_config.json', 'config.json', 'special_tokens_map.json', 'added_tokens.json', 'vocab.json', 'merges.txt', 'speech_emb.npy', 'speech_pos_emb.npy', 'text_emb.npy', 'text_pos_emb.npy', 'spkr_enc_weight.npy', 'spkr_enc_bias.npy', 'emotion_adv_fc_weight.npy', 'perceiver_query.npy', 'perceiver_norm_weight.npy', 'perceiver_norm_bias.npy', 'perceiver_to_q_weight.npy', 'perceiver_to_q_bias.npy', 'perceiver_to_k_weight.npy', 'perceiver_to_k_bias.npy', 'perceiver_to_v_weight.npy', 'perceiver_to_v_bias.npy', 'perceiver_proj_out_weight.npy', 'perceiver_proj_out_bias.npy', 'chat_template.jinja', 'chat_template.json')
def require(v,message):
    if not v:raise RuntimeError(message)
def read(path,limit):
    p=pathlib.Path(path);require(p.stat().st_size<=limit,'Oversized metadata')
    with p.open('rb') as f:
        value=f.read(limit+1);require(len(value)<=limit,'Growing metadata');return value
def digest(path,guard):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        while True:
            guard();b=f.read(1024*1024)
            if not b:break
            h.update(b)
    return h.hexdigest()
def write(path,value):
    tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(value,indent=2)+'\n');tmp.replace(path)
def run(path,expected):
    path=pathlib.Path(path).resolve();root=path.parent
    require(root.parent==ROOT.resolve() and root.name=='native-decode-stage-profile-v01','Unowned program')
    receipt=root/'supervisor-result.json';require(not receipt.exists(),'Existing terminal stage; no restart')
    result={'state':'failed','owned_child_joined':False,'automatic_restart':False,'acoustics_executed':False,'audio_exported':False}
    write(receipt,result);owner.install_signal_handlers();began=time.monotonic();child=None;peak=0;next_check=0;host=None
    def guard():
        nonlocal next_check,peak
        owner.check_stop();now=time.monotonic();require(now-began<240,'Whole-program deadline')
        if now>=next_check:
            host();r=native_resources.shared();require(r.available_bytes()>=4*1024**3,'Available-memory guard')
            require(shutil.disk_usage(root).free>=2*1024**3,'Storage guard')
            if child is not None and child.poll() is None:
                try:rss=r.rss(child.pid)
                except RuntimeError:require(child.poll() is not None,'Unknown owned process memory')
                else:peak=max(peak,rss);require(rss<=4*1024**3,'RSS guard')
            next_check=now+1
    try:
        host=owner.HostGuard();raw=read(path,1024*1024);require(hashlib.sha256(raw).hexdigest()==expected,'Changed manifest');m=json.loads(raw)
        require(m['stage']=='native-decode-stage-profile-v01' and m['deadline_seconds']==240 and m['rss_limit_bytes']==4*1024**3 and m['automatic_restart'] is False,'Wrong scope');result['manifest_sha256']=expected
        files=m['source_files'];require(len(files)==len(REQUIRED_SOURCES),'Incomplete source inventory')
        require({str(pathlib.Path(f['path']).resolve().relative_to(root/'source')) for f in files}==set(REQUIRED_SOURCES),'Wrong source inventory')
        for f in files:require(digest(f['path'],guard)==f['sha256'],'Changed frozen source')
        bypath={pathlib.Path(f['path']).resolve():f['sha256'] for f in files}
        for p in [pathlib.Path(__file__).resolve(),pathlib.Path(owner.__file__).resolve(),pathlib.Path(native_resources.__file__).resolve()]:require(p in bypath and digest(p,guard)==bypath[p],'Unbound watchdog source')
        config=pathlib.Path(m['configuration']['path']);binary=pathlib.Path(m['executable']['path'])
        require(config.parent==root and binary.parent==root,'Unowned executable/config')
        require(digest(binary,guard)==m['executable']['sha256'],'Changed executable')
        cbytes=read(config,65536);require(hashlib.sha256(cbytes).hexdigest()==m['configuration']['sha256'],'Changed configuration');c=json.loads(cbytes)
        pre=read(root/'preregistration.json',65536);require(hashlib.sha256(pre).hexdigest()==m['preregistration_sha256'],'Changed preregistration');p=json.loads(pre)
        extra=read(root/'implementation-controls.json',65536);require(hashlib.sha256(extra).hexdigest()==m['implementation_controls_sha256'],'Changed implementation controls');extra=json.loads(extra)
        require(extra['parent_sha256']==m['preregistration_sha256'] and extra['inputs_and_arms_unchanged'] is True and extra['nested_not_added_to_accounted_sum'] is True,'Wrong implementation controls')
        require(c['inputs']==p['inputs'] and c['outputDirectory']==str(root/'output') and not (root/'output').exists(),'Wrong frozen inputs/output')
        require(p['controls']=={'exaggeration':.9,'guidance':.3,'temperature':.8,'seed':42,'max_tokens':350} and p['arms']==['profiling-off-en','profiling-off-es','profiling-on-en','profiling-on-es'],'Wrong prereg controls')
        require(pathlib.Path(c['metallib']).parent==root and digest(c['metallib'],guard)=='282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f','Changed runtime')
        def frontend():
            require(set(m['frontend_assets'])==set(FRONTEND_NAMES),'Incomplete frontend')
            for name,value in m['frontend_assets'].items():
                q=pathlib.Path(c['modelDirectory'])/name
                if value is None:require(not q.exists(),'Optional frontend appeared')
                else:require(digest(q,guard)==value,'Changed frontend')
        frontend()
        with open(root/'stdout.log','xb') as log:
            child=subprocess.Popen([str(binary),'--decoder-profile',str(config)],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,
                env=dict(os.environ,MLX_ENABLE_TF32='0',CHATTERBOX_PROFILE_DECODE='0',CHATTERBOX_SYNTH_SEED='42'))
            owner.check_stop();write(root/'status.json',{'state':'running','pid':child.pid})
            while child.poll() is None:
                guard()
                try:child.wait(timeout=.1)
                except subprocess.TimeoutExpired:pass
            guard();require(child.returncode==0 and not owner.group_alive(child.pid),'Terminal profile/descendants')
        rr=read(root/'output/report.json',1024*1024);r=json.loads(rr)
        require(r['state']=='complete_numeric_decoder_profile' and r['tokenIdentityValidated'] is True and r['acousticsExecuted'] is False and r['audioExported'] is False and r['cloudUsed'] is False,'Invalid/false-completion receipt')
        require(r['rendererProfile'].endswith(':backend=diagnostic-no-audio-decode-profile-1') and ':watermark=disabled-1' in r['rendererProfile'],'Unqualified backend identity')
        require(r['decoderWeightsSHA256']=='3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0' and r['oracleSHA256']=='87b8ab31eda9c63abbeecb8a9f0678bc8e0fe6980396ea0c4f9e16637ef618d2' and r['stockSHA256']=='5fef40319194272ac3ca10f02cd02e69b51ccb587f9b33357901a04605cdb68d','Wrong Standard identity')
        require([a['id'] for a in r['arms']]==p['arms'],'Missing/reordered/extra arms')
        for a in r['arms']:
            inp=next(x for x in p['inputs'] if x['language']==a['language'])
            require(a['inputSHA256']==hashlib.sha256(inp['text'].encode()).hexdigest(),'Wrong arm input')
            require(0<len(a['tokens'])<=350 and all(type(t) is int and 0<=t<6561 for t in a['tokens']),'Invalid token stream')
            require(a['tokensSHA256']==hashlib.sha256(struct.pack('<'+'i'*len(a['tokens']),*a['tokens'])).hexdigest(),'Invalid token hash')
            for k in ['wallSeconds','prefillSeconds','decodeSeconds','assemblySeconds']:require(math.isfinite(a[k]) and a[k]>=0,'Invalid timing')
            on=a['id'].startswith('profiling-on');require(a['profiling']==on,'Wrong profile flag')
            if on:
                s=a['stages'];fields=['inputPreparationSeconds','predictionSeconds','logitsCopyAndCFGSeconds','samplingSeconds','resourceGuardSeconds']
                require(all(math.isfinite(s[k]) and s[k]>=0 for k in fields) and len(a['tokens'])<s['iterations']<=350,'Invalid profiled stages')
                require(sum(s[k] for k in fields)<=a['wallSeconds']+.001,'Overlapping/invalid accounted wall')
                require(all(math.isfinite(s[k]) and s[k]>=0 for k in ['graphConstructionSeconds','evaluationSeconds']) and s['graphConstructionSeconds']+s['evaluationSeconds']<=s['predictionSeconds']+.001,'Invalid nested prediction accounting')
            else:require(a.get('stages') is None,'Unexpected off-arm profiling')
        for lang in ['en','es']:
            arms=[a for a in r['arms'] if a['language']==lang];require(len(arms)==2 and arms[0]['tokens']==arms[1]['tokens'],'Profiling changed complete token identity')
        require({x.name for x in (root/'output').iterdir()}=={'status.json','arms-incomplete.json','report.json'},'Unexpected audio/cache/asset output')
        frontend();require(digest(binary,guard)==m['executable']['sha256'] and read(config,65536)==cbytes and read(path,1024*1024)==raw,'Program changed')
        for f in files:require(digest(f['path'],guard)==f['sha256'],'Frozen source changed')
        result.update(state='complete_numeric_profile',report_sha256=hashlib.sha256(rr).hexdigest(),token_identity_validated=True)
    except BaseException as e:result.update(state='failed',failure=type(e).__name__+': '+str(e))
    finally:
        if child is not None:
            try:owner.terminate_owned(child);result['owned_child_joined']=child.poll() is not None and not owner.group_alive(child.pid)
            except BaseException as e:result.update(state='failed',cleanup_failure=str(e))
            result['exit_code']=child.poll()
        result.update(elapsed_seconds=time.monotonic()-began,peak_observed_rss_bytes=peak)
        write(root/'status.json',{'state':result['state'],'owned_child_joined':result['owned_child_joined'],'automatic_restart':False})
        try:
            if result['state']=='complete_numeric_profile':next_check=0;guard();require(result['owned_child_joined'],'Unjoined profile')
        except BaseException as e:
            result.update(state='failed',failure='final guard: '+str(e));write(root/'status.json',{'state':'failed','owned_child_joined':result['owned_child_joined'],'automatic_restart':False})
        write(receipt,result)
    print(json.dumps(result));return 0 if result['state']=='complete_numeric_profile' else 1
if __name__=='__main__':sys.exit(run(sys.argv[1],sys.argv[2]))
