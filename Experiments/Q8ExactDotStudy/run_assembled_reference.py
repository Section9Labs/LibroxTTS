"""Finite, sequential off-phone controls/reference program; never selects an app oracle."""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import time

RUN_ROOT = Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01')
CASES = ('en-short', 'en-boundary', 'en-long', 'es-short', 'es-boundary', 'es-long')
LENGTHS = dict(zip(CASES, (80, 251, 501, 87, 252, 503)))
INPUT_SHA = '2d20b5932df08b022cbd95e5713de5f5f1c0b15fcebde04801f42b6a0584baf7'
PREREG_SHA = '7bf0b7d723603fb34b161e3d545a279a3d0487e86e1c987548d01671253bc12b'
SOURCE = Path('/Users/matt/Code/swift/librox-tts-chatterbox')
_stop_signal = None


def check_stop():
    if _stop_signal is not None:
        raise InterruptedError('Controlled stop signal ' + str(_stop_signal))


def digest(path):
    check_stop()
    with Path(path).open('rb') as handle:
        return hashlib.file_digest(handle, 'sha256').hexdigest()


def write(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def owned(path):
    path = Path(path).resolve()
    if not path.is_relative_to(RUN_ROOT.resolve()):
        raise ValueError('Path outside owned run root')
    return path


def pinned_json(path, expected_sha=None, maximum=16_777_216):
    check_stop()
    path = owned(path)
    with path.open('rb') as handle:
        data = handle.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError('Oversized receipt')
    sha = hashlib.sha256(data).hexdigest()
    if expected_sha is not None and sha != expected_sha:
        raise ValueError('Changed pinned JSON bytes')
    return json.loads(data), sha


def receipt(path, expected_sha=None):
    result, sha = pinned_json(path, expected_sha)
    if result.get('completed') is not True:
        raise ValueError('Incomplete or failed arm')
    return result, sha


def tensors(path, expected_sha):
    check_stop()
    path = owned(path)
    if not 8 < path.stat().st_size <= 134_217_728:
        raise ValueError('Tensor artifact size')
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected_sha:
        raise ValueError('Tensor artifact identity')
    size, = struct.unpack_from('<Q', data)
    if not 1 <= size <= 1_000_000 or size + 8 > len(data):
        raise ValueError('Tensor header')
    header = json.loads(data[8:8 + size])
    payload = memoryview(data)[8 + size:]
    result, ranges = {}, []
    for name, entry in header.items():
        check_stop()
        if name == '__metadata__':
            continue
        dtype, shape = entry['dtype'], entry['shape']
        if dtype not in ('F16', 'F32') or not shape or any(type(x) is not int or not 0 < x <= 8194 for x in shape):
            raise ValueError('Tensor type/shape')
        count = 1
        for dimension in shape:
            count *= dimension
        start, end = entry['data_offsets']
        width = 2 if dtype == 'F16' else 4
        if type(start) is not int or type(end) is not int or not 0 <= start < end <= len(payload) or end - start != count * width:
            raise ValueError('Tensor bounds')
        ranges.append((start, end))
        fmt = '<e' if dtype == 'F16' else '<f'
        if not all(math.isfinite(x[0]) for x in struct.iter_unpack(fmt, payload[start:end])):
            raise ValueError('Nonfinite artifact values')
        result[name] = (dtype, shape, payload[start:end])
    cursor = 0
    for start, end in sorted(ranges):
        if start != cursor:
            raise ValueError('Overlapping/gapped tensor payload')
        cursor = end
    if cursor != len(payload):
        raise ValueError('Unclaimed tensor payload')
    return result


def append_rows(previous, tail, old_rows, new_rows):
    stride = 64 * 2
    if len(previous) != 32 * old_rows * stride or len(tail) != 32 * new_rows * stride:
        raise ValueError('Cache append dimensions')
    return b''.join(bytes(previous[h * old_rows * stride:(h + 1) * old_rows * stride]) +
                    bytes(tail[h * new_rows * stride:(h + 1) * new_rows * stride]) for h in range(32))


def verify_pair(full_dir, chunk_dir, case, report_shas, control_shas):
    reports = [receipt(d / 'report.json', sha)[0] for d, sha in zip((full_dir, chunk_dir), report_shas)]
    if case not in LENGTHS or len(report_shas) != 2 or len(control_shas) != 2:
        raise ValueError('Comparison bindings')
    length = LENGTHS[case]
    wanted = {'prefill'} | {f'decode.{i}' for i in range(8)}
    logits = []
    for directory, report, arm in zip((full_dir, chunk_dir), reports, ('reference-full', 'reference-chunks')):
        if report.get('case') != case or report.get('arm') != arm:
            raise ValueError('Wrong case/arm receipt')
        if (report.get('input_vectors_sha256') != INPUT_SHA or report.get('prefill_rows') != length or
                report.get('prefix_chunk_rows') != (length if arm == 'reference-full' else 64) or
                report.get('actual_maximum_position') != length + 7 or
                report.get('forward_calls') != (9 if arm == 'reference-full' else (length + 63) // 64 + 8)):
            raise ValueError('Wrong frozen trajectory or chunk policy')
        bindings = report.get('consumed_native_controls', [])
        if [(b.get('case'), b.get('receipt_sha256')) for b in bindings] != list(zip(('regression', case), control_shas)):
            raise ValueError('Changed control binding')
        if len(report.get('cache_evidence', [])) != 9:
            raise ValueError('Missing/extra cache evidence')
        values = tensors(directory / 'diagnostic-logits.safetensors', report['logits_sha256'])
        if set(values) != wanted or any(x[0] != 'F32' or x[1] != [2, 8194] for x in values.values()):
            raise ValueError('Missing full-logit comparison')
        logits.append(values)
        stage_names = ['prefill'] + [f'decode.{i}' for i in range(8)]
        if [s.get('name') for s in report.get('stages', [])] != stage_names:
            raise ValueError('Logit stage membership')
        for index, stage in enumerate(report['stages']):
            if stage.get('cache_offset') != length + index:
                raise ValueError('Logit/cache offset')
            path = owned(directory / stage['raw_file'])
            if path.parent != directory.resolve():
                raise ValueError('Logit artifact traversal')
            raw = tensors(path, stage['raw_sha256'])
            if (set(raw) != {'logits'} or raw['logits'][:2] != values[stage['name']][:2] or
                    raw['logits'][2] != values[stage['name']][2] or
                    hashlib.sha256(raw['logits'][2]).hexdigest() != stage['logits_sha256']):
                raise ValueError('Per-stage logit evidence')
    for name in wanted:
        if logits[0][name][2] != logits[1][name][2]:
            raise ValueError('Full/chunk logit bits differ: ' + name)
    cache_names = {f'layer.{i}.{kind}' for i in range(30) for kind in ('keys', 'values')}
    active = [{}, {}]
    offsets = [0, 0]
    for stage in range(9):
        check_stop()
        for which, (directory, report) in enumerate(zip((full_dir, chunk_dir), reports)):
            entry = report['cache_evidence'][stage]
            rows, offset = entry['delta_rows'], entry['offset']
            if (entry['stage'] != ('prefill' if stage == 0 else f'decode.{stage - 1}') or
                    offset != length + stage or offset != offsets[which] + rows):
                raise ValueError('Cache stage/offset')
            if stage > 0 and (rows != 1 or entry.get('prefix_unchanged') is not True):
                raise ValueError('Missing append-only control')
            path = owned(directory / entry['file'])
            if path.parent != directory.resolve():
                raise ValueError('Cache artifact traversal')
            delta = tensors(path, entry['file_sha256'])
            if set(delta) != cache_names:
                raise ValueError('Cache membership')
            hashes = {f"layer.{x['layer']}.{x['kind']}": x for x in entry['tensors']}
            if set(hashes) != cache_names or len(entry['tensors']) != 60:
                raise ValueError('Cache hash membership')
            for name, (dtype, shape, tail) in delta.items():
                if dtype != 'F16' or shape != [2, 16, rows, 64]:
                    raise ValueError('Cache tensor shape')
                previous = active[which].get(name, b'')
                combined = append_rows(previous, tail, offsets[which], rows)
                h = hashes[name]
                if (h['active_half_count'] != len(combined) // 2 or hashlib.sha256(combined).hexdigest() != h['active_sha256'] or
                        hashlib.sha256(tail).hexdigest() != h['delta_sha256']):
                    raise ValueError('Reconstructed active-cache identity')
                active[which][name] = combined
            offsets[which] = offset
        if offsets[0] != offsets[1] or active[0] != active[1]:
            raise ValueError('Full/chunk cache bits differ at stage ' + str(stage))
    return {'case': case, 'completed': True, 'full_chunk_logits_bit_identical': True,
            'all_active_cache_bits_reconstructed_and_identical': True, 'logits_compared': 9,
            'cache_stages': 9, 'maximum_offset': offsets[0]}


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False


def terminate_owned(child):
    # Popen created this session/process group. Drain the group, not merely its
    # leader, and protect the bounded cleanup against repeated TERM/INT signals.
    handlers = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            child.poll()
            if not group_alive(child.pid):
                return
            try:
                os.killpg(child.pid, sig)
            except ProcessLookupError:
                return
            end = time.monotonic() + 1
            while time.monotonic() < end:
                child.poll()
                if not group_alive(child.pid):
                    return
                time.sleep(0.01)
        child.poll()
        if group_alive(child.pid):
            raise RuntimeError('Owned process group failed bounded cleanup')
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def install_signal_handlers():
    def stop(signum, frame):
        # Never raise asynchronously across Popen construction/assignment.
        # The owned wait loop observes this request inside its cleanup scope.
        global _stop_signal
        _stop_signal = signum
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)


def run_job(executable, executable_sha, config, output, program):
    check_stop()
    if digest(executable) != executable_sha or output.exists():
        raise ValueError('Changed binary or existing arm; no automatic retry')
    config_file = owned(output.with_name(output.name + '-config.json'))
    if config_file.exists():
        raise ValueError('Existing planned job config')
    write(config_file, config)
    log = output.with_name(output.name + '.log')
    environment = dict(os.environ, MLX_ENABLE_TF32='0', CHATTERBOX_SYNTH_SEED='42')
    with log.open('xb') as handle:
        child = None
        try:
            child = subprocess.Popen([str(executable), str(config_file)], cwd=SOURCE, env=environment,
                                     stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
            check_stop()
            write(program / 'status.json', {'state': 'running', 'child_pid': child.pid, 'active_output': str(output),
                                          'config_sha256': digest(config_file), 'binary_sha256': executable_sha})
            # The Swift arm enforces its unchanged180s shared budget and<=2s
            # resolver cleanup. This outer watchdog also includes process/file
            # startup and never turns a timed-out arm into a completed receipt.
            end = time.monotonic() + 200
            while child.poll() is None:
                check_stop()
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(child.args, 200)
                try:
                    child.wait(timeout=min(remaining, 0.1))
                except subprocess.TimeoutExpired:
                    pass
            check_stop()
            code = child.returncode
            if code != 0 or group_alive(child.pid):
                raise RuntimeError('Terminal arm failure or unexpected descendants: ' + output.name)
        except BaseException:
            if child is not None:
                terminate_owned(child)
            raise
    return receipt(output / 'report.json')


def main(manifest_file, manifest_sha):
    install_signal_handlers()
    manifest_file = owned(manifest_file)
    manifest, actual_manifest_sha = pinned_json(manifest_file, manifest_sha, maximum=1_048_576)
    pinned_json(owned(manifest['preregistration']), PREREG_SHA, maximum=1_048_576)
    if digest(Path(__file__)) != manifest['driver_sha256']:
        raise ValueError('Driver source identity')
    program = owned(manifest['program_directory'])
    program.mkdir(exist_ok=False)
    write(program / 'lease.json', {'pid': os.getpid(), 'manifest_sha256': actual_manifest_sha, 'created': time.time()})
    executable = owned(manifest['executable'])
    binary_sha = manifest['executable_sha256']
    base = manifest['base_configuration']
    root = owned(manifest['run_root'])
    regression = owned(manifest['regression_control'])
    completed = []
    try:
        regression_sha = manifest['regression_control_sha256']
        if receipt(regression, regression_sha)[0].get('old22_bit_identical') is not True:
            raise ValueError('Regression control prerequisite')
        controls = {}
        for case in CASES:
            check_stop()
            output = root / ('assembled-native-controls-' + case + '-v01')
            config = dict(base, profile='local-q8-assembly-native-controls', referenceAssemblyCase=case,
                          outputDirectory=str(output))
            result, report_sha = run_job(executable, binary_sha, config, output, program)
            if result.get('case') != case or result.get('all_trace_boundaries_bit_identical') is not True:
                raise ValueError('Native control outcome')
            controls[case] = (output / 'report.json', report_sha)
            completed.append({'stage': 'native-controls', 'case': case, 'report_sha256': report_sha})
            write(program / 'progress.json', {'completed': False, 'finished': completed})
        for case in CASES:
            check_stop()
            directories, report_shas = [], []
            receipt(regression, regression_sha)
            receipt(*controls[case])
            for arm in ('reference-full', 'reference-chunks'):
                output = root / ('assembled-' + case + '-' + arm + '-v01')
                config = dict(base, profile='local-q8-assembled-reference', referenceAssemblyCase=case,
                              referenceAssemblyArm=arm, outputDirectory=str(output),
                              referenceAssemblyRegressionControl=str(regression),
                              referenceAssemblyRegressionControlSHA256=regression_sha,
                              referenceAssemblyCaseControl=str(controls[case][0]), referenceAssemblyCaseControlSHA256=controls[case][1])
                result, report_sha = run_job(executable, binary_sha, config, output, program)
                directories.append(output)
                report_shas.append(report_sha)
                completed.append({'stage': arm, 'case': case, 'report_sha256': report_sha})
                write(program / 'progress.json', {'completed': False, 'finished': completed})
            pair = verify_pair(*directories, case, report_shas, (regression_sha, controls[case][1]))
            write(program / (case + '-full-chunk-comparison.json'), pair)
        check_stop()
        write(program / 'status.json', {'state': 'complete', 'next': 'independent review, then freshGPUcandidate qualification'})
        check_stop()
        write(program / 'report.json', {'completed': True, 'finished': completed, 'reference_cases': 6,
                                      'full_chunk_comparisons': 54, 'gpu_candidate_comparisons': 0,
                                      'production_clearance': False, 'audio_generated': False})
    except BaseException as error:
        write(program / 'progress.json', {'completed': False, 'finished': completed, 'error': repr(error)})
        write(program / 'status.json', {'state': 'terminal_failure', 'error': repr(error), 'automatic_restart': False})
        raise


if __name__ == '__main__':
    main(Path(sys.argv[1]), sys.argv[2])
