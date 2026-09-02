"""Create a temporally stable depth-warped stereoscopic video on CUDA."""

from __future__ import annotations

import argparse
import json
import math
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import BinaryIO, Iterator

import numpy as np
import torch
import torch.nn.functional as F


DEPTH_HEADER = struct.Struct("<8sIIIII")
DEPTH_MAGIC = b"D5DP0002"
MOTION_HEADER = struct.Struct("<8sIIIIIIII")
MOTION_MAGIC = b"D5MV0003"
MOTION_DTYPE = np.dtype(
    [("dx", "<f2"), ("dy", "<f2"), ("valid", "u1"), ("confidence", "u1")]
)


def depth_frames(paths: list[Path]) -> Iterator[tuple[np.ndarray, int, int]]:
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


def motion_frames(paths: list[Path]) -> Iterator[tuple[np.ndarray, int, int]]:
    for path in paths:
        with path.open("rb") as stream:
            raw = stream.read(MOTION_HEADER.size)
            if len(raw) != MOTION_HEADER.size:
                raise ValueError(f"truncated motion header: {path}")
            header = MOTION_HEADER.unpack(raw)
            magic, width, height = header[:3]
            count, grid_width, grid_height, record_bytes = header[4:8]
            if magic != MOTION_MAGIC or record_bytes != MOTION_DTYPE.itemsize:
                raise ValueError(f"unsupported motion sidecar: {path}")
            extent = grid_width * grid_height
            for _ in range(count):
                data = np.fromfile(stream, dtype=MOTION_DTYPE, count=extent)
                if data.size != extent:
                    raise ValueError(f"truncated motion frame: {path}")
                yield data.reshape(grid_height, grid_width), width, height


def read_exact(stream: BinaryIO, extent: int) -> bytes:
    data = bytearray(extent)
    view = memoryview(data)
    offset = 0
    while offset < extent:
        received = stream.readinto(view[offset:])
        if not received:
            break
        offset += received
    return bytes(view[:offset])


def motion_compensated_depth(
    depth: torch.Tensor,
    previous: torch.Tensor | None,
    motion_np: np.ndarray | None,
    width: int,
    height: int,
    temporal: float,
    grid_cache: dict[tuple[int, int], torch.Tensor],
) -> torch.Tensor:
    if previous is None or temporal <= 0:
        return depth
    if motion_np is None:
        return depth.mul(1.0 - temporal).add(previous, alpha=temporal)

    gh, gw = motion_np.shape
    confidence_np = motion_np["confidence"].astype(np.float32) * (1.0 / 255.0)
    confidence_np *= motion_np["valid"].astype(np.float32)
    confidence = torch.from_numpy(confidence_np).to(depth.device)[None, None]
    # V3 sidecars store confidence-premultiplied flow in full-frame pixels.
    denominator = np.maximum(confidence_np, 1.0 / 255.0)
    dx = torch.from_numpy(motion_np["dx"].astype(np.float32) / denominator).to(depth.device)
    dy = torch.from_numpy(motion_np["dy"].astype(np.float32) / denominator).to(depth.device)
    key = (gh, gw)
    base = grid_cache.get(key)
    if base is None:
        gy, gx = torch.meshgrid(
            torch.linspace(-1.0, 1.0, gh, device=depth.device),
            torch.linspace(-1.0, 1.0, gw, device=depth.device),
            indexing="ij",
        )
        base = torch.stack((gx, gy), dim=-1)[None]
        grid_cache[key] = base
    flow_grid = base + torch.stack(
        (dx * (2.0 / max(1, width - 1)), dy * (2.0 / max(1, height - 1))), dim=-1
    )[None]
    warped = F.grid_sample(
        previous.float(), flow_grid, mode="bilinear", padding_mode="border", align_corners=True
    )
    blend = confidence.mul(temporal).clamp_(0.0, temporal)
    return depth.float().mul(1.0 - blend).add_(warped.mul(blend))


def edge_aware_feather(depth: torch.Tensor, radius: float) -> torch.Tensor:
    if radius < 0.5:
        return depth
    kernel = min(13, int(round(radius)) * 2 + 1)
    if kernel % 2 == 0:
        kernel += 1
    smooth = F.avg_pool2d(depth.float(), kernel, stride=1, padding=kernel // 2)
    edge_gate = torch.exp(-(depth.float() - smooth).abs() * 28.0)
    return depth.float().lerp(smooth, edge_gate * min(1.0, radius / 6.0))


def inverse_warp(
    frame: torch.Tensor,
    disparity_px: torch.Tensor,
    grid_x: torch.Tensor,
    grid_y: torch.Tensor,
    sign: float,
    fill_strength: float,
) -> tuple[torch.Tensor, float]:
    width = frame.shape[-1]
    disparity_norm = disparity_px * (sign * 2.0 / max(1, width - 1))
    grid = torch.stack((grid_x.float() + disparity_norm.float(), grid_y.float()), dim=-1)[None]
    grid = grid.to(frame.dtype)
    view = F.grid_sample(frame, grid, mode="bilinear", padding_mode="border", align_corners=True)
    outside = (grid[..., 0].abs() > 1.0).unsqueeze(1)
    if fill_strength > 0:
        view = torch.where(outside, frame.lerp(view, 1.0 - fill_strength), view)
    return view, float(outside.float().mean().item())


def layered_splat(
    frame: torch.Tensor,
    depth: torch.Tensor,
    disparity_px: torch.Tensor,
    x: torch.Tensor,
    rows: torch.Tensor,
    sign: float,
    z_strength: float,
    fill_strength: float,
    fill_radius: int,
) -> tuple[torch.Tensor, float]:
    """Forward soft z-splat that retains foreground ownership."""
    _, channels, height, width = frame.shape
    device = frame.device
    work_frame = frame[0].float()
    work_depth = depth[0, 0].float()
    target = x + disparity_px.float() * sign
    x0 = torch.floor(target)
    fraction = target - x0
    z_weight = torch.exp2((work_depth - 0.5) * max(0.0, z_strength)).clamp_(0.03125, 32.0)
    accum = torch.zeros((channels, height * width), device=device, dtype=torch.float32)
    weights = torch.zeros((height * width,), device=device, dtype=torch.float32)
    flat_rgb = work_frame.reshape(channels, -1)
    for offset, bilinear in ((0, 1.0 - fraction), (1, fraction)):
        target_x = x0.to(torch.int64) + offset
        valid = (target_x >= 0) & (target_x < width)
        index = (rows + target_x.clamp(0, width - 1)).reshape(-1)
        weight = (bilinear * z_weight * valid).reshape(-1)
        weights.scatter_add_(0, index, weight)
        accum.scatter_add_(1, index[None].expand(channels, -1), flat_rgb * weight)
    visible = weights.reshape(1, 1, height, width)
    view = (accum / weights.clamp_min(1.0e-5)[None]).reshape(1, channels, height, width)
    holes = visible < 0.035
    hole_fraction = float(holes.float().mean().item())
    if holes.any():
        radius = max(1, min(24, fill_radius))
        kernel = radius * 2 + 1
        valid = (~holes).float()
        neighbour_sum = F.avg_pool2d(view * valid, (1, kernel), stride=1, padding=(0, radius))
        neighbour_weight = F.avg_pool2d(valid, (1, kernel), stride=1, padding=(0, radius))
        neighbour = neighbour_sum / neighbour_weight.clamp_min(1.0e-4)
        filled = frame.float().lerp(neighbour, max(0.0, min(1.0, fill_strength)))
        view = torch.where(holes, filled, view)
    return view.to(frame.dtype), hole_fraction


def encode_options(codec: str, pixel_format: str, quality: int) -> list[str]:
    common = [
        "-preset", "p2", "-rc", "constqp", "-qp", str(quality),
        "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709",
        "-color_trc", "bt709",
    ]
    if codec == "h265":
        if pixel_format == "p010le":
            return common + ["-pix_fmt", "p010le", "-profile:v", "main10", "-tag:v", "hvc1"]
        return common + ["-pix_fmt", "yuv420p", "-profile:v", "main", "-tag:v", "hvc1"]
    return common + ["-pix_fmt", "yuv420p", "-profile:v", "high"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--input-video", required=True, type=Path)
    parser.add_argument("--depth-directory", required=True, type=Path)
    parser.add_argument("--motion-directory", type=Path)
    parser.add_argument("--output-video", required=True, type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--frames", required=True, type=int)
    parser.add_argument("--fps", required=True, type=float)
    parser.add_argument(
        "--layout", choices=["half-sbs", "full-sbs", "half-ou", "full-ou"], default="half-sbs"
    )
    parser.add_argument("--stereo-method", choices=["inverse", "layered"], default="layered")
    parser.add_argument("--eye-anchor", choices=["symmetric", "left", "right"], default="symmetric")
    parser.add_argument("--temporal-mode", choices=["off", "ema", "motion"], default="motion")
    parser.add_argument("--eye-separation", type=float, default=1.0)
    parser.add_argument("--convergence", type=float, default=0.48)
    parser.add_argument("--depth-gamma", type=float, default=1.0)
    parser.add_argument("--foreground-strength", type=float, default=1.0)
    parser.add_argument("--background-strength", type=float, default=0.75)
    parser.add_argument("--z-buffer-strength", type=float, default=5.0)
    parser.add_argument("--occlusion-fill", type=float, default=0.72)
    parser.add_argument("--hole-fill-radius", type=int, default=8)
    parser.add_argument("--edge-feather", type=float, default=1.0)
    parser.add_argument("--temporal-smoothing", type=float, default=0.55)
    parser.add_argument("--max-disparity-percent", type=float, default=2.4)
    parser.add_argument("--eye-swap", action="store_true")
    parser.add_argument("--codec", choices=["h264", "h265"], default="h265")
    parser.add_argument("--pixel-format", choices=["yuv420p", "p010le"], default="yuv420p")
    parser.add_argument("--quality", type=int, default=18)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not torch.cuda.is_available():
        raise RuntimeError("depth 3D VR requires CUDA")
    if args.codec == "h264" and args.pixel_format != "yuv420p":
        raise ValueError("H.264 VR output supports only yuv420p")
    depth_paths = sorted(args.depth_directory.glob("chunk-*.depth"))
    if not depth_paths:
        raise FileNotFoundError(f"no depth chunks in {args.depth_directory}")
    motion_paths = sorted((args.motion_directory or args.depth_directory).glob("chunk-*.motion"))
    use_motion = args.temporal_mode == "motion" and bool(motion_paths)
    motion_iterator = iter(motion_frames(motion_paths)) if use_motion else None

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
    ] + encode_options(args.codec, args.pixel_format, args.quality)
    encoder_command += ["-frames:v", str(args.frames), "-movflags", "+faststart", str(args.output_video)]

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
    torch.set_grad_enabled(False)
    device = torch.device("cuda")
    dtype = torch.float16
    eye_width = width // 2 if args.layout == "half-sbs" else width
    eye_height = height // 2 if args.layout == "half-ou" else height
    y, x = torch.meshgrid(
        torch.linspace(-1.0, 1.0, eye_height, device=device, dtype=dtype),
        torch.linspace(-1.0, 1.0, eye_width, device=device, dtype=dtype),
        indexing="ij",
    )
    splat_x = torch.arange(eye_width, device=device, dtype=torch.float32)[None].expand(eye_height, -1)
    splat_rows = (
        torch.arange(eye_height, device=device, dtype=torch.int64)[:, None] * eye_width
    ).expand(-1, eye_width)
    extent = width * height * 3
    started = time.perf_counter()
    processed = 0
    hole_sum = 0.0
    previous_depth: torch.Tensor | None = None
    motion_grid_cache: dict[tuple[int, int], torch.Tensor] = {}
    try:
        with torch.inference_mode():
            for index, (depth_np, _, _) in enumerate(depth_frames(depth_paths)):
                if index >= args.frames:
                    break
                raw = read_exact(decoder.stdout, extent)
                if len(raw) != extent:
                    details = decoder.stderr.read().decode("utf-8", errors="replace").strip()
                    raise RuntimeError(f"video decoder ended at frame {index}: {details}")
                frame_np = np.frombuffer(raw, dtype=np.uint8).reshape(height, width, 3).copy()
                frame = torch.from_numpy(frame_np).to(device=device, non_blocking=True)
                frame = frame.permute(2, 0, 1)[None].to(dtype=dtype).div_(255.0)
                depth = torch.from_numpy(depth_np.astype(np.float32, copy=False)).to(device)[None, None]
                motion_np = next(motion_iterator)[0] if motion_iterator is not None else None
                temporal = max(0.0, min(0.95, args.temporal_smoothing))
                if args.temporal_mode == "off":
                    temporal = 0.0
                if args.temporal_mode == "ema":
                    motion_np = None
                depth = motion_compensated_depth(
                    depth, previous_depth, motion_np, width, height, temporal, motion_grid_cache
                ).clamp_(0.0, 1.0)
                previous_depth = depth.detach().clone()
                depth = F.interpolate(depth, size=(height, width), mode="bilinear", align_corners=False)
                depth = depth.pow(max(0.25, min(3.0, args.depth_gamma)))
                depth = edge_aware_feather(depth, args.edge_feather)
                if (eye_height, eye_width) != (height, width):
                    frame = F.interpolate(frame, size=(eye_height, eye_width), mode="bilinear", align_corners=False)
                    depth = F.interpolate(depth, size=(eye_height, eye_width), mode="bilinear", align_corners=False)

                delta = depth[0, 0] - max(0.1, min(0.9, args.convergence))
                foreground = max(0.0, min(2.0, args.foreground_strength))
                background = max(0.0, min(2.0, args.background_strength))
                delta = torch.where(delta >= 0, delta * foreground, delta * background)
                limit = eye_width * (min(5.0, max(0.5, args.max_disparity_percent)) / 100.0)
                disparity = delta * (limit * max(0.1, min(3.0, args.eye_separation)))
                if args.eye_anchor == "left":
                    left_shift, right_shift = 0.0, -2.0
                elif args.eye_anchor == "right":
                    left_shift, right_shift = 2.0, 0.0
                else:
                    left_shift, right_shift = 1.0, -1.0

                def render_eye(shift: float) -> tuple[torch.Tensor, float]:
                    if shift == 0:
                        return frame, 0.0
                    if args.stereo_method == "layered":
                        return layered_splat(
                            frame, depth, disparity, splat_x, splat_rows, shift, args.z_buffer_strength,
                            args.occlusion_fill, args.hole_fill_radius,
                        )
                    return inverse_warp(frame, disparity, x, y, shift, args.occlusion_fill)

                left, left_holes = render_eye(left_shift)
                right, right_holes = render_eye(right_shift)
                hole_sum += 0.5 * (left_holes + right_holes)
                if args.eye_swap:
                    left, right = right, left
                if args.layout in ("half-sbs", "full-sbs"):
                    stereo = torch.cat((left, right), dim=3)
                else:
                    stereo = torch.cat((left, right), dim=2)
                stereo_np = stereo[0].permute(1, 2, 0).mul_(255.0).clamp_(0, 255).byte().cpu().numpy()
                encoder_process.stdin.write(stereo_np.tobytes())
                processed += 1
                if processed == 1 or processed % 30 == 0 or processed == args.frames:
                    elapsed = time.perf_counter() - started
                    print(
                        "VR_DEPTH_PROGRESS " + json.dumps(
                            {
                                "frames": processed, "total": args.frames,
                                "fps": processed / max(elapsed, 1e-6),
                                "holes_percent": 100.0 * hole_sum / processed,
                                "method": args.stereo_method,
                                "temporal": "motion" if use_motion else args.temporal_mode,
                            }, separators=(",", ":"),
                        ), flush=True,
                    )
    finally:
        decoder.stdout.close()
        encoder_process.stdin.close()

    decoder.wait(timeout=30)
    encoder_process.wait(timeout=120)
    if decoder.returncode != 0:
        raise RuntimeError("VR decoder failed: " + decoder.stderr.read().decode("utf-8", errors="replace"))
    if encoder_process.returncode != 0:
        raise RuntimeError("VR encoder failed: " + encoder_process.stderr.read().decode("utf-8", errors="replace"))
    if processed != args.frames:
        raise RuntimeError(f"depth sidecars contain {processed} frames, expected {args.frames}")
    elapsed = time.perf_counter() - started
    print(
        "VR_DEPTH_DONE " + json.dumps(
            {
                "frames": processed, "elapsed_s": elapsed, "fps": processed / max(elapsed, 1e-6),
                "holes_percent": 100.0 * hole_sum / max(processed, 1),
                "method": args.stereo_method,
                "temporal": "motion" if use_motion else args.temporal_mode,
                "pixel_format": args.pixel_format, "output": str(args.output_video),
            }, separators=(",", ":"),
        ), flush=True,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"VR_DEPTH_ERROR {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise
