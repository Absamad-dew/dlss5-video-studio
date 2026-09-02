"""Run one E2FGVI-HQ window against GAPW output for visual/perf QA."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import torch


def read_frames(path: Path, limit: int, gray: bool = False) -> list[np.ndarray]:
    capture = cv2.VideoCapture(str(path))
    frames: list[np.ndarray] = []
    while len(frames) < limit:
        ok, frame = capture.read()
        if not ok:
            break
        frames.append(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if gray else frame)
    capture.release()
    if not frames:
        raise RuntimeError(f"No frames decoded from {path}")
    return frames


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--mask", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=3)
    parser.add_argument("--mask-dilate", type=int, default=1)
    parser.add_argument("--foreground-expand", type=int, default=0)
    args = parser.parse_args()

    sys.path.insert(0, str(args.repository))
    from model.e2fgvi_hq import InpaintGenerator

    bgr_frames = read_frames(args.video, args.frames)
    raw_masks = read_frames(args.mask, args.frames, gray=True)
    count = min(len(bgr_frames), len(raw_masks))
    bgr_frames, raw_masks = bgr_frames[:count], raw_masks[:count]
    height, width = bgr_frames[0].shape[:2]
    binary_masks = [(mask >= 96).astype(np.uint8) for mask in raw_masks]
    if args.mask_dilate > 0:
        kernel = np.ones((3, 3), np.uint8)
        conditioning_masks = [
            cv2.dilate(mask, kernel, iterations=args.mask_dilate) for mask in binary_masks
        ]
    else:
        conditioning_masks = binary_masks
    if args.foreground_expand > 0:
        pixels = min(96, args.foreground_expand)
        directional_kernel = np.ones((3, pixels + 1), np.uint8)
        conditioning_masks = [
            cv2.dilate(mask, directional_kernel, anchor=(0, 1))
            for mask in conditioning_masks
        ]

    rgb = np.stack([cv2.cvtColor(frame, cv2.COLOR_BGR2RGB) for frame in bgr_frames])
    images = torch.from_numpy(rgb).permute(0, 3, 1, 2).float().div_(127.5).sub_(1.0)
    masks = torch.from_numpy(np.stack(conditioning_masks))[:, None].float()
    device = torch.device("cuda")
    torch.backends.cudnn.benchmark = True
    torch.backends.cuda.matmul.allow_tf32 = True
    model_started = time.perf_counter()
    model = InpaintGenerator(init_weights=False).to(device)
    state = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    model.load_state_dict(state)
    model.eval().half()
    load_seconds = time.perf_counter() - model_started
    images = images[None].to(device=device, dtype=torch.float16)
    masks = masks[None].to(device=device, dtype=torch.float16)
    masked = images * (1.0 - masks)
    padded_height = ((height + 59) // 60) * 60
    padded_width = ((width + 107) // 108) * 108
    masked = torch.cat((masked, torch.flip(masked, dims=(3,))), dim=3)[
        :, :, :, :padded_height, :
    ]
    masked = torch.cat((masked, torch.flip(masked, dims=(4,))), dim=4)[
        :, :, :, :, :padded_width
    ]
    torch.cuda.reset_peak_memory_stats()
    torch.cuda.synchronize()
    started = time.perf_counter()
    with torch.inference_mode(), torch.autocast("cuda", dtype=torch.float16):
        predicted, _ = model(masked, count)
    torch.cuda.synchronize()
    inference_seconds = time.perf_counter() - started
    predicted = predicted[:, :, :height, :width].add(1.0).mul_(127.5)
    predicted = predicted.clamp_(0, 255).byte().permute(0, 2, 3, 1).cpu().numpy()

    args.output.mkdir(parents=True, exist_ok=True)
    for index in range(count):
        generated_bgr = cv2.cvtColor(predicted[index], cv2.COLOR_RGB2BGR)
        output = bgr_frames[index].copy()
        active = binary_masks[index] > 0
        output[active] = generated_bgr[active]
        cv2.imwrite(str(args.output / f"frame-{index:03d}.png"), output)
        if index == 0:
            crop = output[80:600, 500:760]
            cv2.imwrite(str(args.output / "frame-000-crop.png"), cv2.resize(crop, None, fx=2, fy=2, interpolation=cv2.INTER_NEAREST))
    metrics = {
        "frames": count,
        "resolution": [width, height],
        "load_seconds": load_seconds,
        "inference_seconds": inference_seconds,
        "fps": count / max(inference_seconds, 1e-6),
        "peak_vram_gib": torch.cuda.max_memory_allocated() / (1024**3),
        "mask_percent": 100.0 * float(np.mean(np.stack(binary_masks) > 0)),
    }
    (args.output / "metrics.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")
    print(json.dumps(metrics, indent=2))


if __name__ == "__main__":
    main()
