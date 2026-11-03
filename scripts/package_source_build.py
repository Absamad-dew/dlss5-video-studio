"""Package public source, optionally with reviewed local Windows builds.

No dependency discovery/download, SDK copying, runtime collection or deletion.
The explicit allowlist intentionally excludes legacy machine-specific packagers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = ("LICENSE", "THIRD_PARTY_NOTICES.md", "VERSION_OPTIMIZED.txt", "Program.cs",
              "BUILDING.md", "docs/build-verification-2026-11-03.json",
              "build_native.bat", "build_ui.bat", "build_streamline_probe.bat")
SOURCE_TREES = {"app": {".ps1", ".psm1", ".xaml", ".json"},
                "native": {".cpp", ".h"}, "python": {".py", ".json"},
                "licenses": {".txt", ".md"}}
EXTRA_FILES = ("scripts/Test-BuildPrerequisites.ps1", "scripts/demo-preflight.py",
               "scripts/package_source_build.py", "scripts/Install-NvCodecHeaders.ps1", "tests/test_iw3_worker.py",
               "tests/test-studio-launcher.ps1", "media/video-dataflow.svg")
BINARIES = {"dist/DLSS5 Video Studio.exe": "DLSS5 Video Studio.exe",
            "dist/engine/dlss5-video-host.exe": "engine/dlss5-video-host.exe",
            "dist/streamline/streamline-probe.exe": "streamline/streamline-probe.exe"}


def source_files(root):
    files = {root / name for name in ROOT_FILES + EXTRA_FILES}
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--", *SOURCE_TREES], cwd=root).decode("utf-8").split("\0")
    for relative in filter(None, tracked):
        path = Path(relative)
        if path.suffix in SOURCE_TREES[path.parts[0]]:
            files.add(root / path)
    for file in files:
        if file.is_symlink() or not file.is_file() or not file.resolve().is_relative_to(root.resolve()):
            raise ValueError("Missing or unsafe public source: " + file.relative_to(root).as_posix())
    return sorted(files, key=lambda p: p.relative_to(root).as_posix())


def package(output, include_build=False, ngx_license=None, include_launcher=False):
    if include_build and include_launcher:
        raise ValueError("Select one compiled package mode")
    output = output.resolve()
    suffix = "developer-win-x64" if include_build else "launcher-win-x64" if include_launcher else "source-kit"
    selected_binaries = BINARIES if include_build else {"dist/DLSS5 Video Studio.exe": "DLSS5 Video Studio.exe"} if include_launcher else {}
    archive = output.parent / ("dlss5-video-studio-22.3.0-" + suffix + ".zip")
    checksum = archive.with_suffix(".zip.sha256")
    if any(path.exists() for path in (output, archive, checksum)):
        raise FileExistsError("Choose new package and archive destinations")
    files = source_files(ROOT)
    source_version = (ROOT / "VERSION_OPTIMIZED.txt").read_text(encoding="utf-8-sig").splitlines()[0].strip()
    if not source_version.startswith("22.3.0-"):
        raise ValueError("This package definition requires the 22.3.0 source version")
    if selected_binaries:
        for source in selected_binaries:
            if not (ROOT / source).is_file():
                raise ValueError("Build required target first: " + source)
        if include_build and (not ngx_license or not ngx_license.is_file()):
            raise ValueError("Developer binary candidate requires --ngx-license with the applicable NVIDIA license")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    modified = bool(subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"], cwd=ROOT, text=True).strip())
    output.mkdir(parents=True)
    for source in files:
        destination = output / source.relative_to(ROOT)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    if selected_binaries:
        for source, relative in selected_binaries.items():
            destination = output / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / source, destination)
    if include_build:
        shutil.copyfile(ngx_license, output / "licenses/NVIDIA_RTX_SDK_LICENSE.txt")
    heading = {"source-kit": "Source kit: no compiled targets",
               "launcher-win-x64": "Windows launcher + source: native processing backend not included",
               "developer-win-x64": "Local developer candidate: includes SDK-linked native components"}[suffix]
    readme = "# Video Studio 22.3\n\n" + heading + "\n" + """

See BUILDING.md for supported targets, offline checks, SDK/runtime prerequisites
and licensing boundaries. This package does not include NVIDIA/ReShade DLLs,
models, FFmpeg, Python/CUDA or an SDK. It is not a complete portable GPU runtime.
Original source is MIT; an NGX-linked native binary also contains SDK object code
subject to NVIDIA terms. Do not treat every file as MIT-licensed.

CPU check (Python 3.11+, no pip install):
    python -I -S -B scripts/demo-preflight.py
    python -I -S -B -m unittest discover -s tests -p test_iw3_worker.py -v

Compiled-launcher candidate only: --validate-ui is an offscreen check, never a
video-processing result. Native host and probe must not be started until their
separately obtained runtime prerequisites are present.

Full source and history:
https://github.com/Absamad-dew/dlss5-video-studio
"""
    (output / "README.md").write_text(readme, encoding="utf-8", newline="\n")
    entries = []
    for path in sorted(output.rglob("*"), key=lambda p: p.relative_to(output).as_posix()):
        if path.is_file():
            data = path.read_bytes()
            entries.append({"path": path.relative_to(output).as_posix(), "bytes": len(data),
                            "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {"schema_version": 1, "version": "22.3.0", "kind": suffix,
                "source_version": source_version,
                "source_revision": revision, "source_tree_modified": modified,
                "compiled_targets_included": list(selected_binaries.values()),
                "sdk_linked_native_binaries_included": include_build,
                "vendor_runtime_dlls_included": False, "sdk_headers_or_libraries_included": False,
                "models_included": False, "gpu_execution_verified": False,
                "publication_status": "local-candidate",
                "files": entries}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(output.rglob("*"), key=lambda p: p.relative_to(output).as_posix()):
            if path.is_file():
                entry = zipfile.ZipInfo(path.relative_to(output).as_posix(), (2026, 11, 3, 0, 0, 0))
                entry.create_system = 3
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = 0o100644 << 16
                bundle.writestr(entry, path.read_bytes())
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum.write_text(digest + "  " + archive.name + "\n", encoding="ascii")
    print(json.dumps({"kind": suffix, "files": len(entries) + 1,
                      "archive": archive.name, "archive_bytes": archive.stat().st_size,
                      "sha256": digest}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--include-build", action="store_true")
    mode.add_argument("--include-launcher", action="store_true")
    parser.add_argument("--ngx-license", type=Path)
    args = parser.parse_args()
    try:
        package(args.output, args.include_build, args.ngx_license, args.include_launcher)
    except (ValueError, FileExistsError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
