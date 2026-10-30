"""Only generic process-group and NSProcessInfo guards reused from the reviewed
Mac source snapshot. No model/reference/study code is imported or runnable.
"""
import ctypes
import os
import signal
import native_resources
import time
_stop_signal = None

def check_stop():
    if _stop_signal is not None:
        raise InterruptedError('Controlled stop signal ' + str(_stop_signal))

def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Never interpret EPERM as absence; verify complete native membership.
        return bool(native_resources.shared().group_members(pgid))


def terminate_owned(child):
    # Popen created this session/process group. Drain the group, not merely its
    # leader, and protect the bounded cleanup against repeated TERM/INT signals.
    handlers = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            child.poll()
            group_present = group_alive(child.pid)
            if not group_present and child.returncode is not None:
                return
            try:
                if group_present:
                    os.killpg(child.pid, sig)
                else:
                    # Do not equate missing PGID with a joined leader during
                    # exec startup. Popen owns and reaps this exact child PID.
                    child.send_signal(sig)
            except ProcessLookupError:
                pass
            end = time.monotonic() + 1
            while time.monotonic() < end:
                leader_joined = child.poll() is not None
                if not group_alive(child.pid) and leader_joined:
                    return
                time.sleep(0.01)
        child.poll()
        if group_alive(child.pid) or child.returncode is None:
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

