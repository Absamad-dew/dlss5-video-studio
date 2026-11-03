"""Exercise Studio's real stereo geometry preflight without models or a GPU.

This produces a geometry plan, not video. Exit 0 accepts the dimensions;
exit 2 rejects them before rendering. Python standard library only.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import iw3_worker as worker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--width", type=int, default=3840)
    parser.add_argument("--height", type=int, default=1632)
    parser.add_argument("--layout", choices=("FullSBS", "HalfSBS", "FullOU", "HalfOU"), default="FullSBS")
    parser.add_argument("--codec", choices=("H264", "H265"), default="H265")
    parser.add_argument("--output-mode", choices=("Source", "2160p", "1440p", "1080p", "720p", "540p"), default="2160p")
    args = parser.parse_args()
    request = vars(args)
    result = {"schema_version": "1.0", "kind": "cpu_geometry_preflight",
              "executes_gpu": False, "produces_video": False,
              "python_version": platform.python_version(), "request": request,
              "source_sha256": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                  for path in ("python/iw3_worker.py", "app/iw3-settings.json")}}
    try:
        settings = worker.validate_settings(ROOT, {"layout": args.layout})
        plan = worker.plan_geometry(args.width, args.height, settings, args.output_mode, args.codec)
        result["geometry"] = plan
        worker.require_geometry(plan)
        result["accepted"] = True
        result["error"] = None
    except ValueError as error:
        result["accepted"] = False
        result["error"] = str(error)
    print(json.dumps(result, indent=2))
    return 0 if result["accepted"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
