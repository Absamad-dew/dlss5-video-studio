from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path

import torch
from torchvision.models.optical_flow import raft_small


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--runs", type=int, default=8)
    args = parser.parse_args()
    torch.backends.cudnn.benchmark = True
    state = torch.load(args.weights, map_location="cpu", weights_only=True)
    model = raft_small(weights=None, progress=False).eval().cuda()
    model.load_state_dict(state)
    results = []
    for width, height, updates, batch in ((320, 184, 4, 1), (480, 272, 4, 1), (640, 360, 4, 1), (480, 272, 8, 1), (480, 272, 4, 4), (480, 272, 4, 8)):
        a = torch.rand(batch, 3, height, width, device="cuda") * 2 - 1
        b = torch.rand(batch, 3, height, width, device="cuda") * 2 - 1
        with torch.inference_mode(), torch.autocast("cuda", dtype=torch.float16):
            for _ in range(3):
                model(a, b, num_flow_updates=updates)
            torch.cuda.synchronize()
            timings = []
            torch.cuda.reset_peak_memory_stats()
            for _ in range(args.runs):
                started = time.perf_counter()
                model(a, b, num_flow_updates=updates)
                torch.cuda.synchronize()
                timings.append((time.perf_counter() - started) * 1000)
        results.append(
            {
                "width": width,
                "height": height,
                "updates": updates,
                "batch": batch,
                "median_ms": round(statistics.median(timings), 3),
                "p95_ms": round(sorted(timings)[max(0, int(len(timings) * 0.95) - 1)], 3),
                "fps": round(1000 * batch / statistics.median(timings), 2),
                "peak_vram_mb": round(torch.cuda.max_memory_allocated() / 1048576, 1),
            }
        )
        del a, b
    print(json.dumps({"gpu": torch.cuda.get_device_name(0), "results": results}, ensure_ascii=True))


if __name__ == "__main__":
    main()
