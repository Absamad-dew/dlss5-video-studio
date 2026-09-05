import os
from pathlib import Path
import sys
import tempfile
import subprocess
import threading
import unittest
import uuid
import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))
from vr_stream import Guard, PipeReader, depth_stream
from vr_shared_depth import RawDepthWriter, DepthSample


class StreamTests(unittest.TestCase):
    @unittest.skipUnless(os.name=='nt','Windows pipe')
    def test_byte_pipe_and_eof(self):
        guard = Guard(os.getpid(), timeout=3)
        name = '\\\\.\\pipe\\StudioNativeVR-'+uuid.uuid4().hex
        reader = PipeReader(name,guard)
        data = bytes(range(256))*65536
        errors=[]
        def produce():
            try:
                # Windows CRT open with truncation, as used by the C++ host.
                with open(name,'wb',buffering=0) as out:
                    for offset in range(0,len(data),33333):
                        out.write(data[offset:offset+33333])
            except BaseException as error: errors.append(error)
        worker = threading.Thread(target=produce,daemon=True); worker.start()
        try:
            result = bytearray(len(data)); offset=0
            while offset<len(result):
                count=reader.readinto(memoryview(result)[offset:])
                self.assertGreater(count,0); offset+=count
            self.assertEqual(reader.readinto(memoryview(bytearray(8))),0)
            self.assertEqual(data,result)
            worker.join(3); self.assertFalse(worker.is_alive()); self.assertEqual(errors,[])
        finally: reader.close(); guard.close()

    @unittest.skipUnless(os.name=='nt','Windows pipe')
    def test_missing_producer_times_out(self):
        guard=Guard(timeout=.15)
        reader=PipeReader('\\\\.\\pipe\\StudioNativeVR-'+uuid.uuid4().hex,guard)
        try:
            with self.assertRaises(TimeoutError): reader.readinto(memoryview(bytearray(4)))
        finally: reader.close(); guard.close()

    def test_chunk_consumption_and_strict_timeline(self):
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder)
            (folder/'unrelated.txt').write_text('preserve')
            for chunk in range(3):
                writer=RawDepthWriter(folder/f'chunk-{chunk:04d}.vrd',2,chunk*2)
                for i in range(2): writer.write(DepthSample(None,np.ones((4,5),np.float32)*i),i==0)
                writer.close(True)
            self.assertEqual([x[0] for x in depth_stream(folder,6,Guard())],list(range(6)))
            self.assertEqual(list(folder.glob('*.vrd')),[])
            self.assertEqual((folder/'unrelated.txt').read_text(),'preserve')
            writer=RawDepthWriter(folder/'chunk-0000.vrd',1,8)
            writer.write(DepthSample(None,np.ones((4,5),np.float32)),False); writer.close(True)
            with self.assertRaises(ValueError): list(depth_stream(folder,1,Guard()))

    @unittest.skipUnless(os.name=='nt','Windows process handle')
    def test_dead_controller_aborts_pending_connect(self):
        child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(.3)'],
                               creationflags=subprocess.CREATE_NO_WINDOW)
        guard=Guard(child.pid,timeout=5)
        reader=PipeReader('\\\\.\\pipe\\StudioNativeVR-'+uuid.uuid4().hex,guard)
        try:
            child.wait(timeout=3)
            with self.assertRaisesRegex(RuntimeError,'controller exited'):
                reader.readinto(memoryview(bytearray(1)))
        finally:
            reader.close(); guard.close()
            if child.poll() is None: child.kill(); child.wait()


if __name__=='__main__': unittest.main()
