"""Read-only Darwin watchdog queries; no spawned ps/vm_stat processes.
ABI definitions are pinned to the local macOS SDK libproc.h, sys/proc_info.h
(proc_taskinfo, PROC_PIDTASKINFO=4, PROC_PGRP_ONLY=2) and mach/host_info.h
(HOST_VM_INFO64=4; free/active/inactive prefix and speculative_count at offset92).
"""
import ctypes
import os

class TaskInfo(ctypes.Structure):
    _fields_=[(name,ctypes.c_uint64) for name in ('virtual_size','resident_size','total_user','total_system','threads_user','threads_system')]+[(name,ctypes.c_int32) for name in ('policy','faults','pageins','cow_faults','messages_sent','messages_received','syscalls_mach','syscalls_unix','csw','threadnum','numrunning','priority')]

class NativeResources:
    def __init__(self):
        if ctypes.sizeof(TaskInfo)!=96:raise RuntimeError('Unsupported proc_taskinfo ABI')
        self.proc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
        self.proc.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
        self.proc.proc_pidinfo.restype=ctypes.c_int
        self.proc.proc_listpids.argtypes=[ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_int]
        self.proc.proc_listpids.restype=ctypes.c_int
        self.system=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
        self.system.mach_host_self.argtypes=[];self.system.mach_host_self.restype=ctypes.c_uint32
        self.system.host_statistics64.argtypes=[ctypes.c_uint32,ctypes.c_int,ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint32)]
        self.system.host_statistics64.restype=ctypes.c_int
        self.system.host_page_size.argtypes=[ctypes.c_uint32,ctypes.c_void_p];self.system.host_page_size.restype=ctypes.c_int
        self.host=self.system.mach_host_self()
        page=ctypes.c_uint64(0)
        if self.system.host_page_size(self.host,ctypes.byref(page))!=0 or page.value not in (4096,16384):raise RuntimeError('Cannot query host page size')
        self.page_size=page.value
    def rss(self,pid):
        if not isinstance(pid,int) or pid<=0:raise ValueError('Invalid owned PID')
        value=TaskInfo();ctypes.set_errno(0)
        size=self.proc.proc_pidinfo(pid,4,0,ctypes.byref(value),ctypes.sizeof(value))
        if size!=ctypes.sizeof(value) or value.resident_size<=0:raise RuntimeError('Cannot query owned RSS')
        return value.resident_size
    def group_members(self,pgid):
        if not isinstance(pgid,int) or pgid<=0:raise ValueError('Invalid owned PGID')
        buffer=(ctypes.c_int32*4096)();ctypes.set_errno(0)
        size=self.proc.proc_listpids(2,pgid,buffer,ctypes.sizeof(buffer));error=ctypes.get_errno()
        if size<0 or size>=ctypes.sizeof(buffer) or size%4 or error!=0:raise RuntimeError('Cannot verify complete owned group')
        members=list(buffer)[:size//4]
        if any(pid<=0 for pid in members):raise RuntimeError('Invalid group query')
        return members
    def available_bytes(self):
        buffer=(ctypes.c_uint32*256)();count=ctypes.c_uint32(256)
        if self.system.host_statistics64(self.host,4,buffer,ctypes.byref(count))!=0 or not 24<=count.value<=256:raise RuntimeError('Cannot query available host memory')
        free,inactive,speculative=int(buffer[0]),int(buffer[2]),int(buffer[23])
        if free<speculative:raise RuntimeError('Invalid host free/speculative accounting')
        # vm_stat prints free_count - speculative_count as Pages free. Retain
        # the original conservative tool-based free+inactive admission policy.
        return (free-speculative+inactive)*self.page_size

_shared=None
def shared():
    global _shared
    if _shared is None:_shared=NativeResources()
    return _shared
