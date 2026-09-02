"""Sparse temporal Moebius inpainting for a native-resolution VR second eye.

The worker deliberately never sends the complete 4K eye through the image
model.  It keeps the Temporal-LDI reprojection at source resolution, reuses
confident generated pixels from the preceding frame through the existing V3
motion vectors, and invokes Moebius only for residual disocclusion ROIs.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterator

import cv2
import numpy as np
from PIL import Image


MOTION_HEADER = struct.Struct("<8sIIIIIIII")
MOTION_MAGIC = b"D5MV0003"
MOTION_DTYPE = np.dtype(
    [("dx", "<f2"), ("dy", "<f2"), ("valid", "u1"), ("confidence", "u1")]
)


@dataclass(frozen=True)
class Roi:
    x: int
    y: int
    size: int

    @property
    def x2(self) -> int:
        return self.x + self.size

    @property
    def y2(self) -> int:
        return self.y + self.size


def emit(kind: str, **payload: object) -> None:
    print(
        f"VR_GENERATIVE_{kind} "
        + json.dumps(payload, ensure_ascii=True, separators=(",", ":")),
        flush=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--vae", required=True, type=Path)
    parser.add_argument("--site-packages", type=Path)
    parser.add_argument("--reprojected-video", type=Path)
    parser.add_argument("--mask-video", type=Path)
    parser.add_argument("--compose-mask-video", type=Path)
    parser.add_argument("--debug-directory", type=Path)
    parser.add_argument("--motion-directory", type=Path)
    parser.add_argument("--output-video", type=Path)
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--fps", type=float)
    parser.add_argument("--roi-side", type=int, default=0)
    parser.add_argument("--steps", type=int, default=0)
    parser.add_argument("--denoise-strength", type=float, default=0.99)
    parser.add_argument("--guidance-scale", type=float, default=2.5)
    parser.add_argument("--detail-strength", type=float, default=0.55)
    parser.add_argument("--structure-strength", type=float, default=0.65)
    parser.add_argument("--candidates", type=int, default=1)
    parser.add_argument("--reveal-side", choices=["left", "right"], default="right")
    parser.add_argument("--batch-size", type=int, default=0)
    parser.add_argument("--tile-overlap", type=int, default=0)
    parser.add_argument("--context", type=float, default=1.65)
    parser.add_argument("--min-mask-area", type=int, default=20)
    parser.add_argument("--max-patches", type=int, default=0)
    parser.add_argument("--temporal-confidence", type=float, default=0.42)
    parser.add_argument("--temporal-strength", type=float, default=0.92)
    parser.add_argument("--photometric-threshold", type=float, default=0.16)
    parser.add_argument("--refresh-interval", type=int, default=12)
    parser.add_argument("--hole-strength", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=26062026)
    return parser.parse_args()


def configure_import_path(args: argparse.Namespace) -> None:
    repository = args.repository.resolve()
    portable_root = repository.parent.parent
    cache_root = portable_root / "temp" / "model-cache"
    cache_root.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(cache_root / "huggingface"))
    os.environ.setdefault("XDG_CACHE_HOME", str(cache_root))
    os.environ.setdefault("TORCH_HOME", str(cache_root / "torch"))
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    if args.site_packages and args.site_packages.is_dir():
        sys.path.insert(0, str(args.site_packages.resolve()))
    sys.path.insert(0, str(repository))


def validate_install(args: argparse.Namespace, import_modules: bool = True) -> None:
    required = [
        args.ffmpeg,
        args.repository / "LICENSE",
        args.repository / "config" / "model_cfg" / "moebius.yaml",
        args.repository / "removal" / "v1_2" / "pipeline.py",
        args.repository / "model_lib" / "nets" / "unet_lambda_prune_lite.py",
        args.checkpoint,
        args.vae / "config.json",
        args.vae / "diffusion_pytorch_model.bin",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise FileNotFoundError(
            "Moebius is not fully installed; run INSTALL_VR_MODELS.cmd. Missing: "
            + "; ".join(missing)
        )
    if args.checkpoint.stat().st_size < 900_000_000:
        raise ValueError("Moebius checkpoint is incomplete")
    if (args.vae / "diffusion_pytorch_model.bin").stat().st_size < 160_000_000:
        raise ValueError("Moebius VAE checkpoint is incomplete")
    if import_modules:
        configure_import_path(args)
        try:
            import diffusers
            from packaging.version import Version

            if Version(diffusers.__version__) < Version("0.38.0"):
                raise RuntimeError(
                    f"isolated diffusers 0.38+ is required, found {diffusers.__version__}"
                )
            from removal.v1_2.pipeline import RemovalSDXLPipeline_BatchMode  # noqa: F401
        except Exception as exc:
            raise RuntimeError(
                "Moebius Python layer is incomplete. Run INSTALL_VR_MODELS.cmd again. "
                f"Import error: {type(exc).__name__}: {exc}"
            ) from exc


def auto_limits(
    vram_mb: int,
    width: int,
    height: int,
    requested_roi: int,
    requested_steps: int,
    requested_batch: int,
    requested_max_patches: int,
) -> tuple[int, int, int, int]:
    if requested_roi > 0:
        roi_side = max(256, min(1536, requested_roi))
    elif max(width, height) >= 3000:
        roi_side = 768
    elif max(width, height) >= 2000:
        roi_side = 640
    else:
        roi_side = 512
    roi_side = min(roi_side, width, height)
    roi_side = max(128, roi_side // 8 * 8)

    if requested_steps > 0:
        # Below eight DDIM steps the official checkpoint can leave coloured
        # latent noise in thin masks. Never emit that visibly broken draft.
        steps = max(8, min(30, requested_steps))
    else:
        steps = 20 if vram_mb >= 14_000 else 16
    if requested_batch > 0:
        batch_size = max(1, min(8, requested_batch))
    else:
        batch_size = 3 if vram_mb >= 20_000 else (2 if vram_mb >= 12_000 else 1)
    if requested_max_patches > 0:
        max_patches = max(1, min(96, requested_max_patches))
    else:
        max_patches = 36 if vram_mb >= 14_000 else 20
    return roi_side, steps, batch_size, max_patches


def _bounded_square(cx: float, cy: float, side: int, width: int, height: int) -> Roi:
    side = min(side, width, height)
    x = max(0, min(width - side, int(round(cx - side * 0.5))))
    y = max(0, min(height - side, int(round(cy - side * 0.5))))
    return Roi(x=x, y=y, size=side)


def _iou(first: Roi, second: Roi) -> float:
    left = max(first.x, second.x)
    top = max(first.y, second.y)
    right = min(first.x2, second.x2)
    bottom = min(first.y2, second.y2)
    intersection = max(0, right - left) * max(0, bottom - top)
    if intersection == 0:
        return 0.0
    return intersection / float(first.size * first.size + second.size * second.size - intersection)


def plan_rois(
    mask: np.ndarray,
    roi_side: int,
    overlap: int,
    context: float,
    min_area: int,
    max_patches: int,
) -> list[Roi]:
    """Cover connected holes with adaptive square ROIs, never the full frame."""
    height, width = mask.shape
    binary = (mask >= 96).astype(np.uint8)
    if not np.any(binary):
        return []
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    count, labels, stats, centroids = cv2.connectedComponentsWithStats(binary, 8)
    candidates: list[Roi] = []
    accepted_labels: list[int] = []
    maximum = max(128, min(roi_side, width, height))
    overlap = max(0, min(maximum - 64, overlap))
    stride = max(64, maximum - overlap)

    def axis_starts(low: int, high: int, side: int, limit: int) -> list[int]:
        if high - low <= side:
            return [max(0, min(limit - side, int(round((low + high - side) * 0.5))))]
        starts = list(range(low, max(low + 1, high - side + 1), stride))
        starts.append(max(0, min(limit - side, high - side)))
        return sorted(set(starts))

    for label in range(1, count):
        x, y, w, h, area = (int(value) for value in stats[label])
        if area < min_area:
            continue
        accepted_labels.append(label)
        requested = int(math.ceil(max(128.0, max(w, h) * max(1.05, context)) / 8.0) * 8)
        if requested <= maximum:
            roi = _bounded_square(centroids[label][0], centroids[label][1], requested, width, height)
            candidates.append(roi)
            continue

        margin = min(maximum // 3, max(24, int(0.5 * (max(1.0, context) - 1.0) * maximum)))
        left = max(0, x - margin)
        top = max(0, y - margin)
        right = min(width, x + w + margin)
        bottom = min(height, y + h + margin)
        x_starts = axis_starts(left, right, maximum, width)
        y_starts = axis_starts(top, bottom, maximum, height)
        for yy in y_starts:
            for xx in x_starts:
                local_area = int(binary[yy : yy + maximum, xx : xx + maximum].sum())
                if local_area >= min_area:
                    candidates.append(Roi(xx, yy, maximum))

    if not accepted_labels:
        return []
    # Do not let isolated one-pixel depth noise force additional 512x512
    # inference calls. It remains filled by Temporal LDI unless it lies inside
    # an ROI selected for a real connected disocclusion.
    binary = np.isin(labels, accepted_labels).astype(np.uint8)

    # Also offer maximum-size tiles to the set-cover pass. Disocclusion masks
    # are often split into many thin silhouette components; one model patch
    # can reconstruct every component it contains at the same inference cost.
    hole_y, hole_x = np.nonzero(binary)
    global_margin = max(24, overlap // 2)
    global_left = max(0, int(hole_x.min()) - global_margin)
    global_top = max(0, int(hole_y.min()) - global_margin)
    global_right = min(width, int(hole_x.max()) + 1 + global_margin)
    global_bottom = min(height, int(hole_y.max()) + 1 + global_margin)
    for yy in axis_starts(global_top, global_bottom, maximum, height):
        for xx in axis_starts(global_left, global_right, maximum, width):
            if int(binary[yy : yy + maximum, xx : xx + maximum].sum()) >= min_area:
                candidates.append(Roi(xx, yy, maximum))

    # Greedy set cover minimizes expensive model calls. Smaller component ROIs
    # win ties, retaining maximum source detail for isolated holes; a larger
    # tile wins only when it actually covers several components at once.
    unique_candidates = list(dict.fromkeys(candidates))
    remaining = binary.astype(bool)
    # The last scattered 1.5% is normally sub-pixel depth noise. Leaving it to
    # the already-computed LDI fill avoids an entire 512x512 diffusion call.
    target_coverage = max(min_area, int(math.ceil(float(remaining.sum()) * 0.985)))
    covered_pixels = 0
    result: list[Roi] = []
    while unique_candidates and len(result) < max_patches:
        best_index = -1
        best_coverage = 0
        for index, roi in enumerate(unique_candidates):
            coverage = int(remaining[roi.y : roi.y2, roi.x : roi.x2].sum())
            if coverage > best_coverage:
                best_index = index
                best_coverage = coverage
        if best_index < 0 or best_coverage < min_area:
            break
        roi = unique_candidates.pop(best_index)
        result.append(roi)
        covered_pixels += best_coverage
        remaining[roi.y : roi.y2, roi.x : roi.x2] = False
        if covered_pixels >= target_coverage:
            break
    return result


def suppress_peripheral_slivers(mask: np.ndarray, margin_percent: float = 2.5) -> np.ndarray:
    """Leave narrow frame-edge exposure to the geometric fallback.

    A square 512px diffusion tile is a poor trade for a 5-20px strip at the
    extreme headset periphery. Removing only that strip saves up to four ROIs
    while retaining every interior disocclusion and subject boundary.
    """
    _, width = mask.shape
    margin = max(0, min(width // 8, int(round(width * margin_percent / 100.0))))
    if margin <= 0:
        return mask
    cleaned = mask.copy()
    cleaned[:, :margin] = 0
    cleaned[:, width - margin :] = 0
    return cleaned


def expand_model_conditioning_mask(
    mask: np.ndarray,
    compose_mask: np.ndarray,
    reveal_side: str,
    foreground_span: int,
    vertical_span: int = 8,
) -> np.ndarray:
    """Expose the occluding object to Moebius without widening final compose.

    Moebius is an object-removal model. A slit-only mask asks it to repaint an
    arbitrary edge fragment and produces coloured bands. Stereo geometry tells
    us that the occluder lies opposite the newly revealed background, so grow
    the conditioning mask only in that direction. The separate compose mask is
    deliberately unchanged and therefore still protects every native pixel.
    """
    binary = np.maximum(mask, compose_mask) >= 96
    if not np.any(binary) or foreground_span <= 0:
        return binary.astype(np.uint8) * 255
    horizontal = max(1, int(foreground_span))
    vertical = max(0, int(vertical_span))
    kernel = np.ones((vertical * 2 + 1, horizontal + 1), np.uint8)
    # For a right-side reveal, the foreground occluder is left of the hole.
    # OpenCV's anchor at x=0 samples pixels to the right and grows the mask left.
    anchor_x = 0 if reveal_side == "right" else horizontal
    expanded = cv2.dilate(
        binary.astype(np.uint8),
        kernel,
        anchor=(anchor_x, vertical),
        iterations=1,
    )
    return expanded.astype(np.uint8) * 255


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


def read_exact(stream: BinaryIO, size: int) -> bytes:
    target = bytearray(size)
    view = memoryview(target)
    offset = 0
    while offset < size:
        received = stream.readinto(view[offset:])
        if not received:
            break
        offset += received
    if offset != size:
        raise EOFError(f"decoder ended after {offset} of {size} bytes")
    return bytes(target)


def start_decoder(
    ffmpeg: Path, path: Path, width: int, height: int, frames: int, pix_fmt: str
) -> subprocess.Popen:
    command = [
        str(ffmpeg), "-nostdin", "-v", "error", "-i", str(path),
        "-vf", f"scale={width}:{height}:flags=neighbor" if pix_fmt == "gray" else f"scale={width}:{height}:flags=lanczos",
        "-frames:v", str(frames), "-an", "-f", "rawvideo", "-pix_fmt", pix_fmt, "pipe:1",
    ]
    return subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )


def _motion_patch(
    motion: np.ndarray,
    roi: Roi,
    source_width: int,
    source_height: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    gh, gw = motion.shape
    confidence = motion["confidence"].astype(np.float32) * (1.0 / 255.0)
    confidence *= motion["valid"].astype(np.float32)
    denominator = np.maximum(confidence, 1.0 / 255.0)
    dx = motion["dx"].astype(np.float32) / denominator
    dy = motion["dy"].astype(np.float32) / denominator
    xs = np.linspace(roi.x, roi.x2 - 1, roi.size, dtype=np.float32)
    ys = np.linspace(roi.y, roi.y2 - 1, roi.size, dtype=np.float32)
    gx = np.broadcast_to(xs[None, :] * ((gw - 1) / max(1, source_width - 1)), (roi.size, roi.size))
    gy = np.broadcast_to(ys[:, None] * ((gh - 1) / max(1, source_height - 1)), (roi.size, roi.size))
    sampled_dx = cv2.remap(dx, gx, gy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    sampled_dy = cv2.remap(dy, gx, gy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    sampled_confidence = cv2.remap(
        confidence, gx, gy, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT
    )
    return sampled_dx, sampled_dy, sampled_confidence


def temporal_reuse_patch(
    seed_patch: np.ndarray,
    hole_mask: np.ndarray,
    previous_frame: np.ndarray | None,
    previous_valid: np.ndarray | None,
    motion: np.ndarray | None,
    roi: Roi,
    source_width: int,
    source_height: int,
    confidence_threshold: float,
    strength: float,
    photometric_threshold: float,
    force_refresh: bool,
) -> tuple[np.ndarray, np.ndarray, int, float, float]:
    residual = (hole_mask >= 96).astype(np.uint8) * 255
    if previous_frame is None or previous_valid is None or motion is None:
        return seed_patch.copy(), residual, 0, 0.0, 1.0

    dx, dy, confidence = _motion_patch(motion, roi, source_width, source_height)
    xx = np.broadcast_to(
        np.arange(roi.x, roi.x2, dtype=np.float32)[None, :], (roi.size, roi.size)
    )
    yy = np.broadcast_to(
        np.arange(roi.y, roi.y2, dtype=np.float32)[:, None], (roi.size, roi.size)
    )
    map_x = xx + dx
    map_y = yy + dy
    warped = cv2.remap(
        previous_frame, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE
    )
    warped_valid = cv2.remap(
        previous_valid, map_x, map_y, cv2.INTER_NEAREST, borderMode=cv2.BORDER_CONSTANT
    )
    holes = hole_mask >= 96
    ring = cv2.dilate(holes.astype(np.uint8), np.ones((9, 9), np.uint8)).astype(bool) & ~holes
    reliable_ring = ring & (confidence >= confidence_threshold)
    if np.any(reliable_ring):
        delta = np.abs(warped.astype(np.float32) - seed_patch.astype(np.float32)).mean(axis=2)
        photometric = float(delta[reliable_ring].mean() / 255.0)
    else:
        photometric = 1.0
    mean_confidence = float(confidence[holes].mean()) if np.any(holes) else 1.0
    reuse = (
        holes
        & (warped_valid >= 128)
        & (confidence >= confidence_threshold)
        & (photometric <= photometric_threshold)
    )
    output = seed_patch.astype(np.float32)
    amount = max(0.0, min(1.0, strength))
    output[reuse] = output[reuse] * (1.0 - amount) + warped[reuse].astype(np.float32) * amount
    if force_refresh:
        reuse[:] = False
    residual[reuse] = 0
    return output.clip(0, 255).astype(np.uint8), residual, int(reuse.sum()), mean_confidence, photometric


def feather(mask: np.ndarray, radius: float = 2.0) -> np.ndarray:
    work = (mask.astype(np.float32) / 255.0).clip(0.0, 1.0)
    if radius > 0:
        work = cv2.GaussianBlur(work, (0, 0), radius)
    return work.clip(0.0, 1.0)


def inward_feather(mask: np.ndarray, radius: float = 4.0) -> np.ndarray:
    """Blend only inside a disocclusion, never across a foreground silhouette."""
    binary = (mask >= 96).astype(np.uint8)
    if not np.any(binary):
        return binary.astype(np.float32)
    if radius <= 0.0:
        return binary.astype(np.float32)
    distance = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
    alpha = np.clip(distance / max(0.5, float(radius)), 0.0, 1.0)
    # Smoothstep suppresses the visible half-transparent line while the hard
    # zero outside the mask guarantees native foreground ownership.
    alpha = alpha * alpha * (3.0 - 2.0 * alpha)
    return alpha.astype(np.float32)


def directional_background_prior(
    image: np.ndarray,
    mask: np.ndarray,
    reveal_side: str = "right",
) -> np.ndarray:
    """Mirror visible background texture into a narrow stereo disocclusion.

    Generic inpainting samples both sides of a slit and can drag dark hair or
    clothing into the newly exposed background. Stereo geometry tells us the
    correct sampling side. Mirroring the first known background pixels keeps
    its real two-dimensional texture; the old per-row median produced flat,
    blocky scanlines that were very visible around a moving silhouette.
    """
    binary = mask >= 96
    if not np.any(binary):
        return image.copy()
    result = image.copy()
    height, width = binary.shape
    for y in range(height):
        xs = np.flatnonzero(binary[y])
        if xs.size == 0:
            continue
        breaks = np.flatnonzero(np.diff(xs) > 1)
        starts = np.r_[0, breaks + 1]
        ends = np.r_[breaks, xs.size - 1]
        for start_index, end_index in zip(starts, ends):
            left = int(xs[start_index])
            right = int(xs[end_index])
            run = right - left + 1
            if reveal_side == "right":
                destination = np.arange(left, right + 1, dtype=np.int32)
                source = right + 1 + (right - destination)
                source = np.clip(source, right + 1, width - 1)
            else:
                destination = np.arange(left, right + 1, dtype=np.int32)
                source = left - 1 - (destination - left)
                source = np.clip(source, 0, left - 1)

            # If the reflected sample intersects another small hole, continue
            # searching away from the foreground until a known pixel is found.
            direction = 1 if reveal_side == "right" else -1
            for index in range(run):
                source_x = int(source[index])
                while 0 <= source_x < width and binary[y, source_x]:
                    source_x += direction
                if 0 <= source_x < width:
                    result[y, int(destination[index])] = image[y, source_x]

    # Smooth only the synthesized pixels. The modest vertical support removes
    # one-row depth/mask noise without flattening the copied background texture.
    smoothed = cv2.GaussianBlur(result, (3, 3), 0.62)
    result[binary] = smoothed[binary]
    return result


def fuse_generated_background(
    generated: np.ndarray,
    base: np.ndarray,
    compose_mask: np.ndarray,
    reveal_side: str,
    detail_strength: float,
    structure_strength: float,
) -> np.ndarray:
    """Keep model micro-detail while grounding colour/shape in visible scene."""
    binary = compose_mask >= 96
    if not np.any(binary):
        return generated
    prior = directional_background_prior(base, compose_mask, reveal_side)
    low = cv2.GaussianBlur(generated, (0, 0), 3.2)
    detail = np.clip(
        generated.astype(np.float32) - low.astype(np.float32), -24.0, 24.0
    )
    amount = max(0.0, min(1.0, detail_strength))
    fused = np.clip(prior.astype(np.float32) + detail * amount, 0, 255).astype(np.uint8)
    # The generator contributes detail, while the visible stereo background
    # owns low-frequency colour and structure. Keeping this anchor at full
    # strength prevents stochastic green/magenta bands and frame-to-frame
    # hallucinations at the silhouette.
    prior_amount = max(0.0, min(1.0, structure_strength))
    fused = np.clip(
        generated.astype(np.float32) * (1.0 - prior_amount)
        + fused.astype(np.float32) * prior_amount,
        0,
        255,
    ).astype(np.uint8)
    output = generated.copy()
    output[binary] = fused[binary]
    return output


def score_generated_candidate(
    generated: np.ndarray,
    base: np.ndarray,
    compose_mask: np.ndarray,
    reveal_side: str,
) -> float:
    """Rank stochastic fills by low-frequency agreement with visible background."""
    binary = compose_mask >= 96
    if not np.any(binary):
        return 0.0
    prior = directional_background_prior(base, compose_mask, reveal_side)
    generated_low = cv2.GaussianBlur(generated, (0, 0), 4.0).astype(np.float32)
    prior_low = cv2.GaussianBlur(prior, (0, 0), 4.0).astype(np.float32)
    low_frequency_error = float(
        np.abs(generated_low[binary] - prior_low[binary]).mean() / 255.0
    )
    laplacian = cv2.Laplacian(generated, cv2.CV_32F)
    texture_penalty = float(np.percentile(np.abs(laplacian[binary]), 95) / 255.0)
    return low_frequency_error + 0.08 * texture_penalty


def directional_compose_alpha(
    mask: np.ndarray,
    reveal_side: str,
    feather_pixels: float = 4.0,
) -> np.ndarray:
    """Keep a sharp foreground edge and feather only into known background."""
    binary = mask >= 96
    alpha = np.zeros(binary.shape, np.float32)
    radius = max(1.0, float(feather_pixels))
    for y in range(binary.shape[0]):
        xs = np.flatnonzero(binary[y])
        if xs.size == 0:
            continue
        breaks = np.flatnonzero(np.diff(xs) > 1)
        starts = np.r_[0, breaks + 1]
        ends = np.r_[breaks, xs.size - 1]
        for start_index, end_index in zip(starts, ends):
            left = int(xs[start_index])
            right = int(xs[end_index])
            if reveal_side == "right":
                distance = right - np.arange(left, right + 1, dtype=np.float32) + 1.0
            else:
                distance = np.arange(left, right + 1, dtype=np.float32) - left + 1.0
            work = np.clip(distance / radius, 0.0, 1.0)
            alpha[y, left : right + 1] = work * work * (3.0 - 2.0 * work)
    return alpha


class MoebiusRuntime:
    def __init__(self, args: argparse.Namespace):
        configure_import_path(args)
        import torch
        from diffusers import DDIMScheduler
        from diffusers.models import AutoencoderKL
        from removal.v1_2.pipeline import RemovalSDXLPipeline_BatchMode
        from removal.v1_2.removal_model import build_removal_model, load_removal_model

        if not torch.cuda.is_available():
            raise RuntimeError("Moebius requires an NVIDIA CUDA GPU")
        self.torch = torch
        torch.set_grad_enabled(False)
        torch.backends.cudnn.benchmark = True
        torch.backends.cudnn.allow_tf32 = True
        torch.backends.cuda.matmul.allow_tf32 = True
        try:
            torch.set_float32_matmul_precision("high")
        except Exception:
            pass
        model_config = args.repository / "config" / "model_cfg" / "moebius.yaml"
        model = build_removal_model(str(model_config), 20)
        load_removal_model(model, str(args.checkpoint), "cpu", torch.float32)
        model.requires_grad_(False).to(device="cuda", dtype=torch.float16).eval()
        try:
            model.to(memory_format=torch.channels_last)
        except Exception:
            pass
        vae = AutoencoderKL.from_pretrained(
            str(args.vae), local_files_only=True, use_safetensors=False
        )
        vae.requires_grad_(False).to(device="cuda", dtype=torch.float16).eval()
        try:
            vae.to(memory_format=torch.channels_last)
        except Exception:
            pass
        scheduler = DDIMScheduler(
            beta_start=0.00085,
            beta_end=0.012,
            beta_schedule="scaled_linear",
            num_train_timesteps=1000,
            clip_sample=False,
        )
        self.pipe = RemovalSDXLPipeline_BatchMode(
            removal_model=model,
            vae=vae,
            scheduler=scheduler,
            device="cuda",
            dtype=torch.float16,
        )
        self.vram_mb = int(torch.cuda.get_device_properties(0).total_memory // (1024 * 1024))
        self.gpu_name = torch.cuda.get_device_name(0)

    def infer(
        self,
        images: list[Image.Image],
        masks: list[Image.Image],
        steps: int,
        seed: int,
        denoise_strength: float,
        guidance_scale: float,
    ) -> list[Image.Image]:
        torch = self.torch
        with torch.inference_mode(), torch.autocast(device_type="cuda", dtype=torch.float16):
            return self.pipe(
                images,
                masks,
                image_size=512,
                mask_dilate_kernel_size=3,
                strength=max(0.35, min(0.99, denoise_strength)),
                num_steps=steps,
                guidance_scale=max(1.0, min(8.0, guidance_scale)),
                retry=max(1, seed),
                paste=False,
                compensate=False,
                noise_offset=0.0357,
                mute=True,
            )


def close_process(process: subprocess.Popen, label: str, timeout: int = 180) -> None:
    if process.stdout is not None:
        process.stdout.close()
    process.wait(timeout=timeout)
    if process.returncode != 0:
        error = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
        raise RuntimeError(f"{label} failed: {error.strip()}")


def main() -> int:
    args = parse_args()
    validate_install(args)
    if args.check:
        emit("STATUS", stage="installation-ready", backend="Moebius-Sparse-Temporal")
        return 0
    for name in ("reprojected_video", "mask_video", "output_video"):
        if getattr(args, name) is None:
            raise ValueError(f"--{name.replace('_', '-')} is required")
    if not args.width or not args.height or not args.frames or not args.fps:
        raise ValueError("--width, --height, --frames and --fps must be positive")
    if args.debug_directory is not None:
        args.debug_directory.mkdir(parents=True, exist_ok=True)

    runtime = MoebiusRuntime(args)
    roi_side, steps, batch_size, max_patches = auto_limits(
        runtime.vram_mb,
        args.width,
        args.height,
        args.roi_side,
        args.steps,
        args.batch_size,
        args.max_patches,
    )
    overlap = args.tile_overlap if args.tile_overlap > 0 else max(64, roi_side // 6)
    emit(
        "STATUS",
        stage="model-ready",
        backend="Moebius-Sparse-Temporal",
        gpu=runtime.gpu_name,
        vram_mb=runtime.vram_mb,
        model_canvas="512x512",
        roi_side=roi_side,
        steps=steps,
        batch_size=batch_size,
        temporal=True,
        denoise_strength=max(0.35, min(0.99, args.denoise_strength)),
        guidance_scale=max(1.0, min(8.0, args.guidance_scale)),
    )

    seed_decoder = start_decoder(
        args.ffmpeg, args.reprojected_video, args.width, args.height, args.frames, "rgb24"
    )
    mask_decoder = start_decoder(
        args.ffmpeg, args.mask_video, args.width, args.height, args.frames, "gray"
    )
    compose_mask_decoder = (
        start_decoder(
            args.ffmpeg,
            args.compose_mask_video,
            args.width,
            args.height,
            args.frames,
            "gray",
        )
        if args.compose_mask_video is not None
        else None
    )
    if (
        seed_decoder.stdout is None
        or mask_decoder.stdout is None
        or (compose_mask_decoder is not None and compose_mask_decoder.stdout is None)
    ):
        raise RuntimeError("could not start Moebius input decoders")
    encoder_command = [
        str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s:v", f"{args.width}x{args.height}",
        "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an", "-c:v", "ffv1",
        "-level", "3", "-coder", "1", "-context", "1", "-pix_fmt", "bgr0",
        "-frames:v", str(args.frames), str(args.output_video),
    ]
    encoder = subprocess.Popen(
        encoder_command,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if encoder.stdin is None:
        raise RuntimeError("could not start Moebius output encoder")

    motion_paths = (
        sorted(args.motion_directory.glob("chunk-*.motion"))
        if args.motion_directory and args.motion_directory.is_dir()
        else []
    )
    motion_iterator = iter(motion_frames(motion_paths)) if motion_paths else None
    rgb_extent = args.width * args.height * 3
    mask_extent = args.width * args.height
    previous_output: np.ndarray | None = None
    previous_valid: np.ndarray | None = None
    started = time.perf_counter()
    processed = 0
    total_rois = 0
    generated_rois = 0
    hole_pixels = 0
    generated_pixels = 0
    reused_pixels = 0
    photometric_sum = 0.0
    confidence_sum = 0.0
    temporal_samples = 0

    try:
        for frame_index in range(args.frames):
            seed = np.frombuffer(read_exact(seed_decoder.stdout, rgb_extent), np.uint8).reshape(
                args.height, args.width, 3
            )
            mask = np.frombuffer(read_exact(mask_decoder.stdout, mask_extent), np.uint8).reshape(
                args.height, args.width
            )
            mask = suppress_peripheral_slivers(mask)
            compose_mask = (
                np.frombuffer(
                    read_exact(compose_mask_decoder.stdout, mask_extent), np.uint8
                ).reshape(args.height, args.width)
                if compose_mask_decoder is not None
                else mask.copy()
            )
            compose_mask = suppress_peripheral_slivers(compose_mask)
            foreground_context = min(
                max(96, int(round(args.width * 0.15))),
                max(96, roi_side // 2),
            )
            mask = expand_model_conditioning_mask(
                mask,
                compose_mask,
                args.reveal_side,
                foreground_context,
            )
            motion = next(motion_iterator)[0] if motion_iterator is not None else None
            rois = plan_rois(
                mask,
                roi_side,
                overlap,
                args.context,
                max(1, args.min_mask_area),
                max_patches,
            )
            total_rois += len(rois)
            holes_this_frame = int((compose_mask >= 96).sum())
            hole_pixels += holes_this_frame
            if not rois:
                output = seed.copy()
                previous_valid = np.zeros_like(mask)
            else:
                colour_sum = np.zeros((args.height, args.width, 3), dtype=np.float32)
                weight_sum = np.zeros((args.height, args.width), dtype=np.float32)
                reused_coverage = np.zeros((args.height, args.width), dtype=bool)
                generated_coverage = np.zeros((args.height, args.width), dtype=bool)
                patch_records: list[dict[str, object]] = []
                force_refresh = args.refresh_interval > 0 and frame_index % args.refresh_interval == 0
                for roi in rois:
                    seed_patch = seed[roi.y : roi.y2, roi.x : roi.x2]
                    mask_patch = mask[roi.y : roi.y2, roi.x : roi.x2]
                    compose_patch = compose_mask[roi.y : roi.y2, roi.x : roi.x2]
                    base, residual, reused, mean_conf, photo = temporal_reuse_patch(
                        seed_patch,
                        compose_patch,
                        previous_output,
                        previous_valid,
                        motion,
                        roi,
                        args.width,
                        args.height,
                        max(0.0, min(1.0, args.temporal_confidence)),
                        max(0.0, min(1.0, args.temporal_strength)),
                        max(0.0, min(1.0, args.photometric_threshold)),
                        force_refresh,
                    )
                    reused_local = (compose_patch >= 96) & (residual < 96)
                    reused_coverage[roi.y : roi.y2, roi.x : roi.x2] |= reused_local
                    confidence_sum += mean_conf
                    photometric_sum += photo
                    temporal_samples += 1
                    patch_records.append(
                        {"roi": roi, "base": base, "mask": mask_patch, "residual": residual}
                    )

                pending = [record for record in patch_records if int(np.count_nonzero(record["residual"])) >= args.min_mask_area]
                for start in range(0, len(pending), batch_size):
                    batch = pending[start : start + batch_size]
                    input_images: list[Image.Image] = []
                    input_masks: list[Image.Image] = []
                    for record in batch:
                        base = record["base"]
                        residual = record["residual"]
                        model_mask = record["mask"]
                        input_images.append(
                            Image.fromarray(base, "RGB").resize((512, 512), Image.Resampling.LANCZOS)
                        )
                        input_masks.append(
                            Image.fromarray(model_mask, "L").resize((512, 512), Image.Resampling.NEAREST)
                        )
                    candidate_count = max(1, min(4, args.candidates))
                    candidate_sets = [
                        runtime.infer(
                            input_images,
                            input_masks,
                            steps,
                            args.seed + candidate_index * 104729,
                            args.denoise_strength,
                            args.guidance_scale,
                        )
                        for candidate_index in range(candidate_count)
                    ]
                    for record_index, record in enumerate(batch):
                        roi = record["roi"]
                        residual = record["residual"]
                        candidates = [
                            np.asarray(
                                candidate_set[record_index].convert("RGB").resize(
                                    (roi.size, roi.size), Image.Resampling.LANCZOS
                                ),
                                dtype=np.uint8,
                            )
                            for candidate_set in candidate_sets
                        ]
                        if args.debug_directory is not None and frame_index == 0:
                            Image.fromarray(record["base"], "RGB").save(
                                args.debug_directory / f"roi-{record_index:02d}-base.png"
                            )
                            Image.fromarray(record["mask"], "L").save(
                                args.debug_directory / f"roi-{record_index:02d}-model-mask.png"
                            )
                            Image.fromarray(residual, "L").save(
                                args.debug_directory / f"roi-{record_index:02d}-compose-mask.png"
                            )
                            for candidate_index, candidate in enumerate(candidates):
                                Image.fromarray(candidate, "RGB").save(
                                    args.debug_directory
                                    / f"roi-{record_index:02d}-candidate-{candidate_index:02d}.png"
                                )
                        result = min(
                            candidates,
                            key=lambda candidate: score_generated_candidate(
                                candidate,
                                record["base"],
                                residual,
                                args.reveal_side,
                            ),
                        )
                        result = fuse_generated_background(
                            result,
                            record["base"],
                            residual,
                            args.reveal_side,
                            args.detail_strength,
                            args.structure_strength,
                        )
                        # Fade inward from the real hole boundary. Gaussian
                        # feathering leaked generated colour onto the person
                        # and created a false outline/cut-out appearance.
                        # An occlusion boundary is physically sharp: generated
                        # background must reach the first uncovered pixel, but
                        # must never leak over the foreground owner.
                        alpha = directional_compose_alpha(
                            residual, args.reveal_side, 4.0
                        ) * max(0.0, min(1.0, args.hole_strength))
                        base = record["base"].astype(np.float32)
                        record["base"] = (
                            base * (1.0 - alpha[..., None]) + result.astype(np.float32) * alpha[..., None]
                        ).clip(0, 255).astype(np.uint8)
                        generated_coverage[roi.y : roi.y2, roi.x : roi.x2] |= residual >= 96
                        generated_rois += 1

                for record in patch_records:
                    roi = record["roi"]
                    alpha = feather(record["mask"], 3.0)
                    colour_sum[roi.y : roi.y2, roi.x : roi.x2] += (
                        record["base"].astype(np.float32) * alpha[..., None]
                    )
                    weight_sum[roi.y : roi.y2, roi.x : roi.x2] += alpha
                output = seed.astype(np.float32)
                covered = weight_sum > 1.0e-5
                output[covered] = colour_sum[covered] / weight_sum[covered, None]
                output = output.clip(0, 255).astype(np.uint8)
                previous_valid = (compose_mask >= 96).astype(np.uint8) * 255
                reused_pixels += int(reused_coverage.sum())
                # Count unique source-resolution pixels rather than summing
                # overlapping ROI masks; telemetry therefore never exceeds
                # 100 percent of the actual disocclusion area.
                generated_pixels += int(generated_coverage.sum())

            encoder.stdin.write(memoryview(np.ascontiguousarray(output)).cast("B"))
            previous_output = output
            processed += 1
            if processed == 1 or processed % 10 == 0 or processed == args.frames:
                elapsed = time.perf_counter() - started
                emit(
                    "PROGRESS",
                    backend="Moebius-Sparse-Temporal",
                    frames=processed,
                    total=args.frames,
                    fps=processed / max(elapsed, 1.0e-6),
                    model_canvas="512x512",
                    rois=total_rois,
                    generated_rois=generated_rois,
                    native_preserved_percent=100.0 * (1.0 - hole_pixels / max(1, processed * args.width * args.height)),
                    generated_hole_percent=100.0 * generated_pixels / max(1, hole_pixels),
                    reused_hole_percent=100.0 * reused_pixels / max(1, hole_pixels),
                )
    finally:
        encoder.stdin.close()

    close_process(seed_decoder, "right-eye seed decoder")
    close_process(mask_decoder, "disocclusion mask decoder")
    if compose_mask_decoder is not None:
        close_process(compose_mask_decoder, "strict compose mask decoder")
    encoder.wait(timeout=300)
    if encoder.returncode != 0:
        error = encoder.stderr.read().decode("utf-8", errors="replace") if encoder.stderr else ""
        raise RuntimeError("Moebius output encoder failed: " + error.strip())
    if processed != args.frames:
        raise RuntimeError(f"Moebius produced {processed} frames, expected {args.frames}")
    elapsed = time.perf_counter() - started
    emit(
        "DONE",
        backend="Moebius-Sparse-Temporal",
        frames=processed,
        elapsed_s=elapsed,
        fps=processed / max(elapsed, 1.0e-6),
        model_canvas="512x512",
        roi_side=roi_side,
        steps=steps,
        generated_rois=generated_rois,
        reused_hole_percent=100.0 * reused_pixels / max(1, hole_pixels),
        generated_hole_percent=100.0 * generated_pixels / max(1, hole_pixels),
        native_preserved_percent=100.0 * (1.0 - hole_pixels / max(1, processed * args.width * args.height)),
        mean_temporal_confidence=confidence_sum / max(1, temporal_samples),
        mean_photometric_error=photometric_sum / max(1, temporal_samples),
        output=str(args.output_video),
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        emit("ERROR", backend="Moebius-Sparse-Temporal", type=type(exc).__name__, message=str(exc))
        raise
