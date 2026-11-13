"""The API gate must ignore ordering, but reject real signature/availability drift."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CHECKER = Path(__file__).resolve().parents[1] / 'check-public-api.py'

class PublicAPICheckerTests(unittest.TestCase):
    def setUp(self):
        self.baseline = dict(module='Example', usr='s:Example', path=['Example'], declaration='class Example',
            availability=[dict(domain='iOS', introduced=dict(major=18, minor=0)),
                          dict(domain='macOS', introduced=dict(major=15, minor=0))])

    def compare(self, rows, additions=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'baseline.json').write_text(json.dumps(dict(symbols=[self.baseline])))
            graphs = root/'graphs'; graphs.mkdir()
            symbols = [dict(accessLevel='public', identifier=dict(precise=r['usr']), pathComponents=r['path'],
                            declarationFragments=[dict(spelling=r['declaration'])], availability=r['availability']) for r in rows]
            (graphs/'Example.json').write_text(json.dumps(dict(module=dict(name='Example'), symbols=symbols)))
            arguments = [sys.executable, str(CHECKER), '--baseline', str(root/'baseline.json'), '--graphs', str(graphs)]
            if additions is not None:
                (root/'additions.json').write_text(json.dumps(dict(symbols=additions)))
                arguments += ['--additions', str(root/'additions.json')]
            return subprocess.run(arguments,
                                  capture_output=True, text=True)

    def testReviewedAdditionsAreExactAndCannotOverrideBaseline(self):
        added = copy.deepcopy(self.baseline); added['usr'] = 's:Added'
        self.assertEqual(self.compare([self.baseline, added], additions=[added]).returncode, 0)
        changed = copy.deepcopy(added); changed['declaration'] = 'actor Added'
        self.assertNotEqual(self.compare([self.baseline, changed], additions=[added]).returncode, 0)
        self.assertNotEqual(self.compare([self.baseline], additions=[added]).returncode, 0)
        self.assertNotEqual(self.compare([self.baseline], additions=[self.baseline]).returncode, 0)

    def testPlatformClauseOrderIsNotAnAPIChange(self):
        row = copy.deepcopy(self.baseline); row['availability'].reverse()
        result = self.compare([row])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('0 missing, 0 added, 0 changed', result.stdout)

    def testAvailabilityChangesStillFail(self):
        for mutation in ['version', 'removed', 'deprecated', 'duplicate']:
            with self.subTest(mutation=mutation):
                row = copy.deepcopy(self.baseline)
                if mutation == 'version': row['availability'][0]['introduced']['major'] = 19
                elif mutation == 'removed': row['availability'].pop()
                elif mutation == 'deprecated': row['availability'][0]['deprecated'] = dict(major=19)
                else: row['availability'].append(copy.deepcopy(row['availability'][0]))
                result = self.compare([row])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('1 changed', result.stdout)
                self.assertIn('availability: expected=', result.stdout)

    def testSignatureAdditionAndRemovalStillFail(self):
        changed = copy.deepcopy(self.baseline); changed['declaration'] = 'actor Example'
        added = copy.deepcopy(self.baseline); added['usr'] = 's:Other'
        for rows, expected in [([changed], '1 changed'), ([self.baseline, added], '1 added'), ([], '1 missing')]:
            with self.subTest(expected=expected):
                result = self.compare(rows)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stdout)

if __name__ == '__main__':
    unittest.main()
