#!/usr/bin/env python3
"""Off-phone shape-only CFM specialization. Never loads a Core ML runtime.

Only the symbolic-shape materialization pass is admitted. The convenience
coremltools helper also applies DEFAULT optimization passes, so it is not used.
A structural pass is necessary but not sufficient: original/candidate CPU
trajectory qualification is a separate, required next stage.
"""
import hashlib
import ctypes
import json
from pathlib import Path
import resource
import shutil
import sys
import time

ROOT = Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01')
SOURCE = Path('/Volumes/T9.2025/LibroxTraining/models/chatterbox-v3-coreml-evaluation/multilingual/S3CFM.mlpackage')
MANIFEST_SHA = 'ad88323378459dbb1bd11b1dcb52585e490c8c6aabf9b4c123718b4800936a4f'
MODEL_SHA = 'fe6fd80eec738c2f7716ddfca82a986855d7017e01e00aa0ac35fb010266ef09'
WEIGHT_SHA = '871cced027e306366c4bcacb7a0eb12a328831f6e1d4d70000d0e0d0f6354524'
SHAPES = {'x': (1, 80, 700), 'mu': (1, 80, 700), 'cond': (1, 80, 700),
          'mask': (1, 1, 700), 'spks_raw': (1, 192), 'spks_scale': (1,), 't': (1,)}


def digest(path, check=lambda: None):
    h = hashlib.sha256()
    with path.open('rb') as f:
        while data := f.read(1 << 20):
            check(); h.update(data)
    return h.hexdigest()


def atomic(path, data):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    temp.replace(path)


def describe(function, np, check=lambda: None):
    """Keep names/edges/types/constants; shape metadata is the sole intervention."""
    from coremltools.converters.mil.mil import types
    result = {'inputs': {}, 'outputs': [], 'operators': [], 'constants': {}}
    def value(v):
        shape = [int(x) if isinstance(x, (int, np.integer)) else str(x) for x in v.shape]
        return {'name': v.name, 'dtype': types.builtin_to_string(v.dtype), 'shape': shape}
    for name, v in function.inputs.items():
        result['inputs'][name] = value(v)
    result['outputs'] = [value(v) for v in function.outputs]
    for op in function.operations:
        check()
        if op.blocks:
            raise ValueError('Unreviewed nested block')
        if op.op_type == 'const':
            for v in op.outputs:
                a = np.asarray(v.val)
                if a.dtype.kind in 'OUS':
                    raw = json.dumps(a.tolist(), ensure_ascii=True, sort_keys=True).encode()
                else:
                    raw = a.tobytes(order='C')
                result['constants'][v.name] = {'dtype': a.dtype.str, 'shape': list(a.shape),
                    'sha256': hashlib.sha256(raw).hexdigest()}
        else:
            result['operators'].append({'name': op.name, 'kind': op.op_type,
                'inputs': {name: [v.name for v in (vs if isinstance(vs, (tuple, list)) else [vs])]
                           for name, vs in op.inputs.items()},
                'outputs': [value(v) for v in op.outputs]})
    return result


def require_shape_only(before, after):
    if before['constants'] != after['constants']:
        raise ValueError('Constant identity, bits, dtype or shape changed')
    if set(before['inputs']) != set(after['inputs']):
        raise ValueError('Input identity changed')
    def variables(a, b):
        if len(a) != len(b):
            raise ValueError('Output count changed')
        for old, new in zip(a, b):
            if old['name'] != new['name'] or old['dtype'] != new['dtype']:
                raise ValueError('Variable identity or precision changed')
            if len(old['shape']) != len(new['shape']):
                raise ValueError('Rank changed')
            for previous, actual in zip(old['shape'], new['shape']):
                if type(actual) is not int or actual <= 0:
                    raise ValueError('Unresolved or invalid materialized dimension')
                if type(previous) is int and previous != actual:
                    raise ValueError('Previously static dimension changed')
    for name in before['inputs']:
        variables([before['inputs'][name]], [after['inputs'][name]])
        if after['inputs'][name]['shape'] != list(SHAPES[name]):
            raise ValueError('Wrong exact input shape')
    variables(before['outputs'], after['outputs'])
    if len(before['operators']) != len(after['operators']):
        raise ValueError('Operator count changed')
    for old, new in zip(before['operators'], after['operators']):
        for key in ('name', 'kind', 'inputs'):
            if old[key] != new[key]:
                raise ValueError('Operator, order or operand edges changed')
        variables(old['outputs'], new['outputs'])


def resolve_manifest(source, expected_sha):
    manifest = source / 'Manifest.json'
    with manifest.open('rb') as f:
        data = f.read(16385)
    if len(data) > 16384 or hashlib.sha256(data).hexdigest() != expected_sha:
        raise ValueError('Source package manifest identity')
    record = json.loads(data)
    entries = record['itemInfoEntries']
    root = entries[record['rootModelIdentifier']]
    if (len(entries) != 2 or root['author'] != 'com.apple.CoreML' or
            root['name'] != 'model.mlmodel' or root['path'] != 'com.apple.CoreML/model.mlmodel'):
        raise ValueError('Redirected source package model')
    weights = [v for k, v in entries.items() if k != record['rootModelIdentifier']]
    if (len(weights) != 1 or weights[0]['author'] != 'com.apple.CoreML' or
            weights[0]['name'] != 'weights' or weights[0]['path'] != 'com.apple.CoreML/weights'):
        raise ValueError('Redirected source package weights')
    model = (source / 'Data' / root['path']).resolve()
    directory = (source / 'Data' / weights[0]['path']).resolve()
    if not model.is_relative_to(source.resolve()) or not directory.is_relative_to(source.resolve()):
        raise ValueError('Source package symlink escapes its pinned package')
    return model, directory


def final_package_files(destination, check):
    files = {}
    for p in sorted(destination.rglob('*')):
        check()
        if p.is_file():
            files[str(p.relative_to(destination))] = {'bytes': p.stat().st_size, 'sha256': digest(p, check)}
    check()
    return files


class HostGuard:
    """Read the same NSProcessInfo thermal and low-power state as the SDK."""
    def __init__(self):
        self.foundation = ctypes.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
        objc = ctypes.CDLL('/usr/lib/libobjc.A.dylib')
        objc.objc_getClass.argtypes = [ctypes.c_char_p]
        objc.objc_getClass.restype = ctypes.c_void_p
        objc.sel_registerName.argtypes = [ctypes.c_char_p]
        objc.sel_registerName.restype = ctypes.c_void_p
        self.selector = objc.sel_registerName
        pointer = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(('objc_msgSend', objc))
        self.integer = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)(('objc_msgSend', objc))
        self.boolean = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)(('objc_msgSend', objc))
        self.process = pointer(objc.objc_getClass(b'NSProcessInfo'), self.selector(b'processInfo'))
        if not self.process:
            raise RuntimeError('Host guard unavailable')
    def __call__(self):
        thermal = self.integer(self.process, self.selector(b'thermalState'))
        low_power = self.boolean(self.process, self.selector(b'isLowPowerModeEnabled'))
        if thermal not in (0, 1) or low_power:
            raise RuntimeError('Thermal/low-power guard')


def main(config):
    began = time.monotonic()
    output = Path(config['outputDirectory']).resolve()
    if output.parent != ROOT.resolve() or output.exists():
        raise ValueError('Output must be new and directly under owned run root')
    host_guard = HostGuard()
    host_guard()
    output.mkdir()
    report = {'completed': False, 'runtime_model_loads': 0, 'predictions': 0,
              'audio_or_phone_clearance': False}
    atomic(output / 'report.json', report)
    def check():
        if time.monotonic() - began > 600 or resource.getrusage(resource.RUSAGE_SELF).ru_maxrss > 8 * 1024**3:
            raise RuntimeError('Conversion time/memory limit')
        if shutil.disk_usage(ROOT).free < 1024**3:
            raise RuntimeError('Storage guard')
        host_guard()
    try:
        check()
        import coremltools as ct
        import numpy as np
        from coremltools.converters.mil.frontend.milproto import load as loader
        from coremltools.converters.mil.mil.passes.pass_pipeline import PassPipelineManager
        from coremltools.converters.mil.converter import mil_convert
        if ct.__version__ != '9.0':
            raise ValueError('Unqualified coremltools version')
        def source_identity():
            model_file, weights_directory = resolve_manifest(SOURCE, MANIFEST_SHA)
            if digest(model_file, check) != MODEL_SHA or digest(weights_directory / 'weight.bin', check) != WEIGHT_SHA:
                raise ValueError('Source model identity')
            return weights_directory
        weights_directory = source_identity()
        original = ct.models.MLModel(str(SOURCE), skip_model_load=True, compute_units=ct.ComputeUnit.CPU_ONLY)
        if Path(original.weights_dir).resolve() != weights_directory:
            raise ValueError("Loader source weight resolution differs from pinned package")
        spec = original.get_spec()
        program = loader.load(spec, spec.specificationVersion, original.weights_dir)
        if set(program.functions) != {'main'}:
            raise ValueError('Unreviewed function structure')
        before = describe(program.functions['main'], np, check)
        atomic(output / 'before-structure.json', before)
        check()
        pipeline = ct.PassPipeline(pass_names=['common::materialize_symbolic_shape_program'])
        pipeline.set_options('common::materialize_symbolic_shape_program',
            {'function_name_to_materialization_map': {'main': SHAPES}, 'source_function_name': 'main'})
        PassPipelineManager.apply_pipeline(program, pipeline)
        program.export_as_multifunction = False
        after = describe(program.functions['main'], np, check)
        atomic(output / 'after-structure.json', after)
        require_shape_only(before, after)
        check()
        program.skip_all_passes = True
        candidate = mil_convert(program, convert_from='milinternal', convert_to='mlprogram',
            specification_version=spec.specificationVersion, compute_units=ct.ComputeUnit.CPU_ONLY,
            skip_model_load=True)
        destination = output / 'S3CFM-exact700.mlpackage'
        candidate.save(str(destination))
        reloaded = ct.models.MLModel(str(destination), skip_model_load=True, compute_units=ct.ComputeUnit.CPU_ONLY)
        saved_spec = reloaded.get_spec()
        if saved_spec.specificationVersion != spec.specificationVersion or set(saved_spec.mlProgram.functions) != {'main'}:
            raise ValueError('Changed specification/function contract')
        if saved_spec.description.functions or {v.name for v in saved_spec.description.input} != set(SHAPES):
            raise ValueError('Unexpected multifunction/input signature')
        original_types = {v.name: v.type.multiArrayType.dataType for v in spec.description.input}
        for entry in saved_spec.description.input:
            a = entry.type.multiArrayType
            if (list(a.shape) != list(SHAPES[entry.name]) or a.dataType != original_types[entry.name]
                    or a.HasField('shapeRange') or a.HasField('enumeratedShapes')):
                raise ValueError('Serialized signature is not exact and precision-preserving')
        saved = loader.load(saved_spec, saved_spec.specificationVersion, reloaded.weights_dir)
        serialized = describe(saved.functions['main'], np, check)
        atomic(output / 'serialized-structure.json', serialized)
        require_shape_only(before, serialized)
        files = final_package_files(destination, check)
        source_identity()
        check()
        report.update(structural_pass=True, pipeline=list(pipeline.passes),
            requires_separate_cpu_trajectory_qualification=True, package_files=files,
            source_model_sha256=MODEL_SHA, source_weights_sha256=WEIGHT_SHA,
            source_manifest_sha256=MANIFEST_SHA)
        check(); report['completed'] = True
        atomic(output / 'report.json', report)
    except BaseException as error:
        report.update(completed=False, error=str(error))
        atomic(output / 'report.json', report)
        raise


if __name__ == '__main__':
    main(json.loads(Path(sys.argv[1]).read_text()))
