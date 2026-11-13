#!/usr/bin/env python3
"""Evaluate frozen level profiles on disjoint holdouts and export direct WAV auditions."""
import argparse
import json
import statistics
import struct
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--raw', nargs='+', type=Path, required=True)
p.add_argument('--delivered', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--auditions', type=Path, required=True)
p.add_argument('--policy', type=Path, default=Path('docs/loudness-review/targets.json'))
a = p.parse_args()
policy = json.loads(a.policy.read_text())
raw = [row for path in a.raw for row in json.loads(path.read_text())['rows']]
report = json.loads(a.delivered.read_text()); assert report['complete']
new = report['rows']
def key(row):
    return row['backend'], row['language'], row['voice'], row.get('style', 'original'), row['passage']
before = {key(r): r for r in raw}; after = {key(r): r for r in new}
assert len(before) == len(raw) == len(after) == len(new)
for k, r in after.items():
    assert r['rawSHA256'] == before[k]['sha256']
    assert r['samples'] == before[k]['samples']

def spread(values):
    return round(max(values) - min(values), 3)

def neutral_stats(rows, split):
    group = [r for r in rows if r.get('style', 'original') in ('original', 'neutral') and r['split'] == split]
    medians = [statistics.median(r['integratedLUFS'] for r in group if (r['voice'], r.get('style', 'original')) == pair)
               for pair in sorted({(r['voice'], r.get('style', 'original')) for r in group})]
    passages = {r['passage'] for r in group}
    return dict(medianSpreadLU=spread(medians), individualPassageMaxSpreadLU=max(
                spread([r['integratedLUFS'] for r in group if r['passage'] == passage]) for passage in passages))
summary = []
for backend, language in sorted({(r['backend'], r['language']) for r in new}):
    old_group = [r for r in raw if (r['backend'], r['language']) == (backend, language)]
    group = [r for r in new if (r['backend'], r['language']) == (backend, language)]
    summary.append(dict(backend=backend, language=language, recordings=len(group),
        calibrationBefore=neutral_stats(old_group, 'calibration'), calibrationAfter=neutral_stats(group, 'calibration'),
        holdoutBefore=neutral_stats(old_group, 'holdout'), holdoutAfter=neutral_stats(group, 'holdout'),
        maximumTruePeakDBFS=max(r['truePeakDBFS'] for r in group),
        kneeSamples=sum(r['kneeSamples'] for r in group)))
for row in summary:
    row['goals'] = dict(neutralCalibrationSpreadMet=row['calibrationAfter']['medianSpreadLU'] <= policy['goals']['neutralCalibrationMedianSpreadLU'],
        neutralHoldoutMedianSpreadMet=row['holdoutAfter']['medianSpreadLU'] <= policy['goals']['neutralHoldoutMedianSpreadLU'],
        neutralIndividualHoldoutSpreadMet=row['holdoutAfter']['individualPassageMaxSpreadLU'] <= policy['goals']['neutralIndividualHoldoutSpreadLU'],
        noPeakSafetyActivation=row['kneeSamples'] == 0)
knee = [dict(backend=r['backend'], language=r['language'], voice=r['voice'], style=r['style'], passage=r['passage'],
             split=r['split'], kneeSamples=r['kneeSamples'], samples=r['samples'], truePeakDBFS=r['truePeakDBFS'])
        for r in new if r['kneeSamples']]
a.output.write_text(json.dumps(dict(recordings=len(new), samples=sum(r['samples'] for r in new),
    exactSampleCounts=True, policy=policy, summary=summary, peakSafetyActivations=knee,
    humanListeningAccepted=False), indent=2) + '\n')
a.auditions.mkdir(parents=True, exist_ok=True)

def wav(path, data):
    # IEEE Float32 WAV retains the measured production samples exactly.
    fmt = struct.pack('<HHIIHH', 3, 1, 24000, 96000, 4, 32)
    path.write_bytes(b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<I', 16) + fmt + b'data' + struct.pack('<I', len(data)) + data)
orders = {}
for language in ['en', 'es']:
    sets = {
        'cast': [(v, 'original', 3) for v in ['caro_davy', 'alba', 'peter_yearsley', 'stuart_bell', 'bill_boerst']],
        'expression': [(v, s, 4) for v in ['caro_davy', 'bill_boerst'] for s in ['neutral', 'calm', 'shout', 'excited']]
    }
    for name, order in sets.items():
        keys = [('coreml-cpu', language, *entry) for entry in order]
        for label, lookup in [('before', before), ('after', after)]:
            parts = [Path(lookup[k]['pcm']).read_bytes() for k in keys]
            wav(a.auditions / f'{language}-{name}-{label}.wav', bytes(2400 * 4) + bytes(9600 * 4).join(parts))
        orders[language + '-' + name] = [dict(voice=v, style=s, passage=i, text=before[('coreml-cpu', language, v, s, i)]['text']) for v, s, i in order]
for index, row in enumerate(knee):
    k = (row['backend'], row['language'], row['voice'], row['style'], row['passage'])
    name = f"peak-{index + 1}-{row['language']}-{row['voice']}-{row['style']}"
    for label, lookup in [('before', before), ('after', after)]:
        wav(a.auditions / f'{name}-{label}.wav', Path(lookup[k]['pcm']).read_bytes())
    orders[name] = [dict(voice=row['voice'], style=row['style'], passage=row['passage'], text=before[k]['text'], kneeSamples=row['kneeSamples'])]
(a.auditions / 'order.json').write_text(json.dumps(orders, indent=2) + '\n')
for row in summary:
    print(row['backend'], row['language'], 'neutral calibration', row['calibrationBefore']['medianSpreadLU'], '->', row['calibrationAfter']['medianSpreadLU'],
          'holdout', row['holdoutBefore']['medianSpreadLU'], '->', row['holdoutAfter']['medianSpreadLU'], 'LU; knee', row['kneeSamples'])
