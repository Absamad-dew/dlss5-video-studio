"""Create a real depth-warped stereoscopic video from DLSS output and guide sidecars."""

from __future__ import annotations

import argparse
import json
import math
import struct
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F


DEPTH_HEADER = struct.Struct("<8sIIIII")
DEPTH_MAGIC = b"D5DP0002"


def depth_frames(paths: list[Path]):
    for path in paths:
        with path.open("rb") as stream:
            raw = stream.read(DEPTH_HEADER.size)
            if len(raw) != DEPTH_HEADER.size:
                raise ValueError(f"truncated depth header: {path}")
            magic, width, height, count, fmt, flags = DEPTH_HEADER.unpack(raw)
            if magic != DEPTH_MAGIC or fmt != 2:
                raise ValueError(f"unsupported depth sidecar: {path}")
            tile = max(1, flags >> 8)
            grid_width = math.ceil(width / tile)
            grid_height = math.ceil(height / tile)
            extent = grid_width * grid_height
            for _ in range(count):
                data = np.fromfile(stream, dtype="<f2", count=extent)
                if data.size != extent:
                    raise ValueError(f"truncated depth frame: {path}")
                yield data.reshape(grid_height, grid_width), width, height


def read_exact(stream, extent: int) -> bytes:
    data = bytearray(extent)
    view = memoryview(data)
    offset = 0
    while offset < extent:
        received = stream.readinto(view[offset:])
        if not received:
            break
        offset += received
    return bytes(view[:offset])


def quote_command(command: list[str]) -> str:
    return subprocess.list2cmdline(command)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--input-video", required=True, type=Path)
    parser.add_argument("--depth-directory", required=True, type=Path)
    parser.add_argument("--output-video", required=True, type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--frames", required=True, type=int)
    parser.add_argument("--fps", required=True, type=float)
    parser.add_argument(
        "--layout", choices=["half-sbs", "full-sbs", "half-ou", "full-ou"], default="half-sbs"
    )
    parser.add_argument("--eye-separation", type=float, default=1.0)
    parser.add_argument("--convergence", type=float, default=0.48)
    parser.add_argument("--depth-gamma", type=float, default=1.0)
    parser.add_argument("--occlusion-fill", type=float, default=0.65)
    parser.add_argument("--edge-feather", type=float, default=2.0)
    parser.add_argument("--temporal-smoothing", type=float, default=0.55)
    parser.add_argument("--eye-swap", action="store_true")
    parser.add_argument("--codec", choices=["h264", "h265"], default="h265")
    parser.add_argument("--quality", type=int, default=18)
    args = parser.parse_args()

    if not torch.cuda.is_available():
        raise RuntimeError("depth 3D VR requires CUDA")
    depth_paths = sorted(args.depth_directory.glob("chunk-*.depth"))
    if not depth_paths:
        raise FileNotFoundError(f"no depth chunks in {args.depth_directory}")

    width, height = args.width, args.height
    output_width = width * 2 if args.layout == "full-sbs" else width
    output_height = height * 2 if args.layout == "full-ou" else height
    decoder_command = [
        str(args.ffmpeg), "-nostdin", "-v", "error", "-i", str(args.input_video),
        "-vf", f"scale={width}:{height}:flags=lanczos,format=rgb24",
        "-frames:v", str(args.frames), "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
    ]
    encoder = "hevc_nvenc" if args.codec == "h265" else "h264_nvenc"
    encoder_command = [
        str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s:v", f"{output_width}x{output_height}",
        "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an", "-c:v", encoder,
        "-preset", "p2", "-rc", "constqp", "-qp", str(args.quality),
    ]
    if args.codec == "h265":
        encoder_command += ["-tag:v", "hvc1"]
    encoder_command += ["-movflags", "+faststart", str(args.output_video)]

    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    decoder = subprocess.Popen(
        decoder_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL, creationflags=creation_flags,
    )
    encoder_process = subprocess.Popen(
        encoder_command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE, creationflags=creation_flags,
    )
    if decoder.stdout is None or encoder_process.stdin is None:
        raise RuntimeError("could not create VR video pipes")

    torch.backends.cudnn.benchmark = True
    device = torch.device("cuda")
    dtype = torch.float16
    x = torch.linspace(-1.0, 1.0, width, device=device, dtype=dtype)
    y = torch.linspace(-1.0, 1.0, height, device=device, dtype=dtype)
    grid_y, grid_x = torch.meshgrid(y, x, indexing="ij")
    extent = width * height * 3
    started = time.perf_counter()
    processed = 0
    previous_depth: torch.Tensor | None = None
    try:
        for index, (depth_np, _, _) in enumerate(depth_frames(depth_paths)):
            if index >= args.frames:
                break
            raw = read_exact(decoder.stdout, extent)
            if len(raw) != extent:
                details = decoder.stderr.read().decode("utf-8", errors="replace").strip()
                raise RuntimeError(f"video decoder ended at frame {index}: {details}")
            frame_np = np.frombuffer(raw, dtype=np.uint8).reshape(height, width, 3).copy()
            frame = torch.from_numpy(frame_np).to(device=device, non_blocking=True)
            frame = frame.permute(2, 0, 1).unsqueeze(0).to(dtype=dtype).div_(255.0)
            depth = torch.from_numpy(depth_np.astype(np.float32, copy=False)).to(device=device)
            depth = F.interpolate(
                depth[None, None], size=(height, width), mode="bilinear", align_corners=False
            ).to(dtype=dtype)
            depth = depth.clamp_(0.0, 1.0).pow_(max(0.25, args.depth_gamma))
            temporal = max(0.0, min(0.95, args.temporal_smoothing))
            if previous_depth is not None and temporal > 0:
                depth = depth.mul(1.0 - temporal).add_(previous_depth, alpha=temporal)
            previous_depth = depth.detach().clone()
            feather_kernel = max(1, int(round(args.edge_feather)) * 2 + 1)
            if feather_kernel > 1:
                depth = F.avg_pool2d(
                    depth, kernel_size=feather_kernel, stride=1, padding=feather_kernel // 2
                )
            # About 1.2% screen-width maximum disparity at strength 1.0.  The
            # convergence plane stays fixed, while foreground/background move
            # in opposite directions for genuine binocular parallax.
            disparity_px = (depth[0, 0] - args.convergence) * (width * 0.024 * args.eye_separation)
            disparity_norm = disparity_px * (2.0 / max(1, width - 1))
            left_grid = torch.stack((grid_x - disparity_norm, grid_y), dim=-1).unsqueeze(0)
            right_grid = torch.stack((grid_x + disparity_norm, grid_y), dim=-1).unsqueeze(0)
            left = F.grid_sample(frame, left_grid, mode="bilinear", padding_mode="border", align_corners=True)
            right = F.grid_sample(frame, right_grid, mode="bilinear", padding_mode="border", align_corners=True)
            # Outside-grid samples are disocclusions.  Let the user trade a
            # hard stretched border for a stable mono fill at those edges.
            fill_strength = max(0.0, min(1.0, args.occlusion_fill))
            if fill_strength > 0:
                left_outside = (left_grid[..., 0].abs() > 1.0).to(dtype).unsqueeze(1)
                right_outside = (right_grid[..., 0].abs() > 1.0).to(dtype).unsqueeze(1)
                left = left * (1.0 - left_outside * fill_strength) + frame * left_outside * fill_strength
                right = right * (1.0 - right_outside * fill_strength) + frame * right_outside * fill_strength
            if args.eye_swap:
                left, right = right, left
            if args.layout == "half-sbs":
                left = F.interpolate(left, size=(height, width // 2), mode="bilinear", align_corners=False)
                right = F.interpolate(right, size=(height, width // 2), mode="bilinear", align_corners=False)
                stereo = torch.cat((left, right), dim=3)
            elif args.layout == "full-sbs":
                stereo = torch.cat((left, right), dim=3)
            elif args.layout == "half-ou":
                left = F.interpolate(left, size=(height // 2, width), mode="bilinear", align_corners=False)
                right = F.interpolate(right, size=(height // 2, width), mode="bilinear", align_corners=False)
                stereo = torch.cat((left, right), dim=2)
            else:
                stereo = torch.cat((left, right), dim=2)
            stereo = stereo[0].permute(1, 2, 0).mul_(255.0).clamp_(0, 255).byte().cpu().numpy()
            encoder_process.stdin.write(stereo.tobytes())
            processed += 1
            if processed == 1 or processed % 30 == 0 or processed == args.frames:
                elapsed = time.perf_counter() - started
                print(
                    "VR_DEPTH_PROGRESS "
                    + json.dumps(
                        {"frames": processed, "total": args.frames, "fps": processed / max(elapsed, 1e-6)},
                        separators=(",", ":"),
                    ),
                    flush=True,
                )
    finally:
        decoder.stdout.close()
        encoder_process.stdin.close()

    decoder.wait(timeout=30)
    encoder_process.wait(timeout=60)
    if decoder.returncode != 0:
        raise RuntimeError("VR decoder failed: " + decoder.stderr.read().decode("utf-8", errors="replace"))
    if encoder_process.returncode != 0:
        raise RuntimeError("VR encoder failed: " + encoder_process.stderr.read().decode("utf-8", errors="replace"))
    if processed != args.frames:
        raise RuntimeError(f"depth sidecars contain {processed} frames, expected {args.frames}")
    print(
        "VR_DEPTH_DONE "
        + json.dumps(
            {"frames": processed, "elapsed_s": time.perf_counter() - started, "output": str(args.output_video)},
            separators=(",", ":"),
        ),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"VR_DEPTH_ERROR {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise
