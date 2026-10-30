#!/usr/bin/env python3
"""Full-quality compiled decode MLP candidate, exact expressive PCM gates."""
import hashlib,json,math,os,pathlib,shutil,subprocess,sys,time
import owned_process as owner
import native_resources
ROOT=pathlib.Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01')
REQUIRED_SOURCES = ('Experiments/MacNativeAcoustics/native_resources.py', 'Experiments/MacNativeAcoustics/owned_process.py', 'Experiments/MacNativeAcoustics/supervise_book_expression.py', 'Experiments/MacNativeAcoustics/supervise_compiled_mlp_book.py', 'Experiments/MacNativeAcoustics/supervise_narration.py', 'Experiments/MacNativeAcoustics/supervise_resident_controls.py', 'Integrations/Chatterbox/Sources/LibroxChatterbox/BookDirector.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/BookSession.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/CacheIdentity.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/ChatterboxNarrator.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/LookaheadCache.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/NarrationBridge.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/PerformanceDirections.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/Resources/Chatterbox-Perth-LICENSE.txt', 'Integrations/Chatterbox/Sources/LibroxChatterbox/VoiceCreation.swift', 'Integrations/Chatterbox/Sources/LibroxChatterbox/VoiceStore.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCLI/main.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AcousticTimings.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AudioIO.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/AudioOutput.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/BatchPipeline.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/CanonicalMTLPrefillPacker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ChatterboxCoreMLModel.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ChunkPipeline.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/CondBlockBuilder.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Conditionals.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ConditioningBlockCache.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Constants.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/DecodeStepTimings.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Errors.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/GenerationOptions.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Log.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MLMultiArray+Helpers.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLPrefillAssembler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLT3LMRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MTLTextTokenizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/ModelRepository.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/MultilingualPromptBuilder.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/NPYFloat32.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Perceiver.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/PredictionTrap.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/PrefillAssembler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/RuAccentStress.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Sampler.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/SpeechEmbedding.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/SynthRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/T3Backend.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/T3LMRunner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TextChunker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TextTokenizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/TokenSynthesizer.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/VoiceCloner.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/VoiceFileValidation.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxCoreML/Watermarker.swift', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxExceptionTrap/CBXExceptionTrap.m', 'Integrations/Chatterbox/Vendor/ChatterboxCoreML/Sources/ChatterboxExceptionTrap/include/CBXExceptionTrap.h', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/Backbone.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/BackboneConfiguration.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/ChatterboxMLXRenderer.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/DenseCache.swift', 'Integrations/ChatterboxMLX/Sources/LibroxChatterboxMLX/SpeechDecoder.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticCheckpointAsset.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticInventory.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticKeyMapping.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/AcousticRuntimeAsset.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/ConformerEncoder.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/FlowMatching.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/HiFTGenerator.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/LICENSE', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticModel.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticProcessLease.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticRuntime.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAcousticSynthesizer.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/NativeAudioExport.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticAudit/PROVENANCE.md', 'Integrations/ChatterboxMac/Sources/ChatterboxMacAcousticProbe/main.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacNarrationProbe/CodecBenchmark.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacNarrationProbe/DecodeProfileBenchmark.swift', 'Integrations/ChatterboxMac/Sources/ChatterboxMacNarrationProbe/main.swift', 'Package.resolved', 'Package.swift', 'Sources/KokoroNarration/BookNarrationContext.swift', 'Sources/KokoroNarration/BookNarrationPlanner.swift', 'Sources/KokoroNarration/BookNarrationUnit+TextNative.swift', 'Sources/KokoroNarration/ConversationCadence.swift', 'Sources/KokoroNarration/DialogueTiming.swift', 'Sources/KokoroNarration/EnhancedNarrationDelivery.swift', 'Sources/KokoroNarration/NarrationDelivery.swift', 'Sources/KokoroNarration/NarrationDeliveryOptions.swift', 'Sources/KokoroNarration/NarrationExpression.swift', 'Sources/KokoroNarration/NarrationExpressionLexicon.swift', 'Sources/KokoroNarration/NarrationMood.swift', 'Sources/KokoroNarration/NarrationPerformance.swift', 'Sources/KokoroNarration/NarrationProfile.swift', 'Sources/KokoroNarration/SpanishFinalVocative.swift', 'Sources/KokoroNarration/StageDialogueStructure.swift', 'Sources/KokoroPronunciation/AsianPhonemizers.swift', 'Sources/KokoroPronunciation/BookVoiceCast.swift', 'Sources/KokoroPronunciation/CharacterContext.swift', 'Sources/KokoroPronunciation/EnglishIslandLexicon.swift', 'Sources/KokoroPronunciation/ForeignLatinSpelling.swift', 'Sources/KokoroPronunciation/InternationalNames.swift', 'Sources/KokoroPronunciation/JapaneseMappedLexicon.swift', 'Sources/KokoroPronunciation/LoanwordReadings.swift', 'Sources/KokoroPronunciation/MixedLanguage.swift', 'Sources/KokoroPronunciation/MultilingualLexicon.swift', 'Sources/KokoroPronunciation/NarrationPlanner.swift', 'Sources/KokoroPronunciation/NarrativeText.swift', 'Sources/KokoroPronunciation/NumberReadings.swift', 'Sources/KokoroPronunciation/Pronunciation.swift', 'Sources/KokoroPronunciation/Resources/ENGLISH-ISLANDS-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/UNIDIC-BSD.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/UNIDIC-COPYING.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/UNIDIC-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/japanese-unidic-manifest.json', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/japanese-unidic.dat', 'Sources/KokoroPronunciation/Resources/JapaneseUniDic/japanese-unidic.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/CC-BY-SA-4.0.txt', 'Sources/KokoroPronunciation/Resources/Multilingual/MULTILINGUAL-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-419.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-419.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-419.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-AR.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-AR.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es-AR.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-es.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-fr.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-fr.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-fr.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-hi.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-hi.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-hi.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-it.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-it.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-it.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-pt-BR.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-pt-BR.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-pt-BR.json', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-zh.dat', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-zh.idx', 'Sources/KokoroPronunciation/Resources/Multilingual/lexicon-zh.json', 'Sources/KokoroPronunciation/Resources/README.txt', 'Sources/KokoroPronunciation/Resources/Romance/FRENCH-DATA-NOTICE.txt', 'Sources/KokoroPronunciation/Resources/Romance/IPA-DICT-LICENSE.txt', 'Sources/KokoroPronunciation/Resources/Romance/french-ipa.tsv', 'Sources/KokoroPronunciation/Resources/english-islands.json', 'Sources/KokoroPronunciation/RomanceLexicon.swift', 'Sources/KokoroPronunciation/RomancePhonemizers.swift', 'Sources/KokoroPronunciation/SpanishLexicon.swift', 'Sources/KokoroPronunciation/SpanishPhonemizer.swift', 'Sources/KokoroPronunciation/SpeakerAttributor.swift', 'Sources/KokoroPronunciation/StoryNarration.swift', 'Sources/KokoroPronunciation/StructuredNumbers.swift', 'Sources/KokoroPronunciation/TextNormalizer.swift')
FRONTEND_NAMES=('tokenizer.json', 'tokenizer_config.json', 'config.json', 'special_tokens_map.json', 'added_tokens.json', 'vocab.json', 'merges.txt', 'speech_emb.npy', 'speech_pos_emb.npy', 'text_emb.npy', 'text_pos_emb.npy', 'spkr_enc_weight.npy', 'spkr_enc_bias.npy', 'emotion_adv_fc_weight.npy', 'perceiver_query.npy', 'perceiver_norm_weight.npy', 'perceiver_norm_bias.npy', 'perceiver_to_q_weight.npy', 'perceiver_to_q_bias.npy', 'perceiver_to_k_weight.npy', 'perceiver_to_k_bias.npy', 'perceiver_to_v_weight.npy', 'perceiver_to_v_bias.npy', 'perceiver_proj_out_weight.npy', 'perceiver_proj_out_bias.npy', 'chat_template.jinja', 'chat_template.json')
def require(value,message):
    if not value:raise RuntimeError(message)
def read(path,limit):
    p=pathlib.Path(path);require(p.stat().st_size<=limit,'Oversized metadata')
    with p.open('rb') as f:
        data=f.read(limit+1);require(len(data)<=limit,'Growing metadata');return data
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
    require(root.parent==ROOT.resolve() and root.name=='compiled-decode-mlp-book-v01','Unowned program')
    receipt=root/'supervisor-result.json';require(not receipt.exists(),'Terminal program; no restart')
    result={'state':'failed','owned_child_joined':False,'automatic_restart':False,'quality_approved':False,'cloud_upload_measured':False}
    write(receipt,result);owner.install_signal_handlers();began=time.monotonic();child=None;peak=0;next_check=0;host=None
    def guard():
        nonlocal peak,next_check
        owner.check_stop();now=time.monotonic();require(now-began<360,'Whole-program deadline')
        if now>=next_check:
            host();r=native_resources.shared()
            require(r.available_bytes()>=4*1024**3,'Available-memory guard')
            require(shutil.disk_usage(root).free>=2*1024**3,'Storage guard')
            if child is not None and child.poll() is None:
                try:rss=r.rss(child.pid)
                except RuntimeError:require(child.poll() is not None,'Unknown owned child memory')
                else:peak=max(peak,rss);require(rss<=6*1024**3,'Renderer RSS guard')
            next_check=now+1
    try:
        host=owner.HostGuard();raw=read(path,1024*1024);require(hashlib.sha256(raw).hexdigest()==expected,'Changed manifest');m=json.loads(raw)
        require(m['stage']=='compiled-decode-mlp-book-v01' and m['deadline_seconds']==360 and m['rss_limit_bytes']==6*1024**3 and m['automatic_restart'] is False,'Wrong scope')
        result['manifest_sha256']=expected
        files=m['source_files'];require(len(files)==len(REQUIRED_SOURCES),'Missing source')
        require({str(pathlib.Path(x['path']).resolve().relative_to(root/'source')) for x in files}==set(REQUIRED_SOURCES),'Wrong source inventory')
        for x in files:require(digest(x['path'],guard)==x['sha256'],'Changed frozen source')
        bypath={pathlib.Path(x['path']).resolve():x['sha256'] for x in files}
        for p in [pathlib.Path(__file__).resolve(),pathlib.Path(owner.__file__).resolve(),pathlib.Path(native_resources.__file__).resolve()]:
            require(p in bypath and digest(p,guard)==bypath[p],'Unbound running watchdog')
        config=pathlib.Path(m['configuration']['path']);binary=pathlib.Path(m['executable']['path'])
        require(config.parent==root and binary.parent==root,'Unowned config/executable')
        require(digest(binary,guard)==m['executable']['sha256'],'Changed executable')
        cbytes=read(config,65536);require(hashlib.sha256(cbytes).hexdigest()==m['configuration']['sha256'],'Changed config');c=json.loads(cbytes)
        require(c['variant']=='native' and c['watermark']=='disabled-1' and c['overlap'] is True and c['grouped'] is True and c.get('residentControls') is not True and c['bookSchedulingControls'] is True and c['decoderExecution']=='compiled-decode-mlp-1' and c['waveformPolicy']=='deterministic-gather-2','Wrong render policy')
        require(c['outputDirectory']==str(root/'output') and not (root/'output').exists() and set(c['texts'])=={'en'},'Wrong output/language')
        pread=read(root/'preregistration.json',65536);require(hashlib.sha256(pread).hexdigest()==m['preregistration_sha256'],'Changed preregistration');p=json.loads(pread)
        addraw=read(root/'implementation-controls.json',65536);require(hashlib.sha256(addraw).hexdigest()==m['implementation_controls_sha256'],'Changed implementation controls');add=json.loads(addraw)
        require(add['parent_preregistration_sha256']==m['preregistration_sha256'] and add['clear_allocator_before_every_arm_outside_timer'] is True and add['validate_observed_descriptors_before_advancing'] is True,'Wrong control addendum')
        toy=read(m['toy_qualification']['path'],65536);require(hashlib.sha256(toy).hexdigest()==m['toy_qualification']['sha256'],'Changed tiny qualification');t=json.loads(toy)
        require(all(t.get(k) is True for k in ['completed','sameBitsBeforeUpdate','sameBitsAfterUpdate','outputChanged','ownerReleased','childReleased']),'Unqualified liveweights/lifetime')
        reference_raw=read(p['reference_report'],4*1024**2);require(hashlib.sha256(reference_raw).hexdigest()==p['reference_report_sha256'],'Changed approved PCM reference');reference=json.loads(reference_raw);ref=reference['results'][0]
        descriptor_keys=['index','firstFrame','frames','generatedFrames','sourceLocation','sourceLength','speechTokens','exaggeration','guidance','temperature']
        require(c['referencePassages']==[{k:u[k] for k in descriptor_keys} for u in ref['passages']],'Repointed reference descriptors')
        book=c['bookAudition'];require(book==p['controls']==reference['bookAudition'],'Wrong expression/source policy')
        require(c['texts']['en']==p['input']==ref['text'] and c['referencePCM']==p['reference_pcm_sha256']==ref['pcmSHA256'],'Repointed source/PCM reference')
        require(digest(book['sourceFile'],guard)==book['sourceSHA256'],'Changed book')
        source=read(book['sourceFile'],1024*1024).decode('utf-8').encode('utf-16-le');a=book['offsetUTF16']*2;b=a+book['lengthUTF16']*2
        require(source[a:b].decode('utf-16-le')==p['input'],'Book source range mismatch')
        def assets():
            for name,value in m['frontend_assets'].items():
                q=pathlib.Path(c['modelDirectory'])/name
                if value is None:require(not q.exists(),'Optional frontend appeared')
                else:require(digest(q,guard)==value,'Changed frontend')
        require(set(m['frontend_assets'])==set(FRONTEND_NAMES),'Incomplete frontend inventory');assets()
        require(pathlib.Path(c['metallib']).parent==root and digest(c['metallib'],guard)=='282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f','Changed runtime')
        with open(root/'stdout.log','xb') as log:
            child=subprocess.Popen([str(binary),str(config)],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,
                env=dict(os.environ,MLX_ENABLE_TF32='0',CHATTERBOX_SYNTH_SEED='42',CHATTERBOX_PROFILE_DECODE='0'))
            owner.check_stop();write(root/'status.json',{'state':'running','pid':child.pid,'stage':m['stage']})
            while child.poll() is None:
                guard()
                try:child.wait(timeout=.1)
                except subprocess.TimeoutExpired:pass
            guard();require(child.returncode==0 and not owner.group_alive(child.pid),'Terminal render/descendants')
        rr=read(root/'output/report.json',4*1024**2);r=json.loads(rr)
        require(r['state']=='complete' and r['variant']=='native' and r['watermark']=='disabled-1' and r['bookAudition']==book and r['waveformPolicy']=='deterministic-gather-2','Wrong render receipt')
        require(r['userListeningApproved'] is False and r['cloudUploadMeasured'] is False and r['pcmIdentityValidated'] is True,'False quality/identity/cloud receipt')
        require(r['decoderWeightsSHA256']==reference['decoderWeightsSHA256'] and r['acousticCheckpointSHA256']==reference['acousticCheckpointSHA256'] and r['stockSHA256']==reference['stockSHA256'],'Wrong models')
        require(math.isfinite(r['decoderQualificationSeconds']) and 0<r['decoderQualificationSeconds']<=r['coldLoadSeconds'],'Missing cold qualification/compilation accounting')
        ids=['warmup','legacy-serial','legacy-overlap','resident-serial','resident-overlap','legacy-serial-repeat']
        require([(x['trialID'],x['language']) for x in r['results']]==[(n,'en') for n in ids],'Missing/extra/out-of-order arms')
        expected_trials=[{'id':n,'grouped':True,'overlap':n in ['legacy-overlap','resident-overlap']} | ({'residentBuffers':True} if n.startswith('resident-') else {}) for n in ids]
        require(r['trials']==expected_trials and p['trials']==ids,'Wrong fixed trial policies')
        require(r['bootWarmupSeconds']==r['results'][0]['completeWarmSeconds'],'Incorrect boot warmup accounting')
        exports=[]
        keys=['index','firstFrame','frames','generatedFrames','sourceLocation','sourceLength','speechTokens','exaggeration','guidance','temperature']
        expected_units=[{k:u[k] for k in keys} for u in ref['passages']]
        for x in r['results']:
            name=x['trialID'];overlap=name in ['legacy-overlap','resident-overlap'];retained=name.startswith('resident-')
            require(x['text']==p['input'] and x['deliveryMode']=='AAC64-only' and x['grouped'] is True and x['overlap']==overlap,'Wrong arm scope')
            expected_profile=ref['rendererProfile']+':decoderexecution=compiled-decode-mlp-1'+(':buffers=bounded-resident-mac-1' if retained else '')
            require(x['rendererProfile']==expected_profile,'Wrong allocation profile identity')
            require(x['pcmSHA256']==ref['pcmSHA256'] and x['audioSeconds']==ref['audioSeconds'],'Actual raw PCM changed')
            require([{k:u[k] for k in keys} for u in x['passages']]==expected_units,'Changed token/source/cadence/frame descriptors')
            require(x['profilingEnabled'] is False and x['initialAllocatorCleared'] is True and all(u.get('decodeSteps') is None for u in x['passages']),'Mixed profiling flags/allocator starting conditions')
            for k in ['audioSeconds','completeWarmSeconds','completeWarmRTF','playbackMultiple']:require(math.isfinite(x[k]) and x[k]>0,'Invalid timings')
            for snapshot in [x['memoryAtStart'],x['memoryAtEnd']]:
                require(snapshot['lowPowerMode'] is False and snapshot['thermalState'] in [0,1] and snapshot['activeBytes']>=0 and snapshot['cacheBytes']>=0,'Invalid resource snapshot')
            require(len(x['exports'])==1,'Extra/missing codec');e=x['exports'][0];q=pathlib.Path(e['path'])
            require(q==root/'output'/name/'en-smaller.m4a' and e['codec']=='AAC-LC-64k-requested' and e['frameCountMatches'] is True and e['frames']==p['reference_frames'] and e['samplePrecisionChecked'] is False,'Wrong AAC receipt')
            require(math.isfinite(e['decodedPeak']) and 0<=e['decodedPeak']<=1 and q.stat().st_size==e['bytes'] and digest(q,guard)==e['sha256'],'Unverified AAC bytes/samples')
            exports.append(e)
        assets();require(digest(book['sourceFile'],guard)==book['sourceSHA256'],'Book changed during render')
        require(digest(binary,guard)==m['executable']['sha256'] and read(config,65536)==cbytes and read(path,1024*1024)==raw,'Program changed')
        for f in files:require(digest(f['path'],guard)==f['sha256'],'Frozen source changed')
        result.update(state='complete_exact_pcm_compiled_mlp_controls',report_sha256=hashlib.sha256(rr).hexdigest(),exports=exports,reference_pcm_sha256=ref['pcmSHA256'])
    except BaseException as e:result.update(state='failed',failure=type(e).__name__+': '+str(e))
    finally:
        if child is not None:
            try:owner.terminate_owned(child);result['owned_child_joined']=child.poll() is not None and not owner.group_alive(child.pid)
            except BaseException as e:result.update(state='failed',cleanup_failure=str(e))
            result['exit_code']=child.poll()
        result.update(elapsed_seconds=time.monotonic()-began,peak_observed_rss_bytes=peak)
        write(root/'status.json',{'state':result['state'],'owned_child_joined':result['owned_child_joined'],'automatic_restart':False})
        try:
            if result['state']=='complete_exact_pcm_compiled_mlp_controls':
                next_check=0;guard();require(result['owned_child_joined'],'Unjoined render')
        except BaseException as e:
            result.update(state='failed',failure='final guard: '+str(e))
            write(root/'status.json',{'state':'failed','owned_child_joined':result['owned_child_joined'],'automatic_restart':False})
        write(receipt,result)
    print(json.dumps(result));return 0 if result['state']=='complete_exact_pcm_compiled_mlp_controls' else 1
if __name__=='__main__':sys.exit(run(sys.argv[1],sys.argv[2]))
