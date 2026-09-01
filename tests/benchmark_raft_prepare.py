from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--guidegen", required=True, type=Path)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=96)
    parser.add_argument("--batch", type=int, default=4)
    parser.add_argument("--no-benchmark", action="store_true")
    args = parser.parse_args()
    sys.path.insert(0, str(args.guidegen.parent))
    from guidegen import RaftMotion

    colors = [np.random.default_rng(i).integers(0, 256, (180, 320, 3), dtype=np.uint8) for i in range(args.frames)]
    started = time.perf_counter()
    motion = RaftMotion(args.weights, 4, args.batch)
    if args.no_benchmark:
        motion.torch.backends.cudnn.benchmark = False
    load_s = time.perf_counter() - started
    timings = []
    for _ in range(2):
        started = time.perf_counter()
        result = motion.prepare(colors, None)
        timings.append(time.perf_counter() - started)
        assert result[-1] is not None
    print(json.dumps({"load_s": load_s, "prepare_s": timings, "frames": args.frames, "batch": args.batch}))


if __name__ == "__main__":
    main()
