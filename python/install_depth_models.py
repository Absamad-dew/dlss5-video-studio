"""Install only the compact, redistributable depth checkpoints used by V11."""

from __future__ import annotations

import argparse
from pathlib import Path

from huggingface_hub import hf_hub_download, snapshot_download


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-root", required=True, type=Path)
    parser.add_argument(
        "--models",
        nargs="+",
        choices=["video-small", "da3-small", "da3-base"],
        default=["video-small", "da3-small", "da3-base"],
    )
    args = parser.parse_args()
    target = args.target_root.resolve()
    target.mkdir(parents=True, exist_ok=True)

    if "video-small" in args.models:
        path = hf_hub_download(
            repo_id="depth-anything/Video-Depth-Anything-Small",
            filename="video_depth_anything_vits.pth",
            local_dir=target,
        )
        print(f"DEPTH_MODEL_READY video-small {path}", flush=True)

    for name, repo in (
        ("da3-small", "depth-anything/DA3-SMALL"),
        ("da3-base", "depth-anything/DA3-BASE"),
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
