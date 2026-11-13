#!/usr/bin/env python3
"""Turn completed 1.0 receipts into an explicit goal scorecard; retain missed goals."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence', type=Path, default=Path('docs/architecture-10'))
args = parser.parse_args()
repository = Path(__file__).resolve().parents[1]


def read(name):
    return json.loads((args.evidence / name).read_text())


def optional(name):
    return read(name) if (args.evidence / name).exists() else None


targets = read('targets.json')
preparation = read('preparation-abba.json')
backends = read('backend-abba.json')
profile = read('profile-abba.json')
audio = read('audio-matrix.json')
plus = read('plus-audio.json')
basic = read('basic-audio.json')
coreml_name = 'backend-coreml-final.json' if (args.evidence / 'backend-coreml-final.json').exists() else 'backend-abba.json'
coreml = read(coreml_name)
device = optional('device-final.json')

assert audio['complete'] and audio['exactPCMAndEvents']
assert plus['exactPCM'] and basic['exactPCM']
assert backends['exactPCMAndEvents'] and coreml['exactPCMAndEvents'] and profile['exactWAV']
if device:
    assert device['complete'] and device['exactPCMAndEvents']

planning = {row['case']: row for row in preparation['summary'] if row['probe'] == 'Planning10'}
long_cases = [planning[name] for name in [
    'ctPlusV1-case0', 'ctPlusV1-case1', 'pocketTTSV1-case0', 'pocketTTSV1-case1',
]]
dictionaries = [row for row in preparation['summary'] if row['probe'] == 'Dictionary10']
assert len(dictionaries) == 2
cold = next(row for row in coreml['summary'] if row['backend'] == 'coreml' and row['name'] == 'cold')['firstAcceptedFrameSeconds']
observations = {
    'max-throughput': profile['summary']['warmSpeedup'],
    'cold-first-audio': device['summary']['freshColdRatio'] if device else None,
    'peak-memory': profile['summary']['footprintRatio'],
    'contextual-planning': min(row['speedup'] for row in long_cases),
    'cold-dictionary': min(row['speedup'] for row in dictionaries),
}

goals = []
for target in targets['targets']:
    value = observations[target['id']]
    lower_is_better = target['id'] in ['cold-first-audio', 'peak-memory']
    status = 'pending'
    if value is not None:
        met = value <= target['goal'] if lower_is_better else value >= target['goal']
        status = 'met' if met else 'missed'
    row = dict(**target, observed=value, status=status)
    if target['id'] == 'max-throughput':
        row['targetSeconds'] = profile['summary']['baseline']['warmMedianSeconds'] / target['goal']
        row['candidateSeconds'] = profile['summary']['candidate']['warmMedianSeconds']
    if target['id'] == 'cold-first-audio':
        row['nominatedMacProbe'] = row['workload']
        row['workload'] = 'Fresh physical iPad setup plus first accepted audio; original design requires all preparation'
        row['measurementScope'] = 'Installed/prepared-pack Mac process startup is supplemental; the 50% release goal retains full preparation'
        if device:
            row['targetSeconds'] = device['summary']['baseline']['freshSetupPlusFirstAudioSeconds'] * target['goal']
            row['candidateSeconds'] = device['summary']['candidate']['freshSetupPlusFirstAudioSeconds']
    goals.append(row)

recordings = [row for run in audio['runs'] if run['revision'] == 'candidate' for row in run['rows']]
recordings += plus['runs'][1]['rows'] + basic['rows']
result = dict(
    baseline=targets['baseline'],
    goals=goals,
    exactMacRecordings=len(recordings),
    exactMacSamples=sum(row['samples'] for row in recordings),
    installedPackMacColdRatio=cold['candidate'] / cold['baseline'],
    coreMLTimingReceipt=coreml_name,
    preparationControls=[row for row in planning.values() if row not in long_cases],
    warmPronunciation=read('pronunciation-abba.json'),
    indexedResourceBytes=sum(path.stat().st_size for path in (repository / 'Sources/PronunciationEnglish/Resources').glob('*.lxt')),
    limitations=[
        'Measured workloads only; no universal throughput or memory claim',
        'Shared Mac timing, two process trials per revision; descriptive medians',
        'Cold release goal counts fresh physical-device preparation; installed/prepared-pack Mac process startup is supplemental',
        'Sampled process footprint, not allocation high-water',
        'Goals are unchanged; missing a goal does not permit changing audio or contracts',
    ],
)
if device:
    result['deviceTiming'] = device['summary']
qualification = optional('device-qualification.json')
if qualification:
    result['device'] = qualification['summary']
(args.evidence / 'scorecard.json').write_text(json.dumps(result, indent=2) + '\n')
for row in goals:
    value = round(row['observed'], 3) if row['observed'] is not None else None
    print(row['id'], row['status'], value, 'goal', row['goal'])
