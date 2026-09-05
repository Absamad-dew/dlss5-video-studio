"""Bounded lossless DLSS -> Native VR transport (Windows local byte pipe).

No socket, shared global state, compressed intermediate or unbounded frame queue.
Pending I/O is cancellable; a dead controller cannot leave a waiting worker alive.
"""
from pathlib import Path
import os
import time


class Guard:
    def __init__(self, parent_pid=0, timeout=180):
        self.timeout = timeout
        self.parent = None
        if os.name == 'nt' and parent_pid:
            import _winapi as w
            self.parent = w.OpenProcess(0x00100000, False, parent_pid)  # SYNCHRONIZE only

    def check(self, since):
        if self.parent is not None:
            import _winapi as w
            if w.WaitForSingleObject(self.parent, 0) != w.WAIT_TIMEOUT:
                raise RuntimeError('Native VR controller exited; stopping stream')
        if time.monotonic()-since > self.timeout:
            raise TimeoutError('Native VR producer made no progress before the stream timeout')

    def close(self):
        if self.parent is not None:
            import _winapi as w
            w.CloseHandle(self.parent)
            self.parent = None


class PipeReader:
    def __init__(self, name, guard):
        import _winapi as w
        if not name.startswith('\\\\.\\pipe\\StudioNativeVR-'):
            raise ValueError('Expected a private Studio Native VR pipe name')
        self.guard, self.connected = guard, False
        self.handle = w.CreateNamedPipe(name, w.PIPE_ACCESS_INBOUND |
            w.FILE_FLAG_OVERLAPPED | w.FILE_FLAG_FIRST_PIPE_INSTANCE,
            0x8, 1, 0, 1024*1024, 0, 0)  # byte mode, PIPE_REJECT_REMOTE_CLIENTS

    def _wait(self, operation):
        import _winapi as w
        since = time.monotonic()
        try:
            while w.WaitForSingleObject(operation.event, 100) == w.WAIT_TIMEOUT:
                self.guard.check(since)
            count, error = operation.GetOverlappedResult(True)
            if error:
                raise OSError(error, 'Native VR pipe operation failed')
            return count
        except BaseException:
            operation.cancel()
            operation.GetOverlappedResult(True)
            raise

    def readinto(self, target):
        import _winapi as w
        try:
            if not self.connected:
                self._wait(w.ConnectNamedPipe(self.handle, overlapped=True))
                self.connected = True
            operation, _ = w.ReadFile(self.handle, min(len(target), 4*1024*1024), overlapped=True)
            count = self._wait(operation)
            target[:count] = operation.getbuffer()
            return count
        except OSError as error:
            if getattr(error, 'winerror', None) == w.ERROR_BROKEN_PIPE or error.errno == w.ERROR_BROKEN_PIPE:
                return 0
            raise

    def close(self):
        if self.handle is not None:
            import _winapi as w
            w.CloseHandle(self.handle)
            self.handle = None


def depth_stream(directory, frames, guard, keep=False):
    """Atomic .vrd publication also commits the matching motion/depth sidecars.

    Release only this chunk after its final output RGB frame was consumed. The
    host closes its input/guide handles before readback of that final frame.
    Producer backpressure bounds the remaining cache, including file RGB fallback.
    """
    from vr_shared_depth import raw_depth_frames
    import vr_depth_worker as legacy
    index = chunk = 0
    while index < frames:
        path = Path(directory)/f'chunk-{chunk:04d}.vrd'
        since = time.monotonic()
        while not path.is_file():
            guard.check(since)
            time.sleep(.01)
        motion_path = path.with_suffix('.motion')
        motions = iter(legacy.motion_frames([motion_path])) if motion_path.is_file() else None
        for sample in raw_depth_frames([path], expected_index=index):
            if sample[0] >= frames:
                raise ValueError('Streaming depth exceeds the requested timeline')
            motion = next(motions) if motions is not None else None
            yield (*sample, motion)
            index += 1
        if motions is not None and next(motions, None) is not None:
            raise ValueError('Motion/depth stream length mismatch')
        if not keep:
            for suffix in ('.vrd','.motion','.depth','.rgb'):
                path.with_suffix(suffix).unlink(missing_ok=True)
        chunk += 1
