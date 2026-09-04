"""Bounded model downloads and CPU-only preflight for the native iw3 pipeline."""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

CREATE_NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
DISTILL_SMALL = {
    'name': 'distill_any_depth_vits.safetensors',
    'url': 'https://huggingface.co/xingyang1/Distill-Any-Depth/resolve/38095a41cca1e28a28e8bb6372c68df721455a2d/small/model.safetensors',
    'bytes': 99165428,
    'sha256': '56a173c0e1b5045bf6296a5c1fb16eace0bbde2eddc24b37532cb1774ac09caa',
}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def report(**values):
    # Native iw3 intentionally hides normal stdout while loading models.
    # Retain our explicit progress channel, without changing upstream classes.
    value = {'phase': 'Models', 'percent': 0, 'processed_frames': 0,
             'total_frames': 0, 'eta_seconds': None, **values}
    print('STUDIO_PROGRESS_JSON ' + json.dumps(value, ensure_ascii=False),
          file=sys.__stdout__ or sys.stdout, flush=True)


@contextmanager
def file_lock(path):
    """OS-owned lock: released even if the user kills the worker."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a+b') as stream:
        if not stream.tell():
            stream.write(b'0'); stream.flush()
        stream.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise RuntimeError('Модель уже загружается другим процессом: ' + path.name) from error
        try:
            yield
        finally:
            if os.name == 'nt':
                stream.seek(0); msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def download(url, target, checksum=None, expected=None, *, attempts=3,
             connect_timeout=10, stall_timeout=20, attempt_timeout=300,
             callback=report, poll_seconds=.25):
    """curl handles bounded DNS/connect/read, retries resume a separate partial.

    Existing checkpoints are never overwritten. Failed/partial downloads never
    become a checkpoint. URLs/redirect credentials and curl stderr aren't logged.
    """
    target = Path(target)
    if attempts < 1 or min(connect_timeout, stall_timeout, attempt_timeout, poll_seconds) <= 0:
        raise ValueError('Download timeouts and attempt count must be positive')
    if target.name == DISTILL_SMALL['name']:
        url, checksum, expected = (DISTILL_SMALL[k] for k in ('url', 'sha256', 'bytes'))
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + '.studio.partial')

    def valid(path):
        return (path.is_file() and path.stat().st_size > 0
                and (expected is None or path.stat().st_size == expected)
                and (checksum is None or digest(path).startswith(checksum)))

    with file_lock(target.with_name(target.name + '.download.lock')):
        if target.exists():
            if valid(target):
                return
            raise RuntimeError('Существующая модель повреждена или отличается; файл сохранён: ' + str(target))
        curl = shutil.which('curl.exe') or shutil.which('curl')
        if not curl:
            raise RuntimeError('curl не найден: безопасная загрузка модели недоступна.')
        for attempt in range(1, attempts + 1):
            # A complete partial may remain after an interrupted publication.
            if expected and checksum and valid(partial):
                break
            if partial.exists() and expected and partial.stat().st_size >= expected:
                raise RuntimeError('Неверная контрольная сумма незавершённой модели: ' + str(partial))
            offset = partial.stat().st_size if partial.exists() else 0
            if shutil.disk_usage(target.parent).free < max(0, (expected or 0) - offset) + 512*1024**2:
                raise RuntimeError('Недостаточно места для модели и резерва 512 МиБ.')
            callback(message=f'Загрузка {target.name}: попытка {attempt}/{attempts}',
                     download_bytes=offset, download_total_bytes=expected,
                     download_attempt=attempt)
            command = [curl, '--location', '--fail', '--silent', '--show-error',
                       '--connect-timeout', str(connect_timeout), '--max-time', str(attempt_timeout),
                       '--speed-time', str(stall_timeout), '--speed-limit', '1024',
                       '--output', str(partial)]
            if offset:
                command += ['--continue-at', str(offset)]
            command += [url]
            started, last, last_bytes = time.monotonic(), 0, offset
            with tempfile.TemporaryFile() as errors:
                child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=errors,
                                         creationflags=CREATE_NO_WINDOW)
                try:
                    while child.poll() is None:
                        now = time.monotonic()
                        if now-started > attempt_timeout + 5:
                            raise TimeoutError('Истекло время попытки загрузки модели.')
                        if now-last >= 1:
                            done = partial.stat().st_size if partial.exists() else 0
                            speed = max(0, done-last_bytes)/max(1, now-last) if last else 0
                            if shutil.disk_usage(target.parent).free < 512*1024**2:
                                raise RuntimeError('Загрузка остановлена: осталось менее 512 МиБ.')
                            callback(message=f'{target.name}: {done/1e6:.1f} МБ' +
                                     (f' / {expected/1e6:.1f} МБ' if expected else '') +
                                     f' · {speed/1e6:.2f} МБ/с', download_bytes=done,
                                     download_total_bytes=expected, download_mbps=speed/1e6,
                                     download_attempt=attempt)
                            last, last_bytes = now, done
                        time.sleep(poll_seconds)
                    code = child.returncode
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.wait()
            if code == 0:
                callback(message='Проверка целостности ' + target.name)
                if not valid(partial):
                    raise RuntimeError('Размер или SHA-256 модели не совпадает: ' + str(partial))
                break
            # A server that does not support resuming must not append a full body.
            # curl 33/36 leaves the old partial intact; retain it for diagnosis.
            if attempt == attempts:
                raise RuntimeError(f'Не удалось скачать {target.name}: curl {code}, '
                                   f'{attempts} попытки. Незавершённый файл сохранён отдельно.')
        if target.exists():
            raise FileExistsError('Модель появилась во время загрузки: ' + str(target))
        # Windows rename refuses to replace an existing destination.
        os.rename(partial, target)
        callback(message='Модель готова: ' + target.name,
                 download_bytes=target.stat().st_size, download_total_bytes=target.stat().st_size)


@contextmanager
def network_guard():
    """Guard legacy torch.hub callers without modifying installed Torch/iw3."""
    import torch.hub
    previous_download = torch.hub.download_url_to_file
    previous_timeout = socket.getdefaulttimeout()
    def guarded(url, dst, hash_prefix=None, progress=True):
        return download(url, dst, checksum=hash_prefix)
    torch.hub.download_url_to_file = guarded
    socket.setdefaulttimeout(20)
    try:
        yield
    finally:
        torch.hub.download_url_to_file = previous_download
        socket.setdefaulttimeout(previous_timeout)


def preflight(root, settings, da3_selected=False, *, timeout=1000, callback=report):
    if da3_selected:  # These weights already have their own pinned readiness check.
        return
    command = [sys.executable, '-s', '-B', str(Path(__file__).resolve()),
               '--root', str(root), '--model', settings['depth_model'],
               '--resolution', str(settings['resolution'])]
    env = dict(os.environ, CUDA_VISIBLE_DEVICES='')
    callback(message='Проверка моделей перед обработкой: ' + settings['depth_model'])
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             encoding='utf-8', errors='replace', env=env,
                             creationflags=CREATE_NO_WINDOW)
    lines = queue.Queue()
    def read_lines():
        try:
            for line in child.stdout:
                lines.put(line)
        finally:
            lines.put(None)
    reader = threading.Thread(target=read_lines, daemon=True)
    reader.start()
    started, last = time.monotonic(), time.monotonic()
    tail = []
    try:
        while True:
            now = time.monotonic()
            if now-started > timeout:
                raise TimeoutError('Подготовка модели превысила допустимое время; видео ещё не обрабатывалось.')
            try:
                line = lines.get(timeout=.25)
            except queue.Empty:
                if now-last > 5:
                    callback(message='Ожидание модели ' + settings['depth_model'] +
                             f' · {int(now-started)} с (сетевые ожидания ограничены)')
                    last = now
                continue
            if line is None:
                break
            last = now
            if line.startswith('STUDIO_PROGRESS_JSON '):
                callback(**json.loads(line.split(' ', 1)[1]))
            else:
                # Avoid exposing redirect URLs or credentials through tracebacks.
                if line.startswith('IW3_MODEL_'):
                    print(line.rstrip(), flush=True)
                    tail.append(line.rstrip())
                    tail = tail[-4:]
        if child.wait():
            raise RuntimeError('Не удалось подготовить модель до обработки видео. ' + ' '.join(tail))
    finally:
        if child.poll() is None:
            # Kill the download subprocess as well, never leave an orphan curl.
            if os.name == 'nt':
                subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               creationflags=CREATE_NO_WINDOW, timeout=10)
            else:
                child.kill()
        child.wait()
        reader.join(timeout=2)
        child.stdout.close()


def prepare(root, model_name, resolution=518):
    from iw3_worker import configure_imports
    configure_imports(root)
    from iw3.depth_model_factory import create_depth_model
    model = create_depth_model(model_name)
    path = Path(model.get_model_path(model_name)) if model_name != 'NULL' else None
    if model_name == 'Distill_Any_S':
        download(DISTILL_SMALL['url'], path)
    elif path is not None and not path.exists():
        # Native loader retains its license/manual-install decisions. CPU only,
        # no inference, and no duplicate GPU allocation during the DLSS stage.
        with network_guard():
            model.load(gpu=-1, resolution=resolution)
    if path is not None and (not path.is_file() or path.stat().st_size == 0):
        raise RuntimeError('Файл модели отсутствует или пуст: ' + str(path))
    report(message='Модель проверена: ' + model_name)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--resolution', type=int, default=518)
    parser.add_argument('--download-only', action='store_true')
    args = parser.parse_args()
    try:
        if args.download_only:
            if args.model != 'Distill_Any_S':
                raise ValueError('Download-only is available for pinned Distill_Any_S')
            root = args.root.resolve()
            # No Torch import, model loading or GPU initialization for installation.
            from iw3_da3_install import footprint
            target = root / 'models/iw3/pretrained_models/hub/checkpoints' / DISTILL_SMALL['name']
            if not target.exists() and footprint(root) + DISTILL_SMALL['bytes'] + 64*1024**2 > 50e9:
                raise RuntimeError('Установка превысит выделенные программе 50 ГБ.')
            download(DISTILL_SMALL['url'], target)
        else:
            prepare(args.root.resolve(), args.model, args.resolution)
    except Exception as error:
        # Do not echo arbitrary urllib exception text containing signed URLs.
        message = str(error) if isinstance(error, (RuntimeError, FileExistsError)) else type(error).__name__
        if 'http' in message.lower():
            message = type(error).__name__ + ': ошибка сетевой подготовки модели'
        print('IW3_MODEL_ERROR ' + message, flush=True)
        raise SystemExit(1)
