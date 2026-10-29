#!/usr/bin/env python3
"""Metadata-only precision audit of the already-created exact700 package."""
import json
from pathlib import Path
import time
import resource
import shutil
import coremltools as ct
import numpy as np
from coremltools.converters.mil.frontend.milproto import load as loader
from materialize_exact import (SOURCE, ROOT, MANIFEST_SHA, MODEL_SHA, WEIGHT_SHA,
    HostGuard, digest, atomic, resolve_manifest, describe, require_shape_only)


def main():
    began = time.monotonic(); guard = HostGuard()
    output = ROOT / 'cfm-exact700-precision-audit-v04'
    if output.exists(): raise ValueError('Never overwrite an audit')
    output.mkdir()
    report = {'completed': False, 'runtime_model_loads': 0, 'predictions': 0,
        'scope': 'precision-aware metadata audit only; no conversion or prediction rerun',
        'audio_or_phone_or_accelerator_clearance': False}
    atomic(output / 'report.json', report)
    def check():
        guard()
        if time.monotonic() - began > 180: raise TimeoutError('Metadata audit budget')
        if resource.getrusage(resource.RUSAGE_SELF).ru_maxrss > 8 * 1024**3 or shutil.disk_usage(ROOT).free < 1024**3:
            raise RuntimeError('Metadata memory/storage guard')
    source = ROOT / 'cfm-exact700-specialization-v02'
    candidate = source / 'S3CFM-exact700.mlpackage'
    identities = [(SOURCE, MANIFEST_SHA, MODEL_SHA), (candidate,
        '346553802ed0157c8828171b14bfa89f0504fc7c7472dc1611f80b91b605182b',
        'a4dea2fe920015331dee8754adf82fc531bb8edc37c62d8d63238f9fe33c01b4')]
    def verify():
        for package, manifest_sha, model_sha in identities:
            model, weights = resolve_manifest(package, manifest_sha)
            if digest(model, check) != model_sha or digest(weights / 'weight.bin', check) != WEIGHT_SHA:
                raise ValueError('Changed source/candidate bytes')
        if digest(source / 'report.json', check) != '262039cfeb4ef57a7198cb95518642b464cc322fd6d90e643ea38e6cbe99d8a2':
            raise ValueError('Changed parent receipt')
    try:
        verify(); structures=[]
        for index, (package, _, _) in enumerate(identities):
            check()
            model = ct.models.MLModel(str(package), skip_model_load=True, compute_units=ct.ComputeUnit.CPU_ONLY)
            _, resolved_weights = resolve_manifest(package, identities[index][1])
            if Path(model.weights_dir).resolve() != resolved_weights:
                raise ValueError('Loader weights path differs from manifest')
            spec = model.get_spec(); program = loader.load(spec, spec.specificationVersion, model.weights_dir)
            if set(program.functions) != {'main'}: raise ValueError('Wrong function set')
            structure = describe(program.functions['main'], np, check)
            structures.append(structure); atomic(output / f'precision-structure-{index}.json', structure)
        require_shape_only(*structures)
        verify(); check()
        report.update(precision_gate_passed=True, ordered_operations=len(structures[0]['operators']),
            constants=len(structures[0]['constants']), datatype_encoding='MIL types.builtin_to_string',
            structure_sha256=[digest(output / f'precision-structure-{i}.json', check) for i in range(2)])
        check(); report['completed']=True; atomic(output / 'report.json', report)
    except BaseException as error:
        report.update(completed=False,error=str(error));atomic(output / 'report.json', report);raise


if __name__ == '__main__': main()
