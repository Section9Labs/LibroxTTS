#!/usr/bin/env python3
"""Cover every supported latent length in one shared-weight multifunction model."""
import argparse
import json
import pathlib
import subprocess
import sys
import tempfile
import coremltools as ct

p = argparse.ArgumentParser()
p.add_argument('source', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
p.add_argument('--short-functions', type=pathlib.Path, required=True)
a = p.parse_args()
assert not a.output.exists()
groups = [(16 if a.short_functions else 1,128), (129,256), (257,384), (385,431)]
desc = ct.utils.MultiFunctionDescriptor()
short_names = [f'latent_{n}' for n in range(1,16)] if a.short_functions else []
for name in short_names: desc.add_function(str(a.short_functions), name, name)
with tempfile.TemporaryDirectory(prefix='ct-general-gpu-') as staging:
    for first, last in groups:
        path = pathlib.Path(staging) / f'latent_{first}_{last}.mlpackage'
        subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('enumerate_generator_lengths.py')),
            str(a.source), str(path), '--first', str(first), '--last', str(last)], check=True)
        desc.add_function(str(path), 'main', f'latent_{first}_{last}')
    desc.default_function_name = 'latent_129_256'
    a.output.parent.mkdir(parents=True, exist_ok=True)
    ct.utils.save_multifunction(desc, str(a.output))
print(json.dumps({'path':str(a.output), 'functions':short_names + [f'latent_{lo}_{hi}' for lo,hi in groups],
    'bytes':sum(p.stat().st_size for p in a.output.rglob('*') if p.is_file())}))
