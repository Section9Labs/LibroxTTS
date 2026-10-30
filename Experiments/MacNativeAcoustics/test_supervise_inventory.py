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
            root=pathlib.Path(tmp)/'native-swift-acoustic-inventory-v02';root.mkdir();manifest=root/'manifest.json';manifest.write_text('{}')
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
    def testEpermRequiresVerifiedNativeMembership(self):
        with patch.object(os,'killpg',side_effect=PermissionError()):
            for members,wanted in [([42],True),([],False)]:
                fake=type('N',(),{'group_members':lambda _,pid:members})()
                with patch.object(owner.native_resources,'shared',return_value=fake):
                    self.assertEqual(owner.group_alive(42),wanted)
            fake=type('N',(),{'group_members':lambda _,pid:(_ for _ in ()).throw(RuntimeError('query failed'))})()
            with patch.object(owner.native_resources,'shared',return_value=fake):
                with self.assertRaises(RuntimeError):owner.group_alive(42)
    def testNativeQueriesMatchOwnedLiveProcessAndFailClosed(self):
        native=owner.native_resources.shared()
        self.assertGreater(native.rss(os.getpid()),0)
        self.assertIn(os.getpid(),native.group_members(os.getpgrp()))
        self.assertGreater(native.available_bytes(),0)
        with self.assertRaises(RuntimeError):native.rss(2147483647)
        with patch.object(native.proc,'proc_pidinfo',return_value=0):
            with self.assertRaises(RuntimeError):native.rss(os.getpid())
        for count,values in [(4,[0]),(3,[42]),(16384,[42]),(-1,[])]:
            def query(kind,pid,buffer,size):
                for i,v in enumerate(values):buffer[i]=v
                return count
            with patch.object(native.proc,'proc_listpids',query):
                with self.assertRaises(RuntimeError):native.group_members(42)
    def testNativeAvailableMemoryPreservesVmStatConservativePolicy(self):
        native=owner.native_resources.shared()
        def query(host,flavor,buffer,count):
            buffer[0]=1000;buffer[2]=200;buffer[23]=50
            import ctypes
            ctypes.cast(count,ctypes.POINTER(ctypes.c_uint32))[0]=24
            return 0
        with patch.object(native.system,'host_statistics64',query):
            self.assertEqual(native.available_bytes(),1150*native.page_size)
        def invalid(host,flavor,buffer,count):
            buffer[0]=1;buffer[23]=50
            import ctypes
            ctypes.cast(count,ctypes.POINTER(ctypes.c_uint32))[0]=24
            return 0
        with patch.object(native.system,'host_statistics64',invalid):
            with self.assertRaises(RuntimeError):native.available_bytes()
    def testBoundedReadRejectsBeforeAllocatingFullInput(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=pathlib.Path(tmp)/'data';path.write_bytes(b'12345')
            self.assertEqual(s.capped_read(path,5),b'12345')
            with self.assertRaises(ValueError):s.capped_read(path,4)
    def testGuardChecksAreNotOptimizationDependentAssertions(self):
        with self.assertRaises(ValueError):s.require(False,'expected')
        fake=type('N',(),{'available_bytes':lambda _:(_ for _ in ()).throw(RuntimeError('query failed'))})()
        with patch.object(s.native_resources,'shared',return_value=fake):
            with self.assertRaises(RuntimeError):s.available_bytes()

if __name__=='__main__':unittest.main()
