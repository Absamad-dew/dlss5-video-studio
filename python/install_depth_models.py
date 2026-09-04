"""Install only the compact, redistributable depth checkpoints used by V11."""

from __future__ import annotations

import argparse
import hashlib
import io
import urllib.request
import zipfile
from pathlib import Path

from huggingface_hub import hf_hub_download, snapshot_download

VIDEO_REVISION = "256875362cff76724b920335dfb4b29dd611f66e"
VIDEO_SHA256 = "13379300b739e659f076a59d52e9801bd8d38c541a7e71f73bbca4dcfb013609"
VIDEO_CODE_REVISION = "4f5ae23172ba60fd7bc11ef671cca678842c7072"
VIDEO_CODE_SHA256 = "012dc88e5feb7e51f5794f9b8013f4c786aa3d61c60b8e0c3c5a45e1e0feb7c5"


def install_video_code(root: Path) -> None:
    """Install only the pinned inference code, not demos, videos or git history."""
    url = f"https://codeload.github.com/DepthAnything/Video-Depth-Anything/zip/{VIDEO_CODE_REVISION}"
    with urllib.request.urlopen(url, timeout=120) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != VIDEO_CODE_SHA256:
        raise RuntimeError("Video Depth source archive checksum mismatch")
    files = []
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        for name in bundle.namelist():
            relative = Path(*Path(name).parts[1:])
            if not relative.parts or ".." in relative.parts:
                continue
            if not (str(relative) in ("LICENSE", "README.md") or
                    (relative.parts[0] in ("video_depth_anything", "utils") and relative.suffix == ".py")):
                continue
            data = bundle.read(name)
            destination = root / relative
            # Do not silently overwrite a user's modified model implementation.
            if destination.exists() and destination.read_bytes() != data:
                raise RuntimeError(f"Different Video Depth code already exists: {destination}. Back it up before reinstalling.")
            files.append((destination, data))
    for destination, data in files:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    print(f"DEPTH_CODE_READY video-small revision={VIDEO_CODE_REVISION} files={len(files)}", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-root", required=True, type=Path)
    parser.add_argument(
        "--models",
        nargs="+",
        choices=["video-small", "da3-small", "da3-base", "da3-large"],
        default=["video-small", "da3-small", "da3-base"],
    )
    args = parser.parse_args()
    target = args.target_root.resolve()
    target.mkdir(parents=True, exist_ok=True)

    if "video-small" in args.models:
        path = hf_hub_download(
            repo_id="depth-anything/Video-Depth-Anything-Small",
            revision=VIDEO_REVISION,
            filename="video_depth_anything_vits.pth",
            local_dir=target,
        )
        with open(path, "rb") as checkpoint:
            actual = hashlib.file_digest(checkpoint, "sha256").hexdigest()
        if actual != VIDEO_SHA256:
            raise RuntimeError("Video Depth checkpoint checksum mismatch; reinstall the model")
        install_video_code(target.parent.parent / "third_party" / "video-depth-anything")
        print(f"DEPTH_MODEL_READY video-small {path}", flush=True)

    for name, repo in (
        ("da3-small", "depth-anything/DA3-SMALL"),
        ("da3-base", "depth-anything/DA3-BASE"),
        ("da3-large", "depth-anything/DA3-LARGE"),
    ):
        if name not in args.models:
            continue
        path = snapshot_download(
            repo_id=repo,
            local_dir=target / name,
            allow_patterns=["config.json", "model.safetensors", "README.md"],
        )
        print(f"DEPTH_MODEL_READY {name} {path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
