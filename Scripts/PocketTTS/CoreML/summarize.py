#!/usr/bin/env python3
"""Collect the local benchmark receipts without bundling large audio/model files."""
import argparse, hashlib, json, pathlib, statistics

def main():
    p=argparse.ArgumentParser();p.add_argument('--results',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
    report={'date':'2026-11-10','baseCommit':'cd969c6','quality':{'weights':'a7056f505a4a8ca72d8b5fb1440071d6f1a35739','precision':'float32','steps':4,'temperature':0.3,'englishVoice':'caro_davy__calm','chunking':'carefulReading','seed':42},'runs':{}}
    for platform in ['mac','iphone']:
        for file in sorted((a.results/platform).glob('*/report.json')):
            row=json.loads(file.read_text()); warm=row['rows'][1:]
            summary={'medianWarmRTFx':statistics.median(x['realTimeFactor'] for x in warm),
                     'minWarmRTFx':min(x['realTimeFactor'] for x in warm),
                     'medianWarmFirstAudioSeconds':statistics.median(x['firstAudioSeconds'] for x in warm),
                     'renderedAudioSeconds':sum(x['audioSeconds'] for x in row['rows']),
                     'renderSeconds':sum(x['renderSeconds'] for x in row['rows']),
                     'peakSampledApplicationFootprintBytes':max(x['peakPhysicalFootprintBytes'] for x in row['rows'])}
            audio={}
            for wav in sorted(file.parent.glob('*.wav')):
                with wav.open('rb') as f:audio[wav.name]=hashlib.file_digest(f,'sha256').hexdigest()
            report['runs'][f'{platform}/{file.parent.name}']={'summary':summary,'receipt':row,'audioSHA256':audio}
    bg=a.results/'iphone/coreml-cpu-background'
    report['backgroundEvidence']={name:json.loads((bg/f'{name}.json').read_text()) for name in ['generatingInBackground','completedInBackground']}
    lock=json.loads((a.results/'iphone/background-lock-state.json').read_text())['result']
    report['backgroundEvidence']['lockState']={k:lock[k] for k in ['passcodeRequired','unlockedSinceBoot']}
    report['pcmParity']={n:json.loads((a.results/n).read_text()) for n in ['zero-pcm-parity.json','seed42-pcm-parity.json']}
    report['asrScreen']=json.loads((a.results/'asr-screen.json').read_text())
    report['limitations']=[
        'One M3 Ultra Mac and one iPhone 17 Pro Max (iOS 27.2), connected to the Mac by USB.',
        'Background run used real audio playback; no background GPU or continued-processing entitlement.',
        'No silent background preparation, battery-discharge, unplugged endurance, other-device or human listening qualification.',
        'Core ML compute-unit allowances do not prove Neural Engine placement; this float32 baseline is CPU-oriented.',
        'Application footprint snapshots exclude memory in system services and are not total model memory.',
        'Mac application footprint grew during twenty repeated generations; long-session allocation retention needs investigation before production integration.',
        'The final source additionally blocks long teacher-forced prefixes into <=512-token calls. Benchmark passages fit one such call; no acoustic settings changed.'
    ]
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    for name,r in report['runs'].items():print(name, r['summary']['medianWarmRTFx'])
if __name__=='__main__':main()
