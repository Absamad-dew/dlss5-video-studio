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


def read_exact_into(stream: BinaryIO, target: memoryview) -> int:
    """Fill a reusable (normally CUDA-pinned) host buffer without allocations."""
    view = target.cast("B")
    offset = 0
    while offset < len(view):
        received = stream.readinto(view[offset:])
        if not received:
            break
        offset += received
    return offset


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


def robust_depth_range(
    depth: torch.Tensor,
    trim_percent: float,
    previous_range: tuple[float, float] | None,
    smoothing: float,
) -> tuple[torch.Tensor, tuple[float, float]]:
    """Normalize useful depth while suppressing unstable per-frame outliers."""
    trim = max(0.0, min(20.0, trim_percent)) * 0.01
    if trim <= 0.0:
        return depth.float(), (0.0, 1.0)
    sample = depth.float()[..., ::2, ::2]
    low = float(torch.quantile(sample, trim).item())
    high = float(torch.quantile(sample, 1.0 - trim).item())
    if high - low < 1.0e-4:
        low, high = 0.0, 1.0
    if previous_range is not None:
        blend = max(0.0, min(0.98, smoothing))
        low = low * (1.0 - blend) + previous_range[0] * blend
        high = high * (1.0 - blend) + previous_range[1] * blend
    normalized = depth.float().sub(low).div(max(1.0e-4, high - low)).clamp_(0.0, 1.0)
    return normalized, (low, high)


def gradient_aware_depth(depth: torch.Tensor, strength: float) -> torch.Tensor:
    """Turn noisy ramps at silhouettes into clean foreground/background steps."""
    amount = max(0.0, min(1.0, strength))
    if amount <= 0.0:
        return depth
    work = depth.float()
    local_mean = F.avg_pool2d(work, 3, stride=1, padding=1)
    near = F.max_pool2d(work, 3, stride=1, padding=1)
    far = -F.max_pool2d(-work, 3, stride=1, padding=1)
    separated = torch.where(work >= local_mean, near, far)
    edge = (near - far).mul(12.0).clamp_(0.0, 1.0)
    return work.lerp(separated, edge * amount)


def resolve_convergence(
    depth: torch.Tensor,
    configured: float,
    mode: str,
    previous: float | None,
    smoothing: float,
) -> float:
    if mode == "manual":
        return max(0.1, min(0.9, configured))
    _, _, height, width = depth.shape
    crop = depth[
        ...,
        max(0, height // 5) : max(1, height - height // 5),
        max(0, width // 5) : max(1, width - width // 5),
    ].float()
    if mode == "subject":
        target = float(torch.quantile(crop, 0.60).item())
    else:
        target = 0.5 * (
            float(torch.quantile(crop, 0.38).item())
            + float(torch.quantile(crop, 0.68).item())
        )
    target += max(-0.25, min(0.25, configured - 0.5))
    target = max(0.12, min(0.88, target))
    if previous is None:
        return target
    blend = max(0.0, min(0.98, smoothing))
    return target * (1.0 - blend) + previous * blend


def shape_disparity_delta(delta: torch.Tensor, curve: str, comfort: float) -> torch.Tensor:
    work = delta.float()
    if curve == "cinematic":
        work = work.sign() * work.abs().clamp_min(1.0e-6).pow(0.78)
    elif curve == "comfort":
        work = torch.tanh(work * 1.8) / 1.8
    amount = max(0.0, min(1.0, comfort))
    if amount > 0.0:
        comfortable = torch.tanh(work * 2.2) / 2.2
        work = work.lerp(comfortable, amount)
    return work


def motion_quality(motion_np: np.ndarray | None) -> tuple[float, float]:
    """Return mean confidence and robust full-frame motion in pixels."""
    if motion_np is None:
        return 1.0, 0.0
    confidence = (
        motion_np["valid"].astype(np.float32)
        * motion_np["confidence"].astype(np.float32)
        * (1.0 / 255.0)
    )
    usable = confidence > (1.0 / 255.0)
    if not np.any(usable):
        return 0.0, 0.0
    denominator = np.maximum(confidence, 1.0 / 255.0)
    dx = motion_np["dx"].astype(np.float32) / denominator
    dy = motion_np["dy"].astype(np.float32) / denominator
    magnitude = np.sqrt(dx * dx + dy * dy)
    # The 75th percentile responds to camera/subject motion without allowing a
    # few bad vectors to collapse the stereo effect for the whole frame.
    return float(np.mean(confidence)), float(np.percentile(magnitude[usable], 75.0))


def background_plate(
    frame: torch.Tensor, depth: torch.Tensor, disparity: torch.Tensor, radius: int
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    """Create a far-layer plate used only where reprojection reveals hidden pixels."""
    radius = max(1, min(48, radius))
    kernel = radius * 2 + 1
    pooled, indices = F.max_pool2d(
        -depth.float(), (1, kernel), stride=1, padding=(0, radius), return_indices=True
    )
    flat_indices = indices.reshape(1, -1)
    flat_frame = frame[0].float().reshape(frame.shape[1], -1)
    plate = torch.gather(flat_frame, 1, flat_indices.expand(frame.shape[1], -1)).reshape_as(frame)
    plate_disparity = torch.gather(
        disparity.float().reshape(1, -1), 1, flat_indices
    ).reshape_as(disparity)
    return plate, -pooled, plate_disparity


def forward_splat(
    frame: torch.Tensor,
    depth: torch.Tensor,
    disparity_px: torch.Tensor,
    x: torch.Tensor,
    rows: torch.Tensor,
    sign: float,
    z_strength: float,
    ldi_layers: int,
) -> tuple[torch.Tensor, torch.Tensor]:
    _, channels, height, width = frame.shape
    device = frame.device
    work_frame = frame[0].float()
    work_depth = depth[0, 0].float()
    target = x + disparity_px.float() * sign
    x0 = torch.floor(target)
    fraction = target - x0
    layers = max(2, min(12, ldi_layers))
    priority_depth = torch.round(work_depth * (layers - 1)) / float(layers - 1)
    z_weight = torch.exp2((priority_depth - 0.5) * max(0.0, z_strength)).clamp_(0.03125, 32.0)
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
    return view, visible >= 0.02


def sparse_push_pull_fill(
    view: torch.Tensor,
    valid: torch.Tensor,
    fallback: torch.Tensor,
    fill_strength: float,
    fill_radius: int,
) -> tuple[torch.Tensor, torch.Tensor]:
    result = view.float()
    filled = valid
    maximum = max(1, min(48, fill_radius))
    radius = 1
    while radius <= maximum:
        kernel = radius * 2 + 1
        weights = F.avg_pool2d(filled.float(), (1, kernel), stride=1, padding=(0, radius))
        colours = F.avg_pool2d(result * filled.float(), (1, kernel), stride=1, padding=(0, radius))
        candidate = colours / weights.clamp_min(1.0e-4)
        newly_filled = (~filled) & (weights > 1.0e-4)
        result = torch.where(newly_filled, candidate, result)
        filled = filled | newly_filled
        radius *= 2
    strength = max(0.0, min(1.0, fill_strength))
    result = torch.where(filled, result, fallback.float().lerp(result, 1.0 - strength))
    return result, filled


def warp_history(
    image: torch.Tensor,
    valid: torch.Tensor,
    motion_np: np.ndarray,
    source_width: int,
    source_height: int,
    grid_cache: dict[tuple[int, int, int, int], torch.Tensor],
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    target_height, target_width = image.shape[-2:]
    gh, gw = motion_np.shape
    confidence_np = motion_np["confidence"].astype(np.float32) * (1.0 / 255.0)
    confidence_np *= motion_np["valid"].astype(np.float32)
    denominator = np.maximum(confidence_np, 1.0 / 255.0)
    dx = torch.from_numpy(motion_np["dx"].astype(np.float32) / denominator).to(image.device)[None, None]
    dy = torch.from_numpy(motion_np["dy"].astype(np.float32) / denominator).to(image.device)[None, None]
    confidence = torch.from_numpy(confidence_np).to(image.device)[None, None]
    if (gh, gw) != (target_height, target_width):
        dx = F.interpolate(dx, size=(target_height, target_width), mode="bilinear", align_corners=False)
        dy = F.interpolate(dy, size=(target_height, target_width), mode="bilinear", align_corners=False)
        confidence = F.interpolate(confidence, size=(target_height, target_width), mode="bilinear", align_corners=False)
    key = (target_height, target_width, gh, gw)
    base = grid_cache.get(key)
    if base is None:
        gy, gx = torch.meshgrid(
            torch.linspace(-1.0, 1.0, target_height, device=image.device),
            torch.linspace(-1.0, 1.0, target_width, device=image.device),
            indexing="ij",
        )
        base = torch.stack((gx, gy), dim=-1)[None]
        grid_cache[key] = base
    grid = base + torch.stack(
        (
            dx[0, 0] * (2.0 / max(1, source_width - 1)),
            dy[0, 0] * (2.0 / max(1, source_height - 1)),
        ), dim=-1,
    )[None]
    warped_image = F.grid_sample(
        image.float(), grid, mode="bilinear", padding_mode="border", align_corners=True
    )
    warped_valid = F.grid_sample(
        valid.float(), grid, mode="bilinear", padding_mode="zeros", align_corners=True
    ) > 0.75
    return warped_image, warped_valid, confidence


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
    ldi_layers: int = 6,
) -> tuple[torch.Tensor, float]:
    """Forward soft z-splat that retains foreground ownership."""
    view, valid = forward_splat(
        frame, depth, disparity_px, x, rows, sign, z_strength, ldi_layers
    )
    holes = ~valid
    hole_fraction = float(holes.float().mean().item())
    if holes.any():
        view, _ = sparse_push_pull_fill(view, valid, frame, fill_strength, fill_radius)
    return view.to(frame.dtype), hole_fraction


def temporal_ldi_splat(
    frame: torch.Tensor,
    depth: torch.Tensor,
    disparity_px: torch.Tensor,
    x: torch.Tensor,
    rows: torch.Tensor,
    sign: float,
    z_strength: float,
    fill_strength: float,
    fill_radius: int,
    ldi_layers: int,
    background_expansion: int,
    sharpen: float,
) -> tuple[torch.Tensor, float, torch.Tensor, torch.Tensor]:
    """Layered-depth reprojection with a far plate and sparse disocclusion repair."""
    primary, primary_valid = forward_splat(
        frame, depth, disparity_px, x, rows, sign, z_strength, ldi_layers
    )
    original_holes = ~primary_valid
    result = primary
    repaired_valid = primary_valid
    if original_holes.any() and background_expansion > 0:
        plate, plate_depth, plate_disparity = background_plate(
            frame, depth, disparity_px, background_expansion
        )
        background_view, background_valid = forward_splat(
            plate,
            plate_depth,
            plate_disparity,
            x,
            rows,
            sign,
            max(0.0, z_strength * 0.45),
            ldi_layers,
        )
        use_background = original_holes & background_valid
        result = torch.where(use_background, background_view, result)
        repaired_valid = repaired_valid | use_background
    result, _ = sparse_push_pull_fill(
        result, repaired_valid, frame, fill_strength, fill_radius
    )
    sharpen_amount = max(0.0, min(1.0, sharpen))
    if sharpen_amount > 0.0:
        blurred = F.avg_pool2d(result, 3, stride=1, padding=1)
        sharpened = (result + (result - blurred) * (0.65 * sharpen_amount)).clamp_(0.0, 1.0)
        result = torch.where(original_holes, sharpened, result)
    return (
        result.to(frame.dtype),
        float(original_holes.float().mean().item()),
        original_holes,
        repaired_valid,
    )


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
    parser.add_argument("--right-seed-output", type=Path)
    parser.add_argument("--right-mask-output", type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--frames", required=True, type=int)
    parser.add_argument("--fps", required=True, type=float)
    parser.add_argument(
        "--layout", choices=["half-sbs", "full-sbs", "half-ou", "full-ou"], default="half-sbs"
    )
    parser.add_argument(
        "--stereo-method", choices=["inverse", "layered", "temporal-ldi"],
        default="temporal-ldi",
    )
    parser.add_argument("--eye-anchor", choices=["symmetric", "left", "right"], default="symmetric")
    parser.add_argument("--temporal-mode", choices=["off", "ema", "motion"], default="motion")
    parser.add_argument(
        "--convergence-mode", choices=["manual", "subject", "comfort"], default="subject"
    )
    parser.add_argument(
        "--disparity-curve", choices=["linear", "comfort", "cinematic"], default="cinematic"
    )
    parser.add_argument("--eye-separation", type=float, default=1.0)
    parser.add_argument("--convergence", type=float, default=0.48)
    parser.add_argument("--convergence-smoothing", type=float, default=0.88)
    parser.add_argument("--depth-gamma", type=float, default=1.0)
    parser.add_argument("--depth-trim-percent", type=float, default=1.5)
    parser.add_argument("--depth-range-smoothing", type=float, default=0.90)
    parser.add_argument("--edge-protection", type=float, default=0.70)
    parser.add_argument("--comfort-strength", type=float, default=0.30)
    parser.add_argument("--foreground-strength", type=float, default=1.0)
    parser.add_argument("--background-strength", type=float, default=0.75)
    parser.add_argument("--z-buffer-strength", type=float, default=5.0)
    parser.add_argument("--occlusion-fill", type=float, default=0.72)
    parser.add_argument("--hole-fill-radius", type=int, default=8)
    parser.add_argument("--ldi-layers", type=int, default=6)
    parser.add_argument("--background-expansion", type=int, default=16)
    parser.add_argument("--temporal-fill", type=float, default=0.75)
    parser.add_argument("--temporal-fill-confidence", type=float, default=0.35)
    parser.add_argument("--inpaint-sharpen", type=float, default=0.35)
    parser.add_argument("--adaptive-comfort", type=float, default=0.65)
    parser.add_argument("--motion-safety-pixels", type=float, default=14.0)
    parser.add_argument("--scene-cut-ramp-frames", type=int, default=6)
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
    use_temporal_repair = (
        args.stereo_method == "temporal-ldi"
        and args.temporal_fill > 0.0
        and bool(motion_paths)
    )
    motion_iterator = (
        iter(motion_frames(motion_paths)) if use_motion or use_temporal_repair else None
    )

    width, height = args.width, args.height
    output_width = width * 2 if args.layout == "full-sbs" else width
    output_height = height * 2 if args.layout == "full-ou" else height
    eye_width = width // 2 if args.layout == "half-sbs" else width
    eye_height = height // 2 if args.layout == "half-ou" else height
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

    right_seed_command = None
    right_mask_command = None
    if args.right_seed_output is not None:
        right_seed_command = [
            str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-s:v", f"{eye_width}x{eye_height}",
            "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an", "-c:v", "ffv1",
            "-level", "3", "-coder", "1", "-context", "1", "-pix_fmt", "bgr0",
            "-frames:v", str(args.frames), str(args.right_seed_output),
        ]
    if args.right_mask_output is not None:
        right_mask_command = [
            str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
            "-f", "rawvideo", "-pix_fmt", "gray", "-s:v", f"{eye_width}x{eye_height}",
            "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an", "-c:v", "ffv1",
            "-level", "3", "-coder", "1", "-context", "1", "-pix_fmt", "gray",
            "-frames:v", str(args.frames), str(args.right_mask_output),
        ]

    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    decoder = subprocess.Popen(
        decoder_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL, creationflags=creation_flags,
    )
    encoder_process = subprocess.Popen(
        encoder_command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE, creationflags=creation_flags,
    )
    right_seed_process = (
        subprocess.Popen(
            right_seed_command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, creationflags=creation_flags,
        )
        if right_seed_command is not None else None
    )
    right_mask_process = (
        subprocess.Popen(
            right_mask_command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, creationflags=creation_flags,
        )
        if right_mask_command is not None else None
    )
    if decoder.stdout is None or encoder_process.stdin is None:
        raise RuntimeError("could not create VR video pipes")

    torch.backends.cudnn.benchmark = True
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.set_grad_enabled(False)
    device = torch.device("cuda")
    dtype = torch.float16
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
    # Flat RGB pipes are still required for the portable FFmpeg build, but the
    # old loop allocated and copied two 25 MB host buffers per 4K frame. Keep
    # reusable page-locked staging on both sides so CUDA DMA can use the copy
    # engines and Python never materializes frame.tobytes().
    input_staging = torch.empty((height, width, 3), dtype=torch.uint8, pin_memory=True)
    input_staging_view = memoryview(input_staging.numpy())
    output_staging = torch.empty(
        (output_height, output_width, 3), dtype=torch.uint8, pin_memory=True
    )
    output_staging_view = memoryview(output_staging.numpy()).cast("B")
    right_seed_staging = (
        torch.empty((eye_height, eye_width, 3), dtype=torch.uint8, pin_memory=True)
        if right_seed_process is not None else None
    )
    right_mask_staging = (
        torch.empty((eye_height, eye_width), dtype=torch.uint8, pin_memory=True)
        if right_mask_process is not None else None
    )
    right_seed_staging_view = (
        memoryview(right_seed_staging.numpy()).cast("B")
        if right_seed_staging is not None else None
    )
    right_mask_staging_view = (
        memoryview(right_mask_staging.numpy()).cast("B")
        if right_mask_staging is not None else None
    )
    started = time.perf_counter()
    processed = 0
    hole_sum = 0.0
    temporal_repair_sum = 0.0
    convergence_sum = 0.0
    adaptive_scale_sum = 0.0
    motion_pixels_sum = 0.0
    previous_depth: torch.Tensor | None = None
    motion_grid_cache: dict[tuple[int, int], torch.Tensor] = {}
    history_grid_cache: dict[tuple[int, int, int, int], torch.Tensor] = {}
    previous_left: torch.Tensor | None = None
    previous_right: torch.Tensor | None = None
    previous_left_valid: torch.Tensor | None = None
    previous_right_valid: torch.Tensor | None = None
    previous_range: tuple[float, float] | None = None
    previous_convergence: float | None = None
    previous_adaptive_scale: float | None = None
    frames_since_scene_cut = max(0, args.scene_cut_ramp_frames)
    try:
        with torch.inference_mode():
            for index, (depth_np, _, _) in enumerate(depth_frames(depth_paths)):
                if index >= args.frames:
                    break
                received = read_exact_into(decoder.stdout, input_staging_view)
                if received != extent:
                    details = decoder.stderr.read().decode("utf-8", errors="replace").strip()
                    raise RuntimeError(f"video decoder ended at frame {index}: {details}")
                frame = input_staging.to(device=device, non_blocking=True)
                frame = frame.permute(2, 0, 1)[None].to(dtype=dtype).div_(255.0)
                depth = torch.from_numpy(depth_np.astype(np.float32, copy=False)).to(device)[None, None]
                motion_np = next(motion_iterator)[0] if motion_iterator is not None else None
                motion_confidence, motion_pixels = motion_quality(motion_np)
                scene_change = motion_np is not None and motion_confidence < 0.035
                if scene_change:
                    previous_depth = None
                    previous_left = previous_right = None
                    previous_left_valid = previous_right_valid = None
                    previous_range = None
                    previous_convergence = None
                    previous_adaptive_scale = None
                    frames_since_scene_cut = 0
                else:
                    frames_since_scene_cut += 1
                temporal = max(0.0, min(0.95, args.temporal_smoothing))
                if args.temporal_mode == "off":
                    temporal = 0.0
                depth_motion_np = motion_np if args.temporal_mode == "motion" else None
                depth, previous_range = robust_depth_range(
                    depth,
                    args.depth_trim_percent,
                    previous_range,
                    args.depth_range_smoothing,
                )
                depth = motion_compensated_depth(
                    depth, previous_depth, depth_motion_np, width, height, temporal, motion_grid_cache
                ).clamp_(0.0, 1.0)
                previous_depth = depth.detach().clone()
                depth = depth.pow(max(0.25, min(3.0, args.depth_gamma)))
                depth = edge_aware_feather(depth, args.edge_feather)
                convergence = resolve_convergence(
                    depth,
                    args.convergence,
                    args.convergence_mode,
                    previous_convergence,
                    args.convergence_smoothing,
                )
                previous_convergence = convergence
                convergence_sum += convergence
                depth = F.interpolate(depth, size=(height, width), mode="bilinear", align_corners=False)
                if (eye_height, eye_width) != (height, width):
                    frame = F.interpolate(frame, size=(eye_height, eye_width), mode="bilinear", align_corners=False)
                    depth = F.interpolate(depth, size=(eye_height, eye_width), mode="bilinear", align_corners=False)
                depth = gradient_aware_depth(depth, args.edge_protection)

                delta = shape_disparity_delta(
                    depth[0, 0] - convergence,
                    args.disparity_curve,
                    args.comfort_strength,
                )
                foreground = max(0.0, min(2.0, args.foreground_strength))
                background = max(0.0, min(2.0, args.background_strength))
                delta = torch.where(delta >= 0, delta * foreground, delta * background)
                limit = eye_width * (min(5.0, max(0.5, args.max_disparity_percent)) / 100.0)
                disparity = delta * (limit * max(0.1, min(3.0, args.eye_separation)))
                adaptive = max(0.0, min(1.0, args.adaptive_comfort))
                safety_pixels = max(1.0, min(40.0, args.motion_safety_pixels))
                motion_risk = min(1.0, motion_pixels / safety_pixels)
                confidence_risk = max(0.0, min(1.0, (0.35 - motion_confidence) / 0.35))
                adaptive_target = 1.0 - adaptive * (0.38 * motion_risk + 0.24 * confidence_risk)
                ramp_frames = max(0, min(24, args.scene_cut_ramp_frames))
                if ramp_frames > 0 and frames_since_scene_cut < ramp_frames:
                    cut_progress = (frames_since_scene_cut + 1) / float(ramp_frames)
                    # Never collapse the intended stereo impact. The ramp only
                    # removes the uncomfortable instantaneous jump at a cut.
                    adaptive_target *= 0.70 + 0.30 * cut_progress
                adaptive_target = max(0.35, min(1.0, adaptive_target))
                if previous_adaptive_scale is None:
                    adaptive_scale = adaptive_target
                else:
                    # Reduce quickly for comfort, restore slowly so the volume
                    # never "breathes" when motion confidence oscillates.
                    follow = 0.55 if adaptive_target < previous_adaptive_scale else 0.30
                    adaptive_scale = previous_adaptive_scale + follow * (
                        adaptive_target - previous_adaptive_scale
                    )
                previous_adaptive_scale = adaptive_scale
                disparity = disparity * adaptive_scale
                adaptive_scale_sum += adaptive_scale
                motion_pixels_sum += motion_pixels
                if args.eye_anchor == "left":
                    left_shift, right_shift = 0.0, -2.0
                elif args.eye_anchor == "right":
                    left_shift, right_shift = 2.0, 0.0
                else:
                    left_shift, right_shift = 1.0, -1.0

                def render_eye(
                    shift: float,
                ) -> tuple[torch.Tensor, float, torch.Tensor, torch.Tensor]:
                    if shift == 0:
                        valid = torch.ones(
                            (1, 1, eye_height, eye_width), device=device, dtype=torch.bool
                        )
                        return frame, 0.0, ~valid, valid
                    if args.stereo_method == "temporal-ldi":
                        return temporal_ldi_splat(
                            frame,
                            depth,
                            disparity,
                            splat_x,
                            splat_rows,
                            shift,
                            args.z_buffer_strength,
                            args.occlusion_fill,
                            args.hole_fill_radius,
                            args.ldi_layers,
                            args.background_expansion,
                            args.inpaint_sharpen,
                        )
                    if args.stereo_method == "layered":
                        rendered, holes_fraction = layered_splat(
                            frame, depth, disparity, splat_x, splat_rows, shift, args.z_buffer_strength,
                            args.occlusion_fill, args.hole_fill_radius, args.ldi_layers,
                        )
                        valid = torch.ones(
                            (1, 1, eye_height, eye_width), device=device, dtype=torch.bool
                        )
                        return rendered, holes_fraction, ~valid, valid
                    rendered, holes_fraction = inverse_warp(
                        frame, disparity, x, y, shift, args.occlusion_fill
                    )
                    valid = torch.ones(
                        (1, 1, eye_height, eye_width), device=device, dtype=torch.bool
                    )
                    return rendered, holes_fraction, ~valid, valid

                left, left_holes, left_hole_mask, left_valid = render_eye(left_shift)
                right, right_holes, right_hole_mask, right_valid = render_eye(right_shift)
                hole_sum += 0.5 * (left_holes + right_holes)
                if use_temporal_repair and motion_np is not None and not scene_change:
                    threshold = max(0.0, min(1.0, args.temporal_fill_confidence))
                    amount = max(0.0, min(1.0, args.temporal_fill))

                    def repair_from_history(
                        current: torch.Tensor,
                        holes: torch.Tensor,
                        current_valid: torch.Tensor,
                        history: torch.Tensor | None,
                        history_valid: torch.Tensor | None,
                    ) -> tuple[torch.Tensor, torch.Tensor, float]:
                        if history is None or history_valid is None:
                            return current, current_valid, 0.0
                        warped, warped_valid, confidence = warp_history(
                            history,
                            history_valid,
                            motion_np,
                            width,
                            height,
                            history_grid_cache,
                        )
                        eligible = holes & warped_valid & (confidence >= threshold)
                        blend = eligible.float() * confidence.clamp_(0.0, 1.0) * amount
                        repaired = current.float().mul(1.0 - blend).add_(warped.mul(blend))
                        return repaired.to(current.dtype), current_valid | eligible, float(eligible.float().mean().item())

                    left, left_valid, left_repaired = repair_from_history(
                        left, left_hole_mask, left_valid, previous_left, previous_left_valid
                    )
                    right, right_valid, right_repaired = repair_from_history(
                        right, right_hole_mask, right_valid, previous_right, previous_right_valid
                    )
                    temporal_repair_sum += 0.5 * (left_repaired + right_repaired)
                previous_left = left.detach().clone()
                previous_right = right.detach().clone()
                previous_left_valid = left_valid.detach().clone()
                previous_right_valid = right_valid.detach().clone()
                # The generative second-eye backend consumes the geometrically
                # correct right-eye seed and the original disocclusion mask.
                # Export these before optional eye swapping and before packing
                # into a squeezed headset layout so the network always sees an
                # undistorted full eye.
                if right_seed_process is not None and right_seed_staging is not None:
                    right_seed_u8 = (
                        right[0].permute(1, 2, 0).mul(255.0).clamp_(0, 255).byte().contiguous()
                    )
                    right_seed_staging.copy_(right_seed_u8, non_blocking=True)
                if right_mask_process is not None and right_mask_staging is not None:
                    right_mask_u8 = right_hole_mask[0, 0].mul(255.0).byte().contiguous()
                    right_mask_staging.copy_(right_mask_u8, non_blocking=True)
                if args.eye_swap:
                    left, right = right, left
                if args.layout in ("half-sbs", "full-sbs"):
                    stereo = torch.cat((left, right), dim=3)
                else:
                    stereo = torch.cat((left, right), dim=2)
                stereo_u8 = (
                    stereo[0].permute(1, 2, 0).mul_(255.0).clamp_(0, 255).byte().contiguous()
                )
                output_staging.copy_(stereo_u8, non_blocking=True)
                torch.cuda.current_stream().synchronize()
                encoder_process.stdin.write(output_staging_view)
                if right_seed_process is not None and right_seed_process.stdin is not None:
                    right_seed_process.stdin.write(right_seed_staging_view)
                if right_mask_process is not None and right_mask_process.stdin is not None:
                    right_mask_process.stdin.write(right_mask_staging_view)
                processed += 1
                if processed == 1 or processed % 30 == 0 or processed == args.frames:
                    elapsed = time.perf_counter() - started
                    print(
                        "VR_DEPTH_PROGRESS " + json.dumps(
                            {
                                "frames": processed, "total": args.frames,
                                "fps": processed / max(elapsed, 1e-6),
                                "holes_percent": 100.0 * hole_sum / processed,
                                "temporal_repair_percent": 100.0 * temporal_repair_sum / processed,
                                "convergence": convergence_sum / processed,
                                "adaptive_stereo_scale": adaptive_scale_sum / processed,
                                "motion_pixels_p75": motion_pixels_sum / processed,
                                "method": args.stereo_method,
                                "temporal": "motion" if use_motion else args.temporal_mode,
                            }, separators=(",", ":"),
                        ), flush=True,
                    )
    finally:
        decoder.stdout.close()
        encoder_process.stdin.close()
        if right_seed_process is not None and right_seed_process.stdin is not None:
            right_seed_process.stdin.close()
        if right_mask_process is not None and right_mask_process.stdin is not None:
            right_mask_process.stdin.close()

    decoder.wait(timeout=30)
    encoder_process.wait(timeout=120)
    if right_seed_process is not None:
        right_seed_process.wait(timeout=120)
    if right_mask_process is not None:
        right_mask_process.wait(timeout=120)
    if decoder.returncode != 0:
        raise RuntimeError("VR decoder failed: " + decoder.stderr.read().decode("utf-8", errors="replace"))
    if encoder_process.returncode != 0:
        raise RuntimeError("VR encoder failed: " + encoder_process.stderr.read().decode("utf-8", errors="replace"))
    if right_seed_process is not None and right_seed_process.returncode != 0:
        raise RuntimeError(
            "VR right-eye seed encoder failed: "
            + right_seed_process.stderr.read().decode("utf-8", errors="replace")
        )
    if right_mask_process is not None and right_mask_process.returncode != 0:
        raise RuntimeError(
            "VR disocclusion-mask encoder failed: "
            + right_mask_process.stderr.read().decode("utf-8", errors="replace")
        )
    if processed != args.frames:
        raise RuntimeError(f"depth sidecars contain {processed} frames, expected {args.frames}")
    elapsed = time.perf_counter() - started
    print(
        "VR_DEPTH_DONE " + json.dumps(
            {
                "frames": processed, "elapsed_s": elapsed, "fps": processed / max(elapsed, 1e-6),
                "holes_percent": 100.0 * hole_sum / max(processed, 1),
                "temporal_repair_percent": 100.0 * temporal_repair_sum / max(processed, 1),
                "mean_convergence": convergence_sum / max(processed, 1),
                "mean_adaptive_stereo_scale": adaptive_scale_sum / max(processed, 1),
                "mean_motion_pixels_p75": motion_pixels_sum / max(processed, 1),
                "method": args.stereo_method,
                "temporal": "motion" if use_motion else args.temporal_mode,
                "pixel_format": args.pixel_format, "output": str(args.output_video),
                "right_seed_output": str(args.right_seed_output) if args.right_seed_output else None,
                "right_mask_output": str(args.right_mask_output) if args.right_mask_output else None,
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
