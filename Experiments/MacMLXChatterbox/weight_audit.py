"""Offline load coverage only. No forward, waveform, oracle or runtime selection."""
from pathlib import Path
import hashlib
import importlib.util
import json
import resource
import sys
import time

ROOT = Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01')


def sha(path):
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def write(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def compare_specs(expected, actual):
    """Require every parameter and reject unknown checkpoint values as well."""
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    mismatch = [dict(name=k, expected=expected[k], actual=actual[k])
                for k in sorted(set(expected) & set(actual)) if expected[k] != actual[k]]
    return dict(missing=missing, unexpected=extra, mismatches=mismatch,
                expected_count=len(expected), actual_count=len(actual),
                passed=not (missing or extra or mismatch))


def main(config):
    began = time.monotonic()
    out = Path(config['outputDirectory']).resolve()
    if out.parent != ROOT.resolve() or out.exists():
        raise ValueError('New directly owned output required')
    for path, expected in config['source_hashes'].items():
        if sha(path) != expected:
            raise ValueError('Changed source/interpreter before import')
    spec = importlib.util.spec_from_file_location('frozen_host_guard', config['guard_module'])
    guard_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard_module)
    host_guard = guard_module.HostGuard()

    def check():
        host_guard()
        if time.monotonic() - began >= 180 or resource.getrusage(resource.RUSAGE_SELF).ru_maxrss > 8 * 1024**3:
            raise RuntimeError('Owned time/RSS guard')

    check()
    out.mkdir()
    report = dict(completed=False, predictions=0, audio_or_phone_clearance=False,
                  qualification_scope='CPU metadata/strict-load coverage plus declared constructor table evaluation; GPU must be a fresh process',
                  constructor_cpu_table_evaluation_allowed={'source': 'mlx_audio/codec/models/s3/model_v2.py',
                      'operation': 'precompute_freqs_cis then mx.eval',
                      'tables': 2, 'shape_each': [2048, 64], 'dtype': 'float32'},
                  model_constructions=0, all_components_pass=False, stages=[])
    write(out / 'report.json', report)
    try:
        for path, expected in config['asset_hashes'].items():
            check()
            if sha(path) != expected:
                raise ValueError('Changed pinned model/stock asset')
        check()
        import mlx.core as mx
        mx.set_default_device(mx.cpu)
        from mlx.utils import tree_flatten
        from mlx_audio.tts.models.chatterbox.chatterbox import Model
        from mlx_audio.tts.models.chatterbox.config import ModelConfig
        directory = Path(config['modelDirectory'])
        model_config = json.loads((directory / 'config.json').read_text())
        if (model_config.get('quantization') or model_config.get('t3_model') != 'v3'
                or model_config.get('text_preprocessing') != 'NFKD,fullcase'):
            raise ValueError('Not the full-precision V3 candidate')
        model = Model(ModelConfig.from_dict(model_config))
        report['model_constructions'] = 1
        check()
        combined = mx.load(str(directory / 'model.safetensors'))
        if any(not k.startswith(('ve.', 't3.', 's3gen.')) for k in combined):
            raise ValueError('Unassigned combined model tensors')
        s3 = mx.load(str(Path(config['tokenizerDirectory']) / 'model.safetensors'))
        # Array shapes/dtypes are metadata. The S3 constructor's two small CPU
        # table evaluations above are preregistered; no model forward or further
        # parameter eval is allowed. Strict loading cannot retain random weights.
        for prefix, component, raw in [
            ('ve', model.ve, {k[3:]: v for k, v in combined.items() if k.startswith('ve.')}),
            ('t3', model.t3, {k[3:]: v for k, v in combined.items() if k.startswith('t3.')}),
            ('s3gen', model.s3gen, {k[6:]: v for k, v in combined.items() if k.startswith('s3gen.')}),
            ('s3tokenizer', model._s3_tokenizer, s3),
        ]:
            check()
            actual = component.sanitize(raw) if hasattr(component, 'sanitize') else raw
            def specs(items):
                return {k: dict(shape=list(v.shape), dtype=str(v.dtype)) for k, v in items}
            result = compare_specs(specs(tree_flatten(component.parameters())), specs(actual.items()))
            result['component'] = prefix
            result['strict_load_passed'] = False
            report['stages'].append(result)
            write(out / 'report.json', report)
            if result['passed']:
                component.load_weights(list(actual.items()), strict=True)
                result['strict_load_passed'] = True
            write(out / 'report.json', report)
        if len(report['stages']) != 4 or not all(x['passed'] and x['strict_load_passed'] for x in report['stages']):
            raise ValueError('Complete strict parameter coverage failed; no forward allowed')
        stock = mx.load(config['stockConditioning'])
        expected_stock = {'gen.embedding': ([192], 'mlx.core.float32'),
                          'gen.prompt_feat': ([314, 80], 'mlx.core.float32'),
                          'gen.prompt_token': ([157], 'mlx.core.int32'),
                          'gen.prompt_token_len': ([1], 'mlx.core.int32'),
                          't3.speaker_emb': ([256], 'mlx.core.float32'),
                          't3.cond_prompt_speech_tokens': ([150], 'mlx.core.int32')}
        stock_result = compare_specs(
            {k: dict(shape=s, dtype=t) for k, (s, t) in expected_stock.items()}, specs(stock.items()))
        report['stock_conditioning'] = stock_result
        if not stock_result['passed']:
            raise ValueError('Stock conditioning metadata mismatch')
        # Rebind all inputs and code after load and immediately before receipt.
        for path, expected in {**config['asset_hashes'], **config['source_hashes']}.items():
            check()
            if sha(path) != expected:
                raise ValueError('Changed frozen bytes during audit')
        check()
        report.update(all_components_pass=True, completed=True, elapsed_seconds=time.monotonic() - began)
        write(out / 'report.json', report)
    except BaseException as error:
        report.update(completed=False, error=str(error), automatic_restart=False)
        write(out / 'report.json', report)
        raise


if __name__ == '__main__':
    main(json.loads(Path(sys.argv[1]).read_text()))
