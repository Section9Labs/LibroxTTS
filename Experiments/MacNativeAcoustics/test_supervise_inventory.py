import contextlib,hashlib,io,json,os,pathlib,signal,subprocess,sys,tempfile,time,unittest
from unittest.mock import patch
import owned_process as owner
import supervise_inventory as s

class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.handlers={n:signal.getsignal(n) for n in (signal.SIGTERM,signal.SIGINT)}
        owner._stop_signal=None
    def tearDown(self):
        for n,h in self.handlers.items():signal.signal(n,h)
        owner._stop_signal=None
    def testSignalAtPopenAssignmentJoinsOwnedChild(self):
        owner.install_signal_handlers();original=subprocess.Popen;spawned=[]
        def launch(*a,**kw):
            child=original(*a,**kw);spawned.append(child);os.kill(os.getpid(),signal.SIGTERM);return child
        with self.assertRaises(InterruptedError):
            s.launch_owned([sys.executable,'-c','import time; time.sleep(30)'],factory=launch,start_new_session=True)
        self.assertEqual(len(spawned),1)
        self.assertIsNotNone(spawned[0].poll());self.assertFalse(owner.group_alive(spawned[0].pid))
    def testTermIgnoringChildIsKilledAndJoined(self):
        with tempfile.TemporaryDirectory() as tmp:
            ready=pathlib.Path(tmp)/'ready'
            code='import signal,time,pathlib;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path('+repr(str(ready))+').write_text("ready");time.sleep(30)'
            child=subprocess.Popen([sys.executable,'-c',code],start_new_session=True)
            try:
                end=time.monotonic()+2
                while not ready.exists() and time.monotonic()<end:time.sleep(.01)
                self.assertTrue(ready.exists());start=time.monotonic();owner.terminate_owned(child)
                self.assertLess(time.monotonic()-start,2.2);self.assertIsNotNone(child.poll());self.assertFalse(owner.group_alive(child.pid))
            finally:
                if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait(timeout=1)
    def testManifestRejectionPublishesTerminalFailureWithoutSpawn(self):
        with tempfile.TemporaryDirectory() as tmp,patch.object(s,'ROOT',pathlib.Path(tmp)):
            root=pathlib.Path(tmp)/'native-swift-acoustic-inventory-v01';root.mkdir();manifest=root/'manifest.json';manifest.write_text('{}')
            with patch.object(s,'launch_owned') as launch,contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(s.run(manifest,'0'*64),1);launch.assert_not_called()
            result=json.loads((root/'supervisor-result.json').read_text());self.assertEqual(result['state'],'failed')
            self.assertIn('Changed consumed manifest',result['failure'])
            with self.assertRaises(ValueError):s.run(manifest,hashlib.sha256(b'{}').hexdigest())
    def testExitedLeaderDoesNotHideTermIgnoringDescendant(self):
        with tempfile.TemporaryDirectory() as tmp:
            ready=pathlib.Path(tmp)/'ready'
            grand='import signal,time,pathlib;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path('+repr(str(ready))+').write_text("ready");time.sleep(30)'
            parent='import subprocess,sys,time,pathlib;subprocess.Popen([sys.executable,"-c",'+repr(grand)+']);p=pathlib.Path('+repr(str(ready))+');end=time.monotonic()+2\nwhile not p.exists() and time.monotonic()<end:time.sleep(.01)'
            child=subprocess.Popen([sys.executable,'-c',parent],start_new_session=True)
            try:
                child.wait(timeout=3);self.assertTrue(ready.exists());self.assertTrue(owner.group_alive(child.pid))
                owner.terminate_owned(child);self.assertFalse(owner.group_alive(child.pid))
            finally:
                if owner.group_alive(child.pid):os.killpg(child.pid,signal.SIGKILL)
                child.wait(timeout=1)
    def testMissingGroupStillJoinsOwnedLeader(self):
        child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True)
        try:
            with patch.object(owner,'group_alive',return_value=False):owner.terminate_owned(child)
            self.assertIsNotNone(child.poll());self.assertFalse(owner.group_alive(child.pid))
        finally:
            if child.poll() is None:child.kill();child.wait(timeout=1)
    def testEpermRequiresVerifiedNumericMembership(self):
        with patch.object(os,'killpg',side_effect=PermissionError()):
            for text,wanted in [('4 5 42\n',True),('4 5\n',False)]:
                with patch.object(subprocess,'run',return_value=type('P',(),{'returncode':0,'stdout':text})()):
                    self.assertEqual(owner.group_alive(42),wanted)
            for code,text in [(1,''),(0,''),(0,'bad')]:
                with patch.object(subprocess,'run',return_value=type('P',(),{'returncode':code,'stdout':text})()):
                    with self.assertRaises((RuntimeError,ValueError)):owner.group_alive(42)
    def testBoundedReadRejectsBeforeAllocatingFullInput(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=pathlib.Path(tmp)/'data';path.write_bytes(b'12345')
            self.assertEqual(s.capped_read(path,5),b'12345')
            with self.assertRaises(ValueError):s.capped_read(path,4)
    def testGuardChecksAreNotOptimizationDependentAssertions(self):
        with self.assertRaises(ValueError):s.require(False,'expected')
        with patch.object(subprocess,'run',return_value=type('P',(),{'returncode':1,'stdout':''})()):
            with self.assertRaises(ValueError):s.available_bytes()

if __name__=='__main__':unittest.main()
