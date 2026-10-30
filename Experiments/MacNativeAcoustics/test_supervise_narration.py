import contextlib,io,json,pathlib,tempfile,unittest
from unittest.mock import patch
import supervise_narration as s

class NarrationSupervisorTests(unittest.TestCase):
    def testWrongManifestIsTerminalAndCannotSpawnOrRestart(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(s,'ROOT',pathlib.Path(tmp)):
            root=pathlib.Path(tmp)/'native-full-narration-v01';root.mkdir();manifest=root/'manifest.json';manifest.write_text('{}')
            with patch.object(s.subprocess,'Popen') as launch,contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(s.run(manifest,'0'*64),1);launch.assert_not_called()
            r=json.loads((root/'supervisor-result.json').read_text());self.assertEqual(r['state'],'failed');self.assertFalse(r['automatic_restart'])
            with self.assertRaises(ValueError):s.run(manifest,'0'*64)
    def testBoundedReportReadRejectsOversizedBytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=pathlib.Path(tmp)/'report';p.write_bytes(b'12345')
            self.assertEqual(s.read(p,5),b'12345')
            with self.assertRaises(ValueError):s.read(p,4)

if __name__=='__main__':unittest.main()
