import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
import iw3_model_assets as assets

DATA = b'model-fixture\x00' * 4096
SHA = hashlib.sha256(DATA).hexdigest()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests += 1
        mode = self.path
        if mode == '/retry' and self.server.requests == 1:
            self.send_error(503)
            return
        if mode == '/stall':
            time.sleep(3)
            return
        offset = int(self.headers.get('Range', 'bytes=0-').split('=')[1].split('-')[0])
        self.server.offsets.append(offset)
        self.send_response(206 if offset else 200)
        self.send_header('Content-Length', str(len(DATA)-offset))
        if offset:
            self.send_header('Content-Range', f'bytes {offset}-{len(DATA)-1}/{len(DATA)}')
        self.end_headers()
        try:
            self.wfile.write(DATA[offset:])
        except (BrokenPipeError, ConnectionResetError):
            pass


class DownloadTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.target = Path(self.folder.name) / 'model.safetensors'
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.server.requests, self.server.offsets = 0, []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.events = []

    def tearDown(self):
        self.server.shutdown(); self.server.server_close()
        self.thread.join()
        self.folder.cleanup()

    def download(self, route='/', **kwargs):
        values = dict(checksum=SHA, expected=len(DATA), callback=lambda **x:self.events.append(x),
                      connect_timeout=1, stall_timeout=1, attempt_timeout=2, poll_seconds=.02)
        values.update(kwargs)
        assets.download(f'http://127.0.0.1:{self.server.server_port}{route}', self.target, **values)

    def test_download_size_hash_atomic_publication_and_progress(self):
        self.download()
        self.assertEqual(self.target.read_bytes(), DATA)
        self.assertFalse(self.target.with_name(self.target.name+'.studio.partial').exists())
        self.assertTrue(any('Проверка целостности' in e['message'] for e in self.events))
        self.assertEqual(self.events[-1]['download_bytes'], len(DATA))

    def test_existing_verified_file_never_goes_online(self):
        self.target.write_bytes(DATA)
        self.download()
        self.assertEqual(self.server.requests, 0)

    def test_existing_different_file_preserved(self):
        self.target.write_bytes(b'user')
        with self.assertRaisesRegex(RuntimeError, 'файл сохранён'):
            self.download()
        self.assertEqual(self.target.read_bytes(), b'user')
        self.assertEqual(self.server.requests, 0)

    def test_bad_checksum_never_publishes(self):
        with self.assertRaisesRegex(RuntimeError, 'SHA-256'):
            self.download(checksum='0'*64)
        self.assertFalse(self.target.exists())

    def test_incomplete_response_never_publishes(self):
        with self.assertRaisesRegex(RuntimeError, 'Размер'):
            self.download(expected=len(DATA)+1)
        self.assertFalse(self.target.exists())

    def test_retry_http_failure(self):
        self.download('/retry', attempts=2)
        self.assertEqual(self.server.requests, 2)
        self.assertEqual(self.target.read_bytes(), DATA)
        self.assertTrue(any(e.get('download_attempt') == 2 for e in self.events))

    def test_resume_partial(self):
        self.target.with_name(self.target.name+'.studio.partial').write_bytes(DATA[:2048])
        self.download()
        self.assertEqual(self.server.offsets, [2048])
        self.assertEqual(self.target.read_bytes(), DATA)

    def test_complete_partial_verified_without_network(self):
        self.target.with_name(self.target.name+'.studio.partial').write_bytes(DATA)
        self.download()
        self.assertEqual(self.server.requests, 0)
        self.assertEqual(self.target.read_bytes(), DATA)

    def test_stalled_response_has_a_deadline(self):
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, 'попытки'):
            self.download('/stall', attempts=1, attempt_timeout=1)
        self.assertLess(time.monotonic()-started, 4)
        self.assertFalse(self.target.exists())

    def test_failed_attempt_keeps_partial_separate(self):
        self.target.with_name(self.target.name+'.studio.partial').write_bytes(DATA[:2048])
        with self.assertRaises(RuntimeError):
            self.download('/stall', attempts=1, attempt_timeout=1)
        self.assertEqual(self.target.with_name(self.target.name+'.studio.partial').read_bytes(), DATA[:2048])

    def test_no_disk_space_stops_before_download(self):
        with patch.object(assets.shutil, 'disk_usage') as usage:
            usage.return_value.free = 100
            with self.assertRaisesRegex(RuntimeError, 'места'):
                self.download()
        self.assertEqual(self.server.requests, 0)

    def test_concurrent_installer_rejected(self):
        with assets.file_lock(self.target.with_name(self.target.name+'.download.lock')):
            with self.assertRaisesRegex(RuntimeError, 'другим процессом'):
                self.download()
        self.assertEqual(self.server.requests, 0)

    def test_da3_preflight_does_not_create_process(self):
        with patch.object(assets.subprocess, 'Popen') as process:
            assets.preflight(Path(self.folder.name), {}, da3_selected=True)
            process.assert_not_called()

    def test_preflight_failure_happens_before_video(self):
        events=[]
        with self.assertRaisesRegex(RuntimeError, 'подготовить модель'):
            assets.preflight(Path(self.folder.name), {'depth_model':'Distill_Any_S','resolution':518},
                             timeout=10,callback=lambda **e:events.append(e))
        self.assertTrue(events)
        self.assertFalse((Path(self.folder.name)/'temp').exists())

    def test_preflight_timeout_cleans_up_child(self):
        with self.assertRaises(TimeoutError):
            assets.preflight(Path(self.folder.name), {'depth_model':'Distill_Any_S','resolution':518},
                             timeout=-1, callback=lambda **e:None)


if __name__ == '__main__':
    unittest.main()
