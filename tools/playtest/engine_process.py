"""Identity-checked Windows engine handles for split launch/watch/stop commands.

Never terminate a numeric PID from a file. A retained handle plus creation time
and image identity protects against PID reuse; the launch manifest binds that
identity to one canonical write directory. Polling is a kernel wait, not CIM.
"""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path


def canonical(path):
    return os.path.normcase(str(Path(path).resolve()))


class EngineProcess:
    def __init__(self, pid):
        if os.name != "nt":
            raise RuntimeError("Split engine supervision currently requires Windows")
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        signatures = {
            "OpenProcess": ([wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.HANDLE),
            "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
            "WaitForSingleObject": ([wintypes.HANDLE, wintypes.DWORD], wintypes.DWORD),
            "TerminateProcess": ([wintypes.HANDLE, wintypes.UINT], wintypes.BOOL),
            "GetProcessTimes": ([wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4, wintypes.BOOL),
            "QueryFullProcessImageNameW": ([wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                           ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
        }
        for name, (args, result) in signatures.items():
            fn = getattr(self.api, name)
            fn.argtypes, fn.restype = args, result
        self.handle = self.api.OpenProcess(0x100000 | 0x1000 | 0x0001, False, pid)
        if not self.handle:
            error = ctypes.get_last_error()
            if error == 87:  # process no longer exists
                raise ProcessLookupError(pid)
            raise ctypes.WinError(error)
        self.pid = pid
        try:
            times = [wintypes.FILETIME() for _ in range(4)]
            if not self.api.GetProcessTimes(self.handle, *(ctypes.byref(t) for t in times)):
                raise ctypes.WinError(ctypes.get_last_error())
            self.created = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
            image = ctypes.create_unicode_buffer(32768)
            size = wintypes.DWORD(len(image))
            if not self.api.QueryFullProcessImageNameW(self.handle, 0, image, ctypes.byref(size)):
                raise ctypes.WinError(ctypes.get_last_error())
            self.exe = canonical(image.value)
        except BaseException:
            self.close()
            raise

    def identity(self, directory):
        return {"pid": self.pid, "created": self.created, "exe": self.exe,
                "write_dir": canonical(directory)}

    def matches(self, record, directory):
        return (record.get("created") == self.created and
                canonical(record.get("exe", "")) == self.exe and
                record.get("write_dir") == canonical(directory))

    def alive(self):
        result = self.api.WaitForSingleObject(self.handle, 0)
        if result == 0xFFFFFFFF:
            raise ctypes.WinError(ctypes.get_last_error())
        return result == 258

    def terminate(self):
        if self.alive() and not self.api.TerminateProcess(self.handle, 1):
            error = ctypes.get_last_error()
            # A process already exiting refuses termination with
            # ERROR_ACCESS_DENIED; that race is a successful stop.
            if not (error == 5 and self.api.WaitForSingleObject(self.handle, 5000) == 0):
                raise ctypes.WinError(error)
        result = self.api.WaitForSingleObject(self.handle, 5000)
        if result == 0xFFFFFFFF:
            raise ctypes.WinError(ctypes.get_last_error())
        if result == 258:
            raise TimeoutError("Engine did not exit after termination")

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def attach(record, directory):
    if not record.get("created") or record.get("write_dir") != canonical(directory):
        raise RuntimeError("Missing/mismatched engine identity; refusing to trust a saved PID")
    try:
        process = EngineProcess(int(record["pid"]))
    except ProcessLookupError:
        return None
    if not process.matches(record, directory):
        process.close()
        raise RuntimeError("Engine identity changed (possible PID reuse); refusing access")
    return process
