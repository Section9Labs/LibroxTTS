#!/usr/bin/env python3
"""Compare Basic's eight preferred-language samples with the unchanged kokoro-probe."""
import argparse
import hashlib
import json
import struct
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('baseline', type=Path)
p.add_argument('candidate', type=Path)
p.add_argument('--assets', type=Path, required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--collect-existing', action='store_true', help='Compare already completed probe output')
a = p.parse_args()
if not a.collect_existing:
    a.work.mkdir(parents=True, exist_ok=False)
    for revision in ['baseline', 'candidate']:
        with (a.work / (revision + '.log')).open('w') as log:
            subprocess.run([str((getattr(a, revision) / 'kokoro-probe').resolve()),
                            str(a.assets.resolve()), '--output', str((a.work / revision).resolve())],
                           stdout=log, stderr=subprocess.STDOUT, check=True)

def pcm(path):
    data = path.read_bytes()
    assert data[:4] == b'RIFF' and data[8:12] == b'WAVE', path
    chunks, offset = {}, 12
    while offset + 8 <= len(data):
        name, length = struct.unpack_from('<4sI', data, offset)
        offset += 8
        assert offset + length <= len(data), path
        chunks[name] = data[offset:offset + length]
        offset += length + (length % 2)
    fmt, samples = chunks[b'fmt '], chunks[b'data']
    block_align = struct.unpack_from('<H', fmt, 12)[0]
    assert block_align > 0 and len(samples) % block_align == 0
    return fmt, samples, len(samples) // block_align

names = sorted(f.name for f in (a.work / 'baseline').glob('*.wav'))
assert len(names) == 8 and names == sorted(f.name for f in (a.work / 'candidate').glob('*.wav'))
rows = []
for name in names:
    old, new = [pcm(a.work / revision / name) for revision in ['baseline', 'candidate']]
    assert old == new, name
    rows.append(dict(voice=Path(name).stem, exact=True, samples=old[2],
                     baselineSHA256=hashlib.sha256(old[1]).hexdigest(),
                     candidateSHA256=hashlib.sha256(new[1]).hexdigest()))
result = dict(exactPCM=True,
              scope='Basic established CPU Core ML, eight preferred language samples, speed 1; WAV format and PCM bytes compared',
              rows=rows,
              binarySHA256={r: hashlib.sha256((getattr(a, r) / 'kokoro-probe').read_bytes()).hexdigest()
                            for r in ['baseline', 'candidate']})
a.output.write_text(json.dumps(result, indent=2) + '\n')
print(len(rows), 'exact recordings;', sum(r['samples'] for r in rows), 'samples')
