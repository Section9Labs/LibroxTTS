import hashlib
import json
import os
from pathlib import Path
import struct
import signal
import subprocess
import sys
import tempfile
import unittest
import time
from unittest.mock import patch

import run_assembled_reference as study


class DriverTests(unittest.TestCase):
    def wait_file(self, path):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if path.exists():
                return json.loads(path.read_text())
            time.sleep(0.01)
        self.fail('Owned worker did not become ready')

    def worker(self, directory):
        worker = directory / 'worker.py'
        worker.write_text('#!' + sys.executable + '\n' + '''
import json, os, signal, subprocess, sys, time
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())
out = Path(config['outputDirectory']); out.mkdir()
ready = out / 'ready'
code = "import signal,sys,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path(sys.argv[1]).write_text('ready');time.sleep(30)"
child = subprocess.Popen([sys.executable, '-c', code, str(ready)])
while not ready.exists(): time.sleep(0.01)
(out / 'pids.json').write_text(json.dumps({'leader': os.getpid(), 'descendant': child.pid}))
time.sleep(30)
''')
        worker.chmod(0o700)
        return worker

    def test_append_rows_preserves_head_order(self):
        old = b''.join(bytes([head]) * 256 for head in range(32))
        delta = b''.join(bytes([head + 32]) * 128 for head in range(32))
        actual = study.append_rows(old, delta, 2, 1)
        wanted = b''.join(bytes([head]) * 256 + bytes([head + 32]) * 128 for head in range(32))
        self.assertEqual(actual, wanted)
        with self.assertRaises(ValueError):
            study.append_rows(old[:-1], delta, 2, 1)

    def test_tensor_identity_bounds_and_finite_values(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(study, 'RUN_ROOT', Path(directory)):
            path = Path(directory) / 'fixture.safetensors'

            def put(header, payload):
                raw = json.dumps(header).encode()
                data = struct.pack('<Q', len(raw)) + raw + payload
                path.write_bytes(data)
                return hashlib.sha256(data).hexdigest()

            header = {'a': {'dtype': 'F16', 'shape': [1], 'data_offsets': [0, 2]}}
            sha = put(header, struct.pack('<e', 1.5))
            self.assertEqual(bytes(study.tensors(path, sha)['a'][2]), struct.pack('<e', 1.5))
            with self.assertRaises(ValueError):
                study.tensors(path, '0' * 64)
            overlap = dict(header, b={'dtype': 'F16', 'shape': [1], 'data_offsets': [0, 2]})
            sha = put(overlap, struct.pack('<e', 1.5))
            with self.assertRaises(ValueError):
                study.tensors(path, sha)
            sha = put(header, struct.pack('<e', float('nan')))
            with self.assertRaises(ValueError):
                study.tensors(path, sha)
            with self.assertRaises(ValueError):
                study.owned(Path(directory).parent / 'unowned')

    def test_status_io_failure_drains_entire_owned_group(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(study, 'RUN_ROOT', Path(directory)):
            root = Path(directory); worker = self.worker(root)
            output = root / 'job'; program = root / 'program'; program.mkdir()
            real_write = study.write
            children = []
            real_popen = subprocess.Popen

            def popen(*args, **kwargs):
                child = real_popen(*args, **kwargs); children.append(child); return child

            def failed_status(path, value):
                if path == program / 'status.json':
                    self.wait_file(output / 'pids.json')
                    raise OSError('forced post-Popen status failure')
                return real_write(path, value)

            try:
                with patch.object(study.subprocess, 'Popen', side_effect=popen), patch.object(study, 'write', side_effect=failed_status):
                    with self.assertRaises(OSError):
                        study.run_job(worker, study.digest(worker), {'outputDirectory': str(output)}, output, program)
                self.assertEqual(len(children), 1)
                self.assertEqual(children[0].returncode, -signal.SIGTERM,
                                 'Leader must receive TERM; an inherited blocked mask would require KILL')
                self.assertFalse(study.group_alive(children[0].pid))
            finally:
                for child in children:
                    if study.group_alive(child.pid):
                        os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=3)

    def test_supervisor_sigterm_cancels_owned_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); worker = self.worker(root)
            output = root / 'job'; program = root / 'program'; program.mkdir()
            code = ('from pathlib import Path;import run_assembled_reference as s;'
                    f's.RUN_ROOT=Path({str(root)!r});s.install_signal_handlers();'
                    f's.run_job(Path({str(worker)!r}),{study.digest(worker)!r},'
                    f'{{"outputDirectory":{str(output)!r}}},Path({str(output)!r}),Path({str(program)!r}))')
            controller = subprocess.Popen([sys.executable, '-c', code], cwd=Path(__file__).parent,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            group = None
            try:
                group = self.wait_file(output / 'pids.json')['leader']
                controller.send_signal(signal.SIGTERM)
                self.assertNotEqual(controller.wait(timeout=5), 0)
                self.assertFalse(study.group_alive(group))
            finally:
                if group is not None and study.group_alive(group):
                    os.killpg(group, signal.SIGKILL)
                if controller.poll() is None:
                    controller.kill()
                controller.wait(timeout=3)

    def test_changed_receipt_and_equal_wrong_length_trajectories_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(study, 'RUN_ROOT', Path(directory)):
            root = Path(directory); dirs = [root / 'full', root / 'chunks']
            hashes = []
            for path, arm in zip(dirs, ('reference-full', 'reference-chunks')):
                path.mkdir()
                report = {'completed': True, 'case': 'en-short', 'arm': arm,
                          'input_vectors_sha256': study.INPUT_SHA, 'prefill_rows': 81,
                          'prefix_chunk_rows': 81 if arm == 'reference-full' else 64,
                          'actual_maximum_position': 88, 'forward_calls': 9 if arm == 'reference-full' else 10}
                study.write(path / 'report.json', report); hashes.append(study.digest(path / 'report.json'))
            with self.assertRaisesRegex(ValueError, 'Wrong frozen trajectory'):
                study.verify_pair(*dirs, 'en-short', hashes, ('regression-sha', 'case-sha'))
            with self.assertRaisesRegex(ValueError, 'Changed pinned JSON'):
                study.verify_pair(*dirs, 'en-short', ('0' * 64, hashes[1]), ('regression-sha', 'case-sha'))

    def test_post_run_seal_binds_exact_pair_and_reference_receipts(self):
        # Isolate the binding layer; the raw/cache verifier has separate real
        # payload tests. This mock produces no neural evidence or production data.
        with tempfile.TemporaryDirectory() as directory, patch.object(study, 'RUN_ROOT', Path(directory)):
            root = Path(directory); program = root / 'program'; program.mkdir()
            manifest = {'run_root': str(root), 'program_directory': str(program), 'job_version': 'v99',
                        'regression_control_sha256': 'regression-sha', 'runtime_metallib_sha256': 'runtime-sha'}
            manifest_file = root / 'manifest.json'; study.write(manifest_file, manifest)
            entries, summaries = [], {}
            for case in study.CASES:
                for stage in ('native-controls', 'reference-full', 'reference-chunks'):
                    name = 'assembled-native-controls-' + case + '-v99' if stage == 'native-controls' else 'assembled-' + case + '-' + stage + '-v99'
                    path = root / name; path.mkdir()
                    value = {'completed': True, 'case': case, 'all_trace_boundaries_bit_identical': True,
                             'runtime_metallib_sha256': 'runtime-sha', 'logits_sha256': case + '-logits'}
                    study.write(path / 'report.json', value)
                    entries.append({'case': case, 'stage': stage, 'report_sha256': study.digest(path / 'report.json')})
                summaries[case] = {'case': case, 'completed': True, 'full_chunk_logits_bit_identical': True,
                                   'all_active_cache_bits_reconstructed_and_identical': True, 'logits_compared': 9,
                                   'cache_stages': 9, 'maximum_offset': study.LENGTHS[case] + 8}
                study.write(program / (case + '-full-chunk-comparison.json'), summaries[case])
            report = {'completed': True, 'reference_cases': 6, 'full_chunk_comparisons': 54,
                      'gpu_candidate_comparisons': 0, 'finished': entries}
            report_file = program / 'report.json'; study.write(report_file, report)
            manifest_sha, report_sha = study.digest(manifest_file), study.digest(report_file)

            def verify(full, chunk, case, refs, controls):
                return summaries[case]

            output = root / 'seal.json'
            with patch.object(study, 'verify_pair', side_effect=verify), patch.object(study, 'install_signal_handlers'):
                study.seal_program(manifest_file, manifest_sha, report_file, report_sha, output)
                seal = json.loads(output.read_text())
                self.assertEqual(seal['program_report_sha256'], report_sha)
                self.assertEqual(len(seal['cases']), 6)
                for row in seal['cases']:
                    expected = next(x['report_sha256'] for x in entries if x['case'] == row['case'] and x['stage'] == 'reference-full')
                    self.assertEqual(row['full_reference_report_sha256'], expected)
                pair = program / 'en-short-full-chunk-comparison.json'
                study.write(pair, dict(summaries['en-short'], completed=False))
                with self.assertRaisesRegex(ValueError, 'Pair summary differs'):
                    study.seal_program(manifest_file, manifest_sha, report_file, report_sha, root / 'failed-seal.json')
                self.assertFalse((root / 'failed-seal.json').exists())


if __name__ == '__main__':
    unittest.main()
