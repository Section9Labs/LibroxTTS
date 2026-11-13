#!/usr/bin/env python3
"""Measure raw, hash-verified calibration/holdout PCM with FFmpeg's BS.1770 meter."""
import argparse
import concurrent.futures
import hashlib
import json
import re
import statistics
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directories', nargs='+', type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--allow-partial', action='store_true')
args = parser.parse_args()
records = []
for directory in args.directories:
    if not args.allow_partial:
        assert (directory / 'complete.txt').read_text() == 'complete', directory
    records += [(path, json.loads(path.read_text())) for path in sorted(directory.glob('*.json'))]

def measure(item):
    path, row = item
    row.setdefault("style", "original")
    pcm = path.with_suffix('.f32')
    data = pcm.read_bytes()
    assert len(data) == row['samples'] * 4 and hashlib.sha256(data).hexdigest() == row['sha256'], pcm
    result = subprocess.run(['ffmpeg', '-hide_banner', '-nostats', '-f', 'f32le', '-ar', str(row['sampleRate']),
                             '-ac', '1', '-i', str(pcm), '-af', 'ebur128=peak=true', '-f', 'null', '-'],
                            capture_output=True, text=True, check=True).stderr.rsplit('Summary:', 1)[1]
    return dict(**row, integratedLUFS=float(re.search(r'I:\s+([-\d.]+) LUFS', result)[1]),
                truePeakDBFS=float(re.search(r'Peak:\s+([-\d.]+) dBFS', result)[1]), pcm=str(pcm))

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    rows = list(pool.map(measure, records))
summary = []
for backend, language, voice, style in sorted({(r['backend'], r['language'], r['voice'], r['style']) for r in rows}):
    group = [r for r in rows if (r['backend'], r['language'], r['voice'], r['style']) == (backend, language, voice, style)]
    calibration = [r['integratedLUFS'] for r in group if r['split'] == 'calibration']
    holdout = [r['integratedLUFS'] for r in group if r['split'] == 'holdout']
    if not args.allow_partial:
        assert len(calibration) == 3 and len(holdout) == 2, (backend, language, voice)
    summary.append(dict(backend=backend, language=language, voice=voice, style=style,
                        calibrationMedianLUFS=statistics.median(calibration) if calibration else None,
                        holdoutMedianLUFS=statistics.median(holdout) if holdout else None,
                        maximumTruePeakDBFS=max(r['truePeakDBFS'] for r in group)))
report = dict(complete=not args.allow_partial, rows=rows, summary=summary,
              measurement='Mono 24 kHz Float32; FFmpeg ebur128 integrated loudness and true peak',
              ffmpegVersion=subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0])
args.output.write_text(json.dumps(report, indent=2) + '\n')
for backend, language in sorted({(r['backend'], r['language']) for r in rows}):
    levels = [r['calibrationMedianLUFS'] for r in summary if (r['backend'], r['language']) == (backend, language) and r['calibrationMedianLUFS'] is not None]
    print(backend, language, len(levels), 'voice/style profiles;', min(levels), 'to', max(levels), 'LUFS; spread', max(levels)-min(levels))
