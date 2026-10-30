#!/usr/bin/env python3
"""One owned, bounded graph-specialization child; no auto restart."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path('/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01')


def main(manifest_path, expected_sha):
    # Import only the previously tested lifecycle/receipt helpers. No Core ML
    # model or Python conversion module is initialized by these helpers.
    directory = Path(__file__).resolve().parent
    helper = directory / 'run_assembled_reference.py'
    if hashlib.sha256(helper.read_bytes()).hexdigest() != '6f12126fe1789d04d1e73df2b11100ea763a2517e77fc58416955f4ef549a2a4':
        raise ValueError('Changed lifecycle helper')
    sys.path.insert(0, str(directory))
    import run_assembled_reference as owner
    owner.install_signal_handlers()
    manifest, _ = owner.pinned_json(Path(manifest_path), expected_sha)
    if owner.digest(Path(__file__)) != manifest['supervisor_sha256']:
        raise ValueError('Changed frozen supervisor')
    scope = manifest.get('scope', 'structural')
    if scope != 'weight_coverage':
        raise ValueError('Unreviewed supervisor scope')
    budget = 180
    if manifest.get('budget_seconds', budget) != budget:
        raise ValueError('Wrong scope budget')
    script = owner.owned(manifest['script'])
    if owner.digest(script) != manifest['script_sha256']:
        raise ValueError('Changed frozen converter')
    python = Path(manifest['python'])
    if owner.digest(python) != manifest['python_sha256']:
        raise ValueError('Changed interpreter')
    output = owner.owned(manifest['outputDirectory'])
    program = owner.owned(manifest['programDirectory'])
    if output.parent != ROOT.resolve() or output.exists() or program.exists():
        raise ValueError('Existing or unowned output')
    guard_module = owner.owned(manifest.get('guard_module', str(script)))
    if owner.digest(guard_module) != manifest.get('guard_module_sha256', manifest['script_sha256']):
        raise ValueError('Changed frozen host guard')
    spec = importlib.util.spec_from_file_location('frozen_converter', guard_module)
    converter = importlib.util.module_from_spec(spec); spec.loader.exec_module(converter)
    host_guard = converter.HostGuard(); host_guard()
    program.mkdir()
    config_file = program / 'config.json'
    owner.write(config_file, {**manifest['configuration'], 'outputDirectory': str(output)})
    child = None
    started = time.monotonic()
    peak = 0
    log = program / 'child.log'
    owner.write(program / 'report.json', {'completed': False, 'manifest_sha256': expected_sha, 'automatic_restart': False})
    try:
        owner.check_stop()
        with log.open('xb') as stream:
            child = subprocess.Popen([str(python), str(script), str(config_file)],
                stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                start_new_session=True)
            owner.write(program / 'status.json', {'state': 'running', 'owned_child_pid': child.pid,
                'manifest_sha256': expected_sha, 'deadline_seconds': budget})
            next_check = 0.0
            while child.poll() is None:
                owner.check_stop()
                now = time.monotonic()
                if now - started >= budget:
                    raise TimeoutError('Owned conversion deadline')
                if now >= next_check:
                    host_guard()
                    value = subprocess.run(['/bin/ps', '-p', str(child.pid), '-o', 'rss='],
                        capture_output=True, text=True, timeout=1)
                    text = value.stdout.strip()
                    if text:
                        rss = int(text) * 1024; peak = max(peak, rss)
                        if rss > 8 * 1024**3:
                            raise RuntimeError('Owned conversion memory guard')
                    elif child.poll() is None:
                        raise RuntimeError('Cannot verify owned child memory')
                    if shutil.disk_usage(ROOT).free < 1024**3:
                        raise RuntimeError('Owned conversion storage guard')
                    next_check = now + 1
                try: child.wait(timeout=0.1)
                except subprocess.TimeoutExpired: pass
            owner.check_stop()
            if child.returncode != 0 or owner.group_alive(child.pid):
                raise RuntimeError('Terminal converter failure or unexpected descendants')
        host_guard()
        report, report_sha = owner.receipt(output / 'report.json')
        if report.get('predictions') != 0 or report.get('model_constructions') != 1 or not report.get('all_components_pass'):
            raise ValueError('Wrong conversion scope receipt')
        owner.write(program / 'status.json', {'state': 'complete', 'owned_child_absent': True,
            'report_commit_required': True})
        owner.check_stop(); host_guard()
        if shutil.disk_usage(ROOT).free < 1024**3:
            raise RuntimeError('Storage guard before publication')
        if time.monotonic() - started >= budget:
            raise TimeoutError('Expired before supervisor publication')
        owner.write(program / 'report.json', {'completed': True, 'manifest_sha256': expected_sha,
            'child_report_sha256': report_sha, 'peak_child_rss_bytes': peak,
            'wall_seconds': time.monotonic() - started, 'phone_audio_or_speed_clearance': False})
    except BaseException as error:
        if child is not None: owner.terminate_owned(child)
        owner.write(program / 'report.json', {'completed': False, 'error': str(error),
            'manifest_sha256': expected_sha, 'automatic_restart': False})
        owner.write(program / 'status.json', {'state': 'terminal_failure', 'automatic_restart': False})
        raise


if __name__ == '__main__': main(sys.argv[1], sys.argv[2])
