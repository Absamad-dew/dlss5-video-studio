"""Pinned DA3 assets for iw3. No torch import or GPU work during installation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile


def catalog(root):
    return json.loads((root / 'app/iw3-da3-models.json').read_text(encoding='utf-8-sig'))


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def emit(**values):
    print('IW3_DA3_INSTALL ' + json.dumps(values, ensure_ascii=False), flush=True)


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix('.json.tmp')
    partial.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(partial, path)


def get_model(root, model_id):
    return next(m for m in catalog(root)['models'] if m['id'] == model_id)


def ready(root, model_id, verify=False):
    m = get_model(root, model_id)
    marker = root / 'models/iw3/da3-status' / (model_id + '.json')
    try:
        saved = json.loads(marker.read_text(encoding='utf-8'))
        path = root / m['path']
        stat = path.stat()
        source = catalog(root)['sources'][m['source']]
        code_status = json.loads((root/source['path']/'install.json').read_text(encoding='utf-8'))
        good = (saved['sha256'] == m['sha256'] and saved['mtime_ns'] == stat.st_mtime_ns
                and stat.st_size == m['bytes'] and code_status['commit'] == source['commit'])
        good = good and (root/source['path']/'src/depth_anything_3/model/da3.py').is_file()
        if verify:
            good = good and all(digest(root/source['path']/r['path']) == r['sha256'] for r in code_status['files'])
        return good and (not verify or digest(path) == m['sha256'])
    except (OSError, ValueError, KeyError):
        return False


def download(url, path, checksum, expected=None):
    if path.is_file():
        if (expected is None or path.stat().st_size == expected) and digest(path) == checksum:
            return
        # Never overwrite previous or modified model weights under a shared path.
        raise RuntimeError('Existing file differs from pinned model; move it aside first: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + '.partial')
    for attempt in range(4):
        offset = partial.stat().st_size if partial.exists() else 0
        if expected and offset == expected:
            break
        request = urllib.request.Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                if offset and response.status != 206:
                    offset = 0
                elif offset and not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                    raise RuntimeError('Invalid resumed download range')
                total = expected or offset + int(response.headers.get('Content-Length') or 0)
                done = offset
                start, last = time.monotonic(), 0
                with partial.open('ab' if offset else 'wb') as stream:
                    while data := response.read(1024*1024):
                        if total and done+len(data)>total:
                            raise RuntimeError('Server sent more bytes than the declared model size')
                        stream.write(data); done += len(data)
                        now = time.monotonic()
                        if now-last > 1:
                            if shutil.disk_usage(path.parent).free < 512*1024**2:
                                raise RuntimeError('Download stopped: less than 512 MiB free disk space')
                            emit(file=path.name, phase='download', bytes=done, total=total,
                                 percent=round(100*done/total,1) if total else 0,
                                 mbps=round((done-offset)/max(.001,now-start)/1e6,1))
                            last=now
                if total and done != total:
                    raise RuntimeError(f'Incomplete download: {done}/{total}')
            break
        except (OSError, RuntimeError):
            if attempt == 3:
                raise
    emit(file=path.name, phase='sha256', percent=100)
    if (expected and partial.stat().st_size != expected) or digest(partial) != checksum:
        raise RuntimeError('Checksum mismatch; remove the failed .partial before retrying: ' + str(partial))
    os.replace(partial, path)


def install_source(root, source):
    code = root / source['path']
    marker = code / 'install.json'
    if marker.exists() and json.loads(marker.read_text())['commit'] == source['commit']:
        return
    archive = root / 'models/iw3/da3-cache' / (source['commit'] + '.zip')
    download(source['url'], archive, source['sha256'])
    records = []
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            parts = Path(item.filename).parts[1:]
            if not parts or item.is_dir():
                continue
            if not (parts[0] == 'src' or len(parts) == 1 and parts[0] in {'LICENSE','README.md','hubconf.py'}):
                continue
            target = code.joinpath(*parts).resolve()
            if not target.is_relative_to(code.resolve()):
                raise ValueError('Unsafe source archive path')
            data = bundle.read(item)
            if target.exists() and target.read_bytes() != data:
                raise RuntimeError('Modified source file: ' + str(target))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            records.append({'path':target.relative_to(code).as_posix(), 'sha256':hashlib.sha256(data).hexdigest()})
    atomic_json(marker, {'commit':source['commit'], 'files':records})


def footprint(root):
    total = 0
    for directory, _, files in os.walk(root):
        for filename in files:
            total += (Path(directory)/filename).stat().st_size
    return total


def _install(root, models, limit_gb=50):
    data = catalog(root)
    chosen = [get_model(root, name) for name in models]
    # Includes hidden files, runtime, recordings and temporary files; decimal GB.
    needed = 0
    for m in chosen:
        path=root/m['path']
        if not path.exists():
            partial=path.with_suffix(path.suffix+'.partial')
            needed+=max(0,m['bytes']-(partial.stat().st_size if partial.exists() else 0))
    used = footprint(root)
    if used + needed + 64*1024**2 > limit_gb*1e9:
        raise RuntimeError(f'Installation would exceed {limit_gb} GB: existing {used/1e9:.2f} + models {needed/1e9:.2f}')
    if shutil.disk_usage(root).free < needed + 1024**3:
        raise RuntimeError('Insufficient free disk space (+1 GiB reserve)')
    # Existing portable has these lightweight libraries. Only fill missing ones;
    # never upgrade Torch/CUDA or install the upstream web/GS/reconstruction stack.
    import importlib.util
    deps = root/'models/iw3/site-packages'
    sys.path.insert(0, str(deps))
    required = {'addict':'addict==2.4.0', 'omegaconf':'omegaconf==2.3.0',
                'antlr4':'antlr4-python3-runtime==4.9.3', 'yaml':'PyYAML==6.0.2',
                'einops':'einops==0.8.1', 'safetensors':'safetensors==0.5.3'}
    missing = [package for module, package in required.items() if importlib.util.find_spec(module) is None]
    if missing:
        subprocess.run([sys.executable,'-s','-m','pip','install','--no-deps','--disable-pip-version-check',
                        '--target',str(deps),*missing], check=True)
    for m in chosen:
        emit(model=m['id'], phase='prepare', license=m['license'])
        install_source(root, data['sources'][m['source']])
        path = root / m['path']
        download(f"https://huggingface.co/{m['repo']}/resolve/{m['revision']}/model.safetensors", path, m['sha256'], m['bytes'])
        # Retain model card and license with the checkpoint, pinned to same revision.
        card = path.parent / (m['config']+'-MODEL_CARD.md')
        if not card.exists():
            with urllib.request.urlopen(f"https://huggingface.co/{m['repo']}/raw/{m['revision']}/README.md", timeout=45) as response:
                card.write_bytes(response.read())
        atomic_json(root/'models/iw3/da3-status'/(m['id']+'.json'),
                    dict(m, mtime_ns=path.stat().st_mtime_ns, installed_at=time.time()))
        emit(model=m['id'], phase='ready', percent=100, bytes=m['bytes'])


def install(root, models, limit_gb=50):
    # Cross-process lock: UI and CLI must not write the same .partial concurrently.
    import msvcrt
    lock=root/'models/iw3/da3-install.lock'
    lock.parent.mkdir(parents=True,exist_ok=True)
    with lock.open('a+b') as stream:
        if stream.tell()==0:
            stream.write(b'0');stream.flush()
        stream.seek(0)
        try:
            msvcrt.locking(stream.fileno(),msvcrt.LK_NBLCK,1)
        except OSError as error:
            raise RuntimeError('Another DA3 installation is already running.') from error
        try:
            _install(root,models,limit_gb)
        finally:
            stream.seek(0);msvcrt.locking(stream.fileno(),msvcrt.LK_UNLCK,1)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--models',nargs='+',required=True)
    parser.add_argument('--limit-gb',type=float,default=50)
    parser.add_argument('--verify',action='store_true')
    args=parser.parse_args()
    if args.verify:
        for name in args.models:
            ok=ready(args.root,name,verify=True)
            emit(model=name,verified=ok)
            if not ok: raise SystemExit(1)
    else:
        install(args.root.resolve(),args.models,args.limit_gb)
