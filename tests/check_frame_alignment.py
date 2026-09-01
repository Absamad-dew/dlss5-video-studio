from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def read_frames(path: Path, limit: int) -> list[np.ndarray]:
    capture = cv2.VideoCapture(str(path))
    frames: list[np.ndarray] = []
    while len(frames) < limit:
        ok, frame = capture.read()
        if not ok:
            break
        gray = cv2.cvtColor(cv2.resize(frame, (96, 54), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY)
        frames.append(gray.astype(np.float32))
    capture.release()
    return frames


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--frames", type=int, default=48)
    parser.add_argument("--chunk", type=int, default=24)
    args = parser.parse_args()
    source = read_frames(args.source, args.frames + 8)
    output = read_frames(args.output, args.frames)
    if len(output) != args.frames or len(source) < args.frames:
        raise RuntimeError(f"frame count mismatch source={len(source)} output={len(output)}")

    best_indices: list[int] = []
    best_errors: list[float] = []
    for frame in output:
        errors = [float(np.mean(np.abs(frame - candidate))) for candidate in source]
        index = int(np.argmin(errors))
        best_indices.append(index)
        best_errors.append(errors[index])

    source_delta = [float(np.mean(np.abs(source[i] - source[i - 1]))) for i in range(1, args.frames)]
    output_delta = [float(np.mean(np.abs(output[i] - output[i - 1]))) for i in range(1, args.frames)]
    boundaries = []
    for boundary in range(args.chunk, args.frames, args.chunk):
        local = max(1e-6, float(np.median(output_delta[max(0, boundary - 4):min(len(output_delta), boundary + 3)])))
        boundaries.append(
            {
                "frame": boundary,
                "source_delta": source_delta[boundary - 1],
                "output_delta": output_delta[boundary - 1],
                "output_to_local_ratio": output_delta[boundary - 1] / local,
            }
        )

    stable_start = min(10, max(0, args.frames // 4))
    offsets = [best_indices[i] - i for i in range(stable_start, len(best_indices))]
    median_offset = int(round(float(np.median(offsets))))
    monotonic = all(best_indices[i] >= best_indices[i - 1] for i in range(stable_start + 1, len(best_indices)))
    expected_matches = sum(
        abs((best_indices[i] - i) - median_offset) <= 1 for i in range(stable_start, len(best_indices))
    )
    result = {
        "frames": len(output),
        "best_source_indices": best_indices,
        "mean_alignment_error": float(np.mean(best_errors)),
        "within_one_frame": expected_matches,
        "stable_frames": len(best_indices) - stable_start,
        "median_source_offset": median_offset,
        "monotonic": monotonic,
        "boundaries": boundaries,
        "source_motion_mean": float(np.mean(source_delta)),
        "output_motion_mean": float(np.mean(output_delta)),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not monotonic or expected_matches < int((args.frames - stable_start) * 0.9):
        return 2
    if any(item["output_to_local_ratio"] > 3.0 for item in boundaries):
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
