"""Install the pinned, unmodified iw3 engine inside the portable directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
import zipfile


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download(url, target, checksum):
    if target.is_file() and sha256(target) == checksum:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + '.partial')
    print('IW3_INSTALL downloading ' + target.name, flush=True)
    # curl supports proxy/certificate configuration used by the portable runtime.
    subprocess.run(['curl.exe', '-L', '--fail', '--retry', '5', '--retry-all-errors',
                    '--output', str(partial), url], check=True)
    if sha256(partial) != checksum:
        raise RuntimeError('SHA256 mismatch: ' + target.name)
    os.replace(partial, target)


def install(root):
    lock = json.loads(Path(__file__).with_name('iw3-lock.json').read_text(encoding='utf-8'))
    source = lock['upstream']
    cache = root / 'models/iw3'
    archive = cache / 'nunif-source.zip'
    download(source['url'], archive, source['sha256'])
    code = root / 'third_party/nunif'
    records = []
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            parts = Path(item.filename).parts[1:]
            if not parts or item.is_dir():
                continue
            if parts[0] not in {'iw3', 'nunif', 'LICENSE', 'README.md', 'requirements.txt'}:
                continue
            target = code.joinpath(*parts).resolve()
            if not target.is_relative_to(code.resolve()):
                raise RuntimeError('Unsafe upstream archive path')
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(item) as src, target.open('wb') as dst:
                shutil.copyfileobj(src, dst)
            records.append({'path': target.relative_to(root).as_posix(), 'sha256': sha256(target)})
    checkpoints = cache / 'pretrained_models/hub/checkpoints'
    for asset in lock['assets']:
        target = checkpoints / asset['name']
        download(asset['url'], target, asset['sha256'])
        if target.stat().st_size != asset['bytes']:
            raise RuntimeError('Size mismatch: ' + target.name)
        records.append({'path': target.relative_to(root).as_posix(), 'sha256': asset['sha256']})
    # Isolate PyAV; do not upgrade Torch, CUDA or the other working pipelines.
    deps = cache / 'site-packages'
    if not (deps / 'av/__init__.py').is_file() or not (deps / 'diskcache/__init__.py').is_file():
        subprocess.run([sys.executable, '-s', '-m', 'pip', 'install', '--disable-pip-version-check',
                        '--no-deps', '--only-binary=:all:', '--target', str(deps),
                        'av==15.0.0', 'diskcache==5.6.3'], check=True)
    previous_vda = root / 'models/depth/video_depth_anything_vits.pth'
    vda = checkpoints / previous_vda.name
    if previous_vda.is_file() and not vda.exists():
        shutil.copy2(previous_vda, vda)
    licenses = root / 'licenses/iw3'
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copy2(code / 'LICENSE', licenses / 'nunif-MIT.txt')
    status = {'schema': 1, 'commit': source['commit'], 'files': records,
              'depth_download': 'Selected depth model is downloaded by official iw3 on first use.'}
    (cache / 'install.json').write_text(json.dumps(status, indent=2), encoding='utf-8')
    print('IW3_INSTALL_READY ' + json.dumps({'commit': source['commit'], 'files': len(records)}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    install(args.root.resolve())
