"""Create a temporally stable depth-warped stereoscopic video on CUDA."""

from __future__ import annotations

import argparse
import json
import math
import os
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
IW3_COMMIT = "d23721f1b5f0a4c92c3ee1be013180bf298730c5"
ROWFLOW_CHECKPOINT = "iw3_row_flow_v3_20250627.pth"


def load_rowflow_v3(root: Path):
    """Load the pinned iw3 RowFlow model without invoking iw3 depth inference.

    Studio owns decoding, canonical depth, temporal alignment and encoding.  Only
    the compact RowFlow stereo warp is imported from the pinned nunif install.
    This is deliberately a model-only adapter: running ``iw3_main`` here would
    decode the video and calculate depth for a second time.
    """
    root = root.resolve()
    code = root / "third_party" / "nunif"
    status_path = root / "models" / "iw3" / "install.json"
    checkpoint = (
        root
        / "models"
        / "iw3"
        / "pretrained_models"
        / "hub"
        / "checkpoints"
        / ROWFLOW_CHECKPOINT
    )
    if not (code / "iw3" / "backward_warp.py").is_file() or not status_path.is_file():
        raise RuntimeError(
            "RowFlow V3 is not installed. Run INSTALL_IW3.cmd in the program folder."
        )
    status = json.loads(status_path.read_text(encoding="utf-8"))
    if status.get("commit") != IW3_COMMIT:
        raise RuntimeError("RowFlow V3 engine version mismatch. Run INSTALL_IW3.cmd again.")
    if not checkpoint.is_file() or checkpoint.stat().st_size <= 0:
        raise RuntimeError(
            f"RowFlow V3 checkpoint is missing: {checkpoint}. Run INSTALL_IW3.cmd."
        )
    sys.path[:0] = [str(root / "models" / "iw3" / "site-packages"), str(code)]
    os.environ["NUNIF_HOME"] = str(root / "models")
    os.environ["TORCH_HOME"] = str(root / "models" / "iw3" / "torch")
    os.environ["HF_HOME"] = str(root / "models" / "iw3" / "huggingface")
    os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")
    # Importing the model package registers RowFlowV3 with nunif.load_model.
    import iw3.models  # noqa: F401
    from iw3.backward_warp import apply_divergence_nn_LR
    from iw3.dilation import dilate_edge
    from iw3.stereo_model_factory import create_stereo_model

    model = create_stereo_model("row_flow_v3", divergence=5.0, device_id=0)
    return model, apply_divergence_nn_LR, dilate_edge


def rowflow_auto_steps(divergence_percent: float, eye_anchor: str) -> int:
    """Mirror iw3 V3's trained-range policy for our dynamic stereo strength."""
    model_divergence = divergence_percent * (1.0 if eye_anchor == "symmetric" else 2.0)
    return 1 if model_divergence <= 5.0 else max(2, math.ceil(model_divergence / 4.0))


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


def eye_shift_factors(anchor: str) -> tuple[float, float]:
    """Map one physical eye baseline across the selected camera anchor.

    `disparity` already represents the full left-to-right separation.  The old
    factors used +/-1 for symmetric and -2 for a left anchor, accidentally
    doubling parallax, disocclusion width and VR discomfort.
    """
    if anchor == "left":
        return 0.0, -1.0
    if anchor == "right":
        return 1.0, 0.0
    return 0.5, -0.5


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
    return_uncertain: bool = False,
) -> tuple[torch.Tensor, torch.Tensor] | tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    _, channels, height, width = frame.shape
    device = frame.device
    work_frame = frame[0].float()
    work_depth = depth[0, 0].float()
    target = x + disparity_px.float() * sign
    x0 = torch.floor(target)
    fraction = target - x0
    layers = max(2, min(12, ldi_layers))
    priority_depth = torch.round(work_depth * (layers - 1)) / float(layers - 1)
    # A soft exponential z weight used to average foreground and background
    # colours at depth discontinuities.  On real footage that creates the
    # characteristic torn/transparent halo around people.  Resolve visibility
    # first and only accumulate contributors from the nearest discrete layer.
    # Bilinear weights are retained inside that winning layer.
    flat_priority = priority_depth.reshape(-1)
    nearest = torch.full(
        (height * width,), -torch.inf, device=device, dtype=torch.float32
    )
    farthest = torch.full(
        (height * width,), torch.inf, device=device, dtype=torch.float32
    )
    contribution_geometry: list[tuple[torch.Tensor, torch.Tensor, torch.Tensor]] = []
    for offset, bilinear in ((0, 1.0 - fraction), (1, fraction)):
        target_x = x0.to(torch.int64) + offset
        valid = (target_x >= 0) & (target_x < width) & (bilinear > 1.0e-4)
        index = (rows + target_x.clamp(0, width - 1)).reshape(-1)
        priority = torch.where(valid.reshape(-1), flat_priority, -torch.inf)
        nearest.scatter_reduce_(0, index, priority, reduce="amax", include_self=True)
        far_priority = torch.where(valid.reshape(-1), flat_priority, torch.inf)
        farthest.scatter_reduce_(0, index, far_priority, reduce="amin", include_self=True)
        contribution_geometry.append((index, valid.reshape(-1), bilinear.reshape(-1)))

    accum = torch.zeros((channels, height * width), device=device, dtype=torch.float32)
    weights = torch.zeros((height * width,), device=device, dtype=torch.float32)
    back_accum = torch.zeros((channels, height * width), device=device, dtype=torch.float32)
    back_weights = torch.zeros((height * width,), device=device, dtype=torch.float32)
    flat_rgb = work_frame.reshape(channels, -1)
    layer_step = 1.0 / float(max(1, layers - 1))
    z_tolerance = layer_step * max(0.06, min(0.45, 0.95 / max(1.0, z_strength)))
    for index, valid, bilinear in contribution_geometry:
        winning_layer = flat_priority >= (nearest[index] - z_tolerance)
        weight = bilinear * valid * winning_layer
        weights.scatter_add_(0, index, weight)
        accum.scatter_add_(1, index[None].expand(channels, -1), flat_rgb * weight)
        backing_layer = flat_priority <= (farthest[index] + z_tolerance)
        back_weight = bilinear * valid * backing_layer
        back_weights.scatter_add_(0, index, back_weight)
        back_accum.scatter_add_(
            1, index[None].expand(channels, -1), flat_rgb * back_weight
        )
    visible = weights.reshape(1, 1, height, width)
    view = (accum / weights.clamp_min(1.0e-5)[None]).reshape(1, channels, height, width)
    # At a depth edge, a foreground sample can cover only a fraction of the
    # target pixel. Preserve z ownership for fully covered pixels, but use the
    # far layer for the uncovered sub-pixel area. This is a one-pixel analytic
    # antialias, not the old wide exponential blend that produced ghost halos.
    back_view = (
        back_accum / back_weights.clamp_min(1.0e-5)[None]
    ).reshape(1, channels, height, width)
    coverage = weights.reshape(1, 1, height, width).clamp_(0.0, 1.0)
    has_two_layers = (
        torch.isfinite(nearest)
        & torch.isfinite(farthest)
        & ((nearest - farthest) > layer_step * 0.55)
        & (back_weights > 1.0e-4)
    ).reshape(1, 1, height, width)
    subpixel_edge = has_two_layers & (coverage < 0.999)
    antialiased = view * coverage + back_view * (1.0 - coverage)
    view = torch.where(subpixel_edge, antialiased, view)
    valid_view = visible >= 0.02
    if not return_uncertain:
        return view, valid_view
    collision = has_two_layers
    return view, valid_view, collision


def reprojection_guard_mask(
    holes: torch.Tensor,
    depth_collisions: torch.Tensor,
    effective_disparity: torch.Tensor,
) -> torch.Tensor:
    """Give the inpainting model context around unstable disocclusions."""
    disparity = effective_disparity.float()
    horizontal_edge = torch.zeros_like(disparity, dtype=torch.bool)
    horizontal_edge[:, 1:] = (disparity[:, 1:] - disparity[:, :-1]).abs() > 0.75
    horizontal_edge[:, :-1] |= horizontal_edge[:, 1:]
    edge = horizontal_edge[None, None]
    robust_shift = float(torch.quantile(disparity.abs().reshape(-1), 0.995).item())
    horizontal_radius = max(2, min(14, int(math.ceil(robust_shift * 0.16))))
    # One-pixel gaps are a normal consequence of quantized forward splatting
    # and the fast push/pull plate handles them better than a diffusion model.
    # Select only dense disocclusions, then add collision/edge pixels that are
    # connected to such a region.  This prevents every sign and pavement seam
    # from becoming a generative ROI.
    density = F.avg_pool2d(holes.float(), kernel_size=5, stride=1, padding=2)
    dense_holes = density >= 0.24
    near_dense_hole = F.max_pool2d(
        dense_holes.float(),
        kernel_size=(5, horizontal_radius * 4 + 1),
        stride=1,
        padding=(2, horizontal_radius * 2),
    ) > 0.0
    base = dense_holes | ((depth_collisions | edge) & near_dense_hole)
    # This is a conditioning mask, not a final compositing mask. Moebius needs
    # a wider view of the boundary to reconstruct coherent background.
    return F.max_pool2d(
        base.float(),
        kernel_size=(5, horizontal_radius * 2 + 1),
        stride=1,
        padding=(2, horizontal_radius),
    ) > 0.0


def directional_compose_mask(
    holes: torch.Tensor,
    conditioning_mask: torch.Tensor,
    effective_disparity: torch.Tensor,
) -> torch.Tensor:
    """Make a continuous background-side band without crossing foreground.

    Forward splatting leaves sub-pixel pinholes along a moving silhouette. A
    binary paste of those individual pixels produces coloured glitter. Join
    them vertically, then grow only opposite the image-space shift (the side
    on which hidden background becomes visible) and clip to the wider model
    conditioning mask.
    """
    disparity = effective_disparity.float()
    robust_shift = float(torch.quantile(disparity.abs().reshape(-1), 0.995).item())
    # Keep final compositing close to the actual uncovered pixels. The old
    # 8-18px growth turned a valid inpaint into a conspicuous vertical patch on
    # detailed signs and faces. The large semantic context is exported through
    # `conditioning_mask`; this mask has a different job and stays narrow.
    radius = max(1, min(6, int(math.ceil(robust_shift * 0.10))))
    joined = F.max_pool2d(holes.float(), kernel_size=(5, 1), stride=1, padding=(2, 0))
    # A negative right-eye shift reveals background to the right.  Asymmetric
    # padding makes max-pooling a one-sided dilation while retaining size.
    median_shift = float(torch.median(disparity.reshape(-1)).item())
    if median_shift <= 0.0:
        expanded = F.max_pool2d(
            F.pad(joined, (radius, 0, 0, 0)), (1, radius + 1), stride=1
        )
    else:
        expanded = F.max_pool2d(
            F.pad(joined, (0, radius, 0, 0)), (1, radius + 1), stride=1
        )
    return (expanded > 0.0) & conditioning_mask


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


def directional_nearest_indices(
    valid: torch.Tensor,
    prefer_right: bool,
) -> torch.Tensor:
    """Return a background-biased source column for every target pixel."""
    width = valid.shape[-1]
    columns = torch.arange(width, device=valid.device, dtype=torch.int64)
    columns = columns[None, None, None].expand_as(valid)
    left = torch.cummax(torch.where(valid, columns, -1), dim=-1).values
    right_candidates = torch.where(valid, columns, width)
    right = torch.flip(
        torch.cummin(torch.flip(right_candidates, dims=(-1,)), dim=-1).values,
        dims=(-1,),
    )
    if prefer_right:
        selected = torch.where(right < width, right, left)
    else:
        selected = torch.where(left >= 0, left, right)
    return selected.clamp_(0, width - 1)


def directional_background_fill(
    view: torch.Tensor,
    valid: torch.Tensor,
    prefer_right: bool,
    safety_margin: int = 2,
    mirror_texture: bool = True,
) -> torch.Tensor:
    """Mirror real background texture into narrow disocclusion bands.

    A nearest copy creates a conspicuous flat stripe. Mirroring continues the
    local background gradient and, unlike generic inpainting, can never pull
    foreground colour across the depth edge.
    """
    width = view.shape[-1]
    columns = torch.arange(width, device=view.device, dtype=torch.int64)
    columns = columns[None, None, None].expand_as(valid)
    boundary = directional_nearest_indices(valid, prefer_right)
    margin = max(0, min(8, int(safety_margin)))
    if prefer_right:
        source = boundary + margin
        if mirror_texture:
            source = source + (boundary - columns - 1).clamp_min(0)
    else:
        source = boundary - margin
        if mirror_texture:
            source = source - (columns - boundary - 1).clamp_min(0)
    source = source.clamp_(0, width - 1)
    gathered = torch.gather(view, -1, source.expand(-1, view.shape[1], -1, -1))
    return torch.where(valid, view, gathered)


def gradient_aware_parallax_warp(
    frame: torch.Tensor,
    depth: torch.Tensor,
    disparity_px: torch.Tensor,
    grid_x: torch.Tensor,
    grid_y: torch.Tensor,
    splat_x: torch.Tensor,
    splat_rows: torch.Tensor,
    sign: float,
    z_strength: float,
    ldi_layers: int,
    background_expansion: int,
    sharpen: float,
) -> tuple[torch.Tensor, float, torch.Tensor, torch.Tensor, torch.Tensor]:
    """Clean stereo warp inspired by DreamStereo GAPW.

    Forward splatting is retained only to resolve visibility and target-view
    disparity. RGB is reconstructed by backward sampling, eliminating the
    fly-pixels and partially covered colour fragments that appear around hair,
    shoulders and thin geometry in a forward RGB splat. Missing target pixels
    receive local background from the reveal side only.
    """
    target_disparity, target_valid, holes_fraction, context, compose = stereo_visibility_masks(
        depth,
        disparity_px,
        splat_x,
        splat_rows,
        sign,
        z_strength,
        ldi_layers,
    )
    prefer_right = sign < 0.0
    fill_indices = directional_nearest_indices(target_valid, prefer_right)
    filled_disparity = torch.gather(target_disparity, -1, fill_indices)

    width = frame.shape[-1]
    source_grid_x = grid_x.float() - (
        filled_disparity[0, 0] * (sign * 2.0 / max(1, width - 1))
    )
    grid = torch.stack((source_grid_x, grid_y.float()), dim=-1)[None].to(frame.dtype)
    backward = F.grid_sample(
        frame,
        grid,
        mode="bilinear",
        padding_mode="border",
        align_corners=True,
    )
    # This is only a deterministic seed. Temporal Atlas replaces these pixels
    # with real background observations from other frames before any neural
    # residual repair. Keeping the seed one-sided avoids pulling foreground
    # colour across hair and shoulders.
    directional_seed = directional_background_fill(
        backward, target_valid, prefer_right, safety_margin=2, mirror_texture=True
    )
    result = torch.where(compose, directional_seed, backward)
    vertical = F.avg_pool2d(result, kernel_size=(5, 1), stride=1, padding=(2, 0))
    result = torch.where(compose, result.lerp(vertical, 0.15), result)

    sharpen_amount = max(0.0, min(1.0, sharpen))
    if sharpen_amount > 0.0:
        blurred = F.avg_pool2d(result, 3, stride=1, padding=1)
        enhanced = (result + (result - blurred) * (0.35 * sharpen_amount)).clamp_(0.0, 1.0)
        result = torch.where(compose, enhanced, result)
    return result.to(frame.dtype), holes_fraction, context, compose, ~compose


def stereo_visibility_masks(
    depth: torch.Tensor,
    disparity_px: torch.Tensor,
    splat_x: torch.Tensor,
    splat_rows: torch.Tensor,
    sign: float,
    z_strength: float,
    ldi_layers: int,
) -> tuple[torch.Tensor, torch.Tensor, float, torch.Tensor, torch.Tensor]:
    """Resolve target visibility once for GAPW, RowFlow and Temporal Atlas.

    RowFlow is a backward neural warp and therefore does not expose true
    disocclusions.  A colour-free z-splat of the same canonical depth gives
    Atlas an accurate mask without another RGB warp or another depth model.
    """
    source_disparity = disparity_px[None, None].float()
    target_disparity, target_valid, collisions = forward_splat(
        source_disparity,
        depth,
        disparity_px,
        splat_x,
        splat_rows,
        sign,
        z_strength,
        ldi_layers,
        return_uncertain=True,
    )
    holes = ~target_valid
    # The exported masks are smooth bands derived from true uncovered pixels;
    # collisions are context only and are never pasted over the foreground.
    dense = F.avg_pool2d(holes.float(), kernel_size=3, stride=1, padding=1) >= 0.22
    dilated = F.max_pool2d(dense.float(), kernel_size=(5, 3), stride=1, padding=(2, 1))
    joined = (
        F.avg_pool2d(dilated, kernel_size=(5, 3), stride=1, padding=(2, 1)) >= 0.52
    )
    context = F.max_pool2d(joined.float(), kernel_size=(5, 9), stride=1, padding=(2, 4)) > 0
    context |= collisions & F.max_pool2d(joined.float(), 7, stride=1, padding=3).bool()
    compose = joined & context
    return (
        target_disparity,
        target_valid,
        float(holes.float().mean().item()),
        context,
        compose,
    )


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
) -> tuple[torch.Tensor, float, torch.Tensor, torch.Tensor, torch.Tensor]:
    """Layered-depth reprojection with a far plate and sparse disocclusion repair."""
    primary, primary_valid, depth_collisions = forward_splat(
        frame, depth, disparity_px, x, rows, sign, z_strength, ldi_layers,
        return_uncertain=True,
    )
    original_holes = ~primary_valid
    repair_mask = reprojection_guard_mask(
        original_holes, depth_collisions, disparity_px * float(sign)
    )
    compose_mask = directional_compose_mask(
        original_holes, repair_mask, disparity_px * float(sign)
    )
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
        repair_mask,
        compose_mask,
        repaired_valid & ~repair_mask,
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
    parser.add_argument("--root", type=Path)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--input-video", required=True, type=Path)
    parser.add_argument("--depth-directory", required=True, type=Path)
    parser.add_argument("--motion-directory", type=Path)
    parser.add_argument("--output-video", required=True, type=Path)
    parser.add_argument("--right-seed-output", type=Path)
    parser.add_argument("--right-mask-output", type=Path)
    parser.add_argument("--right-compose-mask-output", type=Path)
    parser.add_argument("--left-compose-mask-output", type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--frames", required=True, type=int)
    parser.add_argument("--fps", required=True, type=float)
    parser.add_argument(
        "--layout", choices=["half-sbs", "full-sbs", "half-ou", "full-ou"], default="half-sbs"
    )
    parser.add_argument(
        "--stereo-method",
        choices=["inverse", "layered", "temporal-ldi", "gapw", "rowflow-v3"],
        default="temporal-ldi",
    )
    parser.add_argument("--rowflow-width", type=int, default=0)
    parser.add_argument("--rowflow-steps", type=int, default=0)
    parser.add_argument("--rowflow-edge-x", type=int, default=0)
    parser.add_argument("--rowflow-edge-y", type=int, default=0)
    parser.add_argument("--rowflow-preserve-border", action="store_true")
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
    if min(args.rowflow_width, args.rowflow_steps, args.rowflow_edge_x, args.rowflow_edge_y) < 0:
        raise ValueError("RowFlow width/steps/edge dilation cannot be negative")
    rowflow_model = None
    rowflow_apply = None
    rowflow_dilate_edge = None
    rowflow_load_seconds = 0.0
    if args.stereo_method == "rowflow-v3":
        if args.root is None:
            raise ValueError("RowFlow V3 requires --root")
        load_started = time.perf_counter()
        rowflow_model, rowflow_apply, rowflow_dilate_edge = load_rowflow_v3(args.root)
        rowflow_load_seconds = time.perf_counter() - load_started
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
    right_compose_mask_command = None
    left_compose_mask_command = None
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
    if args.right_compose_mask_output is not None:
        right_compose_mask_command = [
            str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
            "-f", "rawvideo", "-pix_fmt", "gray", "-s:v", f"{eye_width}x{eye_height}",
            "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an", "-c:v", "ffv1",
            "-level", "3", "-coder", "1", "-context", "1", "-pix_fmt", "gray",
            "-frames:v", str(args.frames), str(args.right_compose_mask_output),
        ]
    if args.left_compose_mask_output is not None:
        left_compose_mask_command = [
            str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
            "-f", "rawvideo", "-pix_fmt", "gray", "-s:v", f"{eye_width}x{eye_height}",
            "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an", "-c:v", "ffv1",
            "-level", "3", "-coder", "1", "-context", "1", "-pix_fmt", "gray",
            "-frames:v", str(args.frames), str(args.left_compose_mask_output),
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
    right_compose_mask_process = (
        subprocess.Popen(
            right_compose_mask_command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, creationflags=creation_flags,
        )
        if right_compose_mask_command is not None else None
    )
    left_compose_mask_process = (
        subprocess.Popen(
            left_compose_mask_command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, creationflags=creation_flags,
        )
        if left_compose_mask_command is not None else None
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
    right_compose_mask_staging = (
        torch.empty((eye_height, eye_width), dtype=torch.uint8, pin_memory=True)
        if right_compose_mask_process is not None else None
    )
    left_compose_mask_staging = (
        torch.empty((eye_height, eye_width), dtype=torch.uint8, pin_memory=True)
        if left_compose_mask_process is not None else None
    )
    right_seed_staging_view = (
        memoryview(right_seed_staging.numpy()).cast("B")
        if right_seed_staging is not None else None
    )
    right_mask_staging_view = (
        memoryview(right_mask_staging.numpy()).cast("B")
        if right_mask_staging is not None else None
    )
    right_compose_mask_staging_view = (
        memoryview(right_compose_mask_staging.numpy()).cast("B")
        if right_compose_mask_staging is not None else None
    )
    left_compose_mask_staging_view = (
        memoryview(left_compose_mask_staging.numpy()).cast("B")
        if left_compose_mask_staging is not None else None
    )
    started = time.perf_counter()
    processed = 0
    hole_sum = 0.0
    temporal_repair_sum = 0.0
    convergence_sum = 0.0
    adaptive_scale_sum = 0.0
    motion_pixels_sum = 0.0
    rowflow_infer_seconds = 0.0
    rowflow_steps_sum = 0
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
    needs_visibility_masks = any(
        process is not None
        for process in (
            right_mask_process,
            right_compose_mask_process,
            left_compose_mask_process,
        )
    )
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
                if (
                    args.stereo_method == "rowflow-v3"
                    and (args.rowflow_edge_x > 0 or args.rowflow_edge_y > 0)
                ):
                    assert rowflow_dilate_edge is not None
                    # Exact iw3 depth-edge operation. It contracts unreliable
                    # foreground fringes before RowFlow predicts its sampling
                    # field, which is especially useful for hair and subtitles.
                    depth = -rowflow_dilate_edge(
                        -depth.float(), (args.rowflow_edge_x, args.rowflow_edge_y)
                    )
                    depth.clamp_(0.0, 1.0)

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
                left_shift, right_shift = eye_shift_factors(args.eye_anchor)

                rowflow_views: tuple[torch.Tensor, torch.Tensor] | None = None
                rowflow_start_event: torch.cuda.Event | None = None
                rowflow_end_event: torch.cuda.Event | None = None
                if args.stereo_method == "rowflow-v3":
                    assert rowflow_model is not None and rowflow_apply is not None
                    # Feed the learned warp our already stabilized canonical
                    # depth.  Artistic curve and independent foreground/
                    # background controls are encoded into the depth values;
                    # adaptive comfort remains a cheap per-frame divergence.
                    scale_pixels = max(
                        1.0e-6,
                        limit * max(0.1, min(3.0, args.eye_separation)) * adaptive_scale,
                    )
                    rowflow_depth = (convergence + disparity[None, None] / scale_pixels).clamp_(
                        0.0, 1.0
                    )
                    requested_width = args.rowflow_width or eye_width
                    model_width = max(96, min(eye_width, requested_width))
                    if rowflow_depth.shape[-1] != model_width:
                        model_height = max(2, round(eye_height * model_width / eye_width))
                        rowflow_depth = F.interpolate(
                            rowflow_depth,
                            size=(model_height, model_width),
                            mode="bilinear",
                            align_corners=True,
                            antialias=True,
                        ).clamp_(0.0, 1.0)
                    divergence_percent = (
                        min(5.0, max(0.5, args.max_disparity_percent))
                        * max(0.1, min(3.0, args.eye_separation))
                        * adaptive_scale
                    )
                    steps = args.rowflow_steps or rowflow_auto_steps(
                        divergence_percent, args.eye_anchor
                    )
                    steps = max(1, min(12, steps))
                    synthetic_view = {
                        "symmetric": "both",
                        "left": "right",
                        "right": "left",
                    }[args.eye_anchor]
                    # CUDA calls are asynchronous. Events keep the RowFlow
                    # telemetry honest without adding a second synchronization
                    # point or slowing the frame pipeline.
                    rowflow_start_event = torch.cuda.Event(enable_timing=True)
                    rowflow_end_event = torch.cuda.Event(enable_timing=True)
                    rowflow_start_event.record()
                    rowflow_views = rowflow_apply(
                        rowflow_model,
                        # The pinned iw3 sampler builds a float32 grid after
                        # its AMP model call; its public path expects RGB in
                        # float32 as well. Keep that exact contract here.
                        frame.float(),
                        rowflow_depth,
                        divergence_percent,
                        convergence,
                        steps,
                        synthetic_view=synthetic_view,
                        preserve_screen_border=args.rowflow_preserve_border,
                        enable_amp=True,
                    )
                    rowflow_end_event.record()
                    rowflow_steps_sum += steps

                def render_eye(
                    shift: float,
                ) -> tuple[torch.Tensor, float, torch.Tensor, torch.Tensor, torch.Tensor]:
                    if shift == 0:
                        valid = torch.ones(
                            (1, 1, eye_height, eye_width), device=device, dtype=torch.bool
                        )
                        return frame, 0.0, ~valid, ~valid, valid
                    if args.stereo_method == "rowflow-v3":
                        assert rowflow_views is not None
                        rendered = rowflow_views[0] if shift > 0 else rowflow_views[1]
                        if not needs_visibility_masks:
                            valid = torch.ones(
                                (1, 1, eye_height, eye_width),
                                device=device,
                                dtype=torch.bool,
                            )
                            return rendered, 0.0, ~valid, ~valid, valid
                        _, valid, holes_fraction, context, compose = stereo_visibility_masks(
                            depth,
                            disparity,
                            splat_x,
                            splat_rows,
                            shift,
                            args.z_buffer_strength,
                            args.ldi_layers,
                        )
                        return rendered, holes_fraction, context, compose, valid & ~compose
                    if args.stereo_method == "gapw":
                        return gradient_aware_parallax_warp(
                            frame,
                            depth,
                            disparity,
                            x,
                            y,
                            splat_x,
                            splat_rows,
                            shift,
                            args.z_buffer_strength,
                            args.ldi_layers,
                            args.background_expansion,
                            args.inpaint_sharpen,
                        )
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
                        return rendered, holes_fraction, ~valid, ~valid, valid
                    rendered, holes_fraction = inverse_warp(
                        frame, disparity, x, y, shift, args.occlusion_fill
                    )
                    valid = torch.ones(
                        (1, 1, eye_height, eye_width), device=device, dtype=torch.bool
                    )
                    return rendered, holes_fraction, ~valid, ~valid, valid

                left, left_holes, left_hole_mask, left_compose_mask, left_valid = render_eye(left_shift)
                right, right_holes, right_hole_mask, right_compose_mask, right_valid = render_eye(right_shift)
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
                        left, left_compose_mask, left_valid, previous_left, previous_left_valid
                    )
                    right, right_valid, right_repaired = repair_from_history(
                        right, right_compose_mask, right_valid, previous_right, previous_right_valid
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
                if (
                    right_compose_mask_process is not None
                    and right_compose_mask_staging is not None
                ):
                    right_compose_mask_u8 = (
                        right_compose_mask[0, 0].mul(255.0).byte().contiguous()
                    )
                    right_compose_mask_staging.copy_(right_compose_mask_u8, non_blocking=True)
                if (
                    left_compose_mask_process is not None
                    and left_compose_mask_staging is not None
                ):
                    left_compose_mask_u8 = (
                        left_compose_mask[0, 0].mul(255.0).byte().contiguous()
                    )
                    left_compose_mask_staging.copy_(left_compose_mask_u8, non_blocking=True)
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
                if rowflow_start_event is not None and rowflow_end_event is not None:
                    rowflow_infer_seconds += (
                        rowflow_start_event.elapsed_time(rowflow_end_event) / 1000.0
                    )
                encoder_process.stdin.write(output_staging_view)
                if right_seed_process is not None and right_seed_process.stdin is not None:
                    right_seed_process.stdin.write(right_seed_staging_view)
                if right_mask_process is not None and right_mask_process.stdin is not None:
                    right_mask_process.stdin.write(right_mask_staging_view)
                if (
                    right_compose_mask_process is not None
                    and right_compose_mask_process.stdin is not None
                ):
                    right_compose_mask_process.stdin.write(right_compose_mask_staging_view)
                if (
                    left_compose_mask_process is not None
                    and left_compose_mask_process.stdin is not None
                ):
                    left_compose_mask_process.stdin.write(left_compose_mask_staging_view)
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
                                "canonical_depth_pipeline_passes": 1,
                                "depth_model_reinvocations": 0,
                                "rowflow_width": (
                                    min(eye_width, args.rowflow_width or eye_width)
                                    if args.stereo_method == "rowflow-v3" else None
                                ),
                                "rowflow_mean_steps": (
                                    rowflow_steps_sum / processed
                                    if args.stereo_method == "rowflow-v3" else None
                                ),
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
        if right_compose_mask_process is not None and right_compose_mask_process.stdin is not None:
            right_compose_mask_process.stdin.close()
        if left_compose_mask_process is not None and left_compose_mask_process.stdin is not None:
            left_compose_mask_process.stdin.close()

    decoder.wait(timeout=30)
    encoder_process.wait(timeout=120)
    if right_seed_process is not None:
        right_seed_process.wait(timeout=120)
    if right_mask_process is not None:
        right_mask_process.wait(timeout=120)
    if right_compose_mask_process is not None:
        right_compose_mask_process.wait(timeout=120)
    if left_compose_mask_process is not None:
        left_compose_mask_process.wait(timeout=120)
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
    if (
        right_compose_mask_process is not None
        and right_compose_mask_process.returncode != 0
    ):
        raise RuntimeError(
            "VR strict compose-mask encoder failed: "
            + right_compose_mask_process.stderr.read().decode("utf-8", errors="replace")
        )
    if (
        left_compose_mask_process is not None
        and left_compose_mask_process.returncode != 0
    ):
        raise RuntimeError(
            "VR left strict compose-mask encoder failed: "
            + left_compose_mask_process.stderr.read().decode("utf-8", errors="replace")
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
                "canonical_depth_pipeline_passes": 1,
                "depth_model_reinvocations": 0,
                "depth_source": "shared-dlss5-guide-cache",
                "rowflow_model_load_s": (
                    rowflow_load_seconds if args.stereo_method == "rowflow-v3" else None
                ),
                "rowflow_infer_s": (
                    rowflow_infer_seconds if args.stereo_method == "rowflow-v3" else None
                ),
                "rowflow_fps": (
                    processed / max(rowflow_infer_seconds, 1.0e-6)
                    if args.stereo_method == "rowflow-v3" else None
                ),
                "rowflow_width": (
                    min(eye_width, args.rowflow_width or eye_width)
                    if args.stereo_method == "rowflow-v3" else None
                ),
                "rowflow_mean_steps": (
                    rowflow_steps_sum / max(processed, 1)
                    if args.stereo_method == "rowflow-v3" else None
                ),
                "temporal": "motion" if use_motion else args.temporal_mode,
                "pixel_format": args.pixel_format, "output": str(args.output_video),
                "right_seed_output": str(args.right_seed_output) if args.right_seed_output else None,
                "right_mask_output": str(args.right_mask_output) if args.right_mask_output else None,
                "right_compose_mask_output": (
                    str(args.right_compose_mask_output)
                    if args.right_compose_mask_output else None
                ),
                "left_compose_mask_output": (
                    str(args.left_compose_mask_output)
                    if args.left_compose_mask_output else None
                ),
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
