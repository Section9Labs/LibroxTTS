#!/usr/bin/env python3
"""ASR word screening of direct WAV auditions; does not rank emotional quality."""
import argparse
import difflib
import json
import pathlib
import re

import mlx_whisper

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('directory', type=pathlib.Path)
args = parser.parse_args()
rows = json.loads((args.directory / 'auditions.json').read_text())
results = []
for row in rows:
    language = row['request']['voiceID'].rsplit('-', 2)[1]
    transcript = mlx_whisper.transcribe(row['wav'], path_or_hf_repo='mlx-community/whisper-large-v3-turbo',
                                      language=language, verbose=False)['text']
    expected = re.findall(r'\w+', row['request']['text'].casefold())
    heard = re.findall(r'\w+', transcript.casefold())
    differences = []
    for tag, i, j, k, l in difflib.SequenceMatcher(a=expected, b=heard, autojunk=False).get_opcodes():
        if tag != 'equal':
            differences.append(dict(kind=tag, expected=' '.join(expected[i:j]), heard=' '.join(heard[k:l])))
    results.append(dict(name=row['name'], audioSHA256=row['audioSHA256'], transcript=transcript,
                        wordsMatch=expected == heard, differences=differences))
    (args.directory / 'asr-screening.json').write_text(json.dumps(dict(results=results,
        qualification='ASR flags need listening review; exact words do not establish narrator quality.'),
        indent=2, ensure_ascii=False) + '\n')
    print(row['name'], 'match' if expected == heard else json.dumps(differences, ensure_ascii=False), flush=True)
