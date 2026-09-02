"""Repair stereo disocclusions from neighbouring frames before local AI inpainting.

The expensive decisions are made on a small guide grid.  Selected pixels are
then sampled from the original stereo frames at native resolution, which keeps
2K/4K texture without running a full-frame neural network at that resolution.
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import struct
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable, Iterator

import cv2
import numpy as np


DEPTH_HEADER = struct.Struct("<8sIIIII")
DEPTH_MAGIC = b"D5DP0002"


def emit(tag: str, **payload: object) -> None:
    print(tag + " " + json.dumps(payload, separators=(",", ":")), flush=True)


def read_exact(stream: BinaryIO, size: int) -> bytes:
    result = bytearray(size)
    view = memoryview(result)
    offset = 0
    while offset < size:
        received = stream.readinto(view[offset:])
        if not received:
            break
        offset += received
    return bytes(view[:offset])


def depth_frames(paths: list[Path]) -> Iterator[np.ndarray]:
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
                yield data.reshape(grid_height, grid_width).astype(np.float32)


def guide_geometry(width: int, height: int, max_side: int) -> tuple[int, int]:
    scale = min(1.0, max(128, max_side) / float(max(width, height)))
    guide_width = max(128, int(round(width * scale / 8.0)) * 8)
    guide_height = max(128, int(round(height * scale / 8.0)) * 8)
    return guide_width, guide_height


def layout_geometry(width: int, height: int, layout: str) -> tuple[int, int, int, int]:
    if layout == "full-sbs":
        return width, height, width * 2, height
    if layout == "half-sbs":
        return width // 2, height, width, height
    if layout == "full-ou":
        return width, height, width, height * 2
    if layout == "half-ou":
        return width, height // 2, width, height
    raise ValueError(f"unsupported layout: {layout}")


def split_eyes(stereo: np.ndarray, layout: str) -> tuple[np.ndarray, np.ndarray]:
    if layout in {"full-sbs", "half-sbs"}:
        midpoint = stereo.shape[1] // 2
        return stereo[:, :midpoint], stereo[:, midpoint:]
    midpoint = stereo.shape[0] // 2
    return stereo[:midpoint], stereo[midpoint:]


def pack_eyes(left: np.ndarray, right: np.ndarray, layout: str) -> np.ndarray:
    if layout in {"full-sbs", "half-sbs"}:
        return np.concatenate((left, right), axis=1)
    return np.concatenate((left, right), axis=0)


def remap(image: np.ndarray, flow: np.ndarray, interpolation: int = cv2.INTER_LINEAR) -> np.ndarray:
    height, width = flow.shape[:2]
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    return cv2.remap(
        image,
        xx + flow[..., 0],
        yy + flow[..., 1],
        interpolation,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )


def flow_reliability(
    first: np.ndarray,
    second: np.ndarray,
    first_to_second: np.ndarray,
    second_to_first: np.ndarray,
) -> np.ndarray:
    """Forward/backward cycle and photometric confidence on the guide grid."""
    height, width = first_to_second.shape[:2]
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    target_x = xx + first_to_second[..., 0]
    target_y = yy + first_to_second[..., 1]
    inside = (
        (target_x >= 0.0)
        & (target_x <= width - 1.0)
        & (target_y >= 0.0)
        & (target_y <= height - 1.0)
    )
    reverse = cv2.remap(
        second_to_first,
        target_x,
        target_y,
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    cycle = np.linalg.norm(first_to_second + reverse, axis=2)
    magnitude = np.linalg.norm(first_to_second, axis=2)
    cycle_scale = 0.65 + 0.035 * magnitude
    cycle_score = np.exp(-cycle / np.maximum(cycle_scale, 1.0e-3))
    warped = cv2.remap(
        second,
        target_x,
        target_y,
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    photo = np.mean(np.abs(first.astype(np.float32) - warped.astype(np.float32)), axis=2)
    photo_score = np.exp(-photo / 28.0)
    confidence = cycle_score * photo_score
    confidence[~inside] = 0.0
    return confidence.astype(np.float32)


class FlowEstimator:
    provider = "unknown"

    def estimate_pair(
        self, first: np.ndarray, second: np.ndarray
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        raise NotImplementedError


class DisFlowEstimator(FlowEstimator):
    provider = "opencv-dis-medium"

    def __init__(self) -> None:
        self.model = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
        self.model.setUseSpatialPropagation(True)

    def _one(self, first: np.ndarray, second: np.ndarray) -> np.ndarray:
        first_gray = cv2.cvtColor(first, cv2.COLOR_RGB2GRAY)
        second_gray = cv2.cvtColor(second, cv2.COLOR_RGB2GRAY)
        return self.model.calc(first_gray, second_gray, None).astype(np.float32)

    def estimate_pair(
        self, first: np.ndarray, second: np.ndarray
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        forward = self._one(first, second)
        backward = self._one(second, first)
        return (
            forward,
            backward,
            flow_reliability(first, second, forward, backward),
            flow_reliability(second, first, backward, forward),
        )


class RaftFlowEstimator(FlowEstimator):
    provider = "torchvision-raft-small-cuda-bidirectional"

    def __init__(self, weights: Path, updates: int) -> None:
        import torch
        from torchvision.models.optical_flow import raft_small

        if not torch.cuda.is_available():
            raise RuntimeError("RAFT Temporal Atlas requires an NVIDIA CUDA GPU")
        state = torch.load(weights, map_location="cpu", weights_only=True)
        self.torch = torch
        self.model = raft_small(weights=None, progress=False).eval().cuda()
        self.model.load_state_dict(state)
        self.updates = max(2, min(12, updates))
        torch.backends.cudnn.benchmark = False
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.set_float32_matmul_precision("high")

    def estimate_pair(
        self, first: np.ndarray, second: np.ndarray
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        torch = self.torch
        images_a = np.stack((first, second)).astype(np.float32, copy=False)
        images_b = np.stack((second, first)).astype(np.float32, copy=False)
        tensor_a = torch.from_numpy(images_a).permute(0, 3, 1, 2).cuda(non_blocking=True)
        tensor_b = torch.from_numpy(images_b).permute(0, 3, 1, 2).cuda(non_blocking=True)
        tensor_a = tensor_a.div_(127.5).sub_(1.0)
        tensor_b = tensor_b.div_(127.5).sub_(1.0)
        with torch.inference_mode(), torch.autocast("cuda", dtype=torch.float16):
            predicted = self.model(tensor_a, tensor_b, num_flow_updates=self.updates)[-1]
        flows = predicted.permute(0, 2, 3, 1).float().cpu().numpy()
        forward, backward = flows[0], flows[1]
        return (
            forward,
            backward,
            flow_reliability(first, second, forward, backward),
            flow_reliability(second, first, backward, forward),
        )


@dataclass
class AtlasFrame:
    index: int
    scene: int
    source: np.ndarray
    stereo: np.ndarray
    left_mask: np.ndarray
    right_mask: np.ndarray
    depth: np.ndarray
    flow_prev: np.ndarray | None = None
    confidence_prev: np.ndarray | None = None
    flow_next: np.ndarray | None = None
    confidence_next: np.ndarray | None = None


def resize_flow(flow: np.ndarray, width: int, height: int) -> np.ndarray:
    source_height, source_width = flow.shape[:2]
    result = cv2.resize(flow, (width, height), interpolation=cv2.INTER_LINEAR)
    result[..., 0] *= width / float(source_width)
    result[..., 1] *= height / float(source_height)
    return result


def compose_flow(
    frames: dict[int, AtlasFrame], start: int, end: int
) -> tuple[np.ndarray, np.ndarray]:
    """Compose adjacent flows while carrying their cycle-consistency confidence."""
    first = frames[start]
    height, width = first.source.shape[:2]
    total = np.zeros((height, width, 2), dtype=np.float32)
    confidence = np.ones((height, width), dtype=np.float32)
    direction = 1 if end > start else -1
    current = start
    while current != end:
        packet = frames[current]
        edge = packet.flow_next if direction > 0 else packet.flow_prev
        edge_confidence = (
            packet.confidence_next if direction > 0 else packet.confidence_prev
        )
        if edge is None or edge_confidence is None:
            confidence.fill(0.0)
            break
        sampled_edge = remap(edge, total)
        sampled_confidence = remap(edge_confidence, total)
        confidence = np.minimum(confidence, sampled_confidence)
        total += sampled_edge
        current += direction
    return total, confidence


def directional_background(values: np.ndarray, holes: np.ndarray, prefer_right: bool) -> np.ndarray:
    """Extend only the reveal-side background into a guide-resolution hole."""
    height, width = holes.shape
    columns = np.broadcast_to(np.arange(width, dtype=np.int32), (height, width))
    valid = ~holes
    left = np.maximum.accumulate(np.where(valid, columns, -1), axis=1)
    right = np.minimum.accumulate(
        np.where(valid, columns, width)[:, ::-1], axis=1
    )[:, ::-1]
    selected = np.where(right < width, right, left) if prefer_right else np.where(left >= 0, left, right)
    selected = np.clip(selected, 0, width - 1)
    return np.take_along_axis(values, selected, axis=1)


def candidate_offsets(radius: int) -> list[int]:
    radius = max(1, radius)
    distances: list[int] = []
    step = 1
    while step <= radius:
        distances.append(step)
        step *= 2
    if distances[-1] != radius:
        distances.append(radius)
    result: list[int] = []
    for distance in distances:
        result.extend((-distance, distance))
    return result


def atlas_choice(
    frames: dict[int, AtlasFrame],
    target_index: int,
    candidates: Iterable[int],
    eye: str,
    minimum_confidence: float,
    photometric_threshold: float,
    depth_tolerance: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, dict[int, tuple[np.ndarray, np.ndarray]]]:
    """Select trustworthy source-frame pixels on the guide grid."""
    target = frames[target_index]
    target_eye = getattr(target, f"_{eye}_eye")
    target_mask_native = target.left_mask if eye == "left" else target.right_mask
    height, width = target.source.shape[:2]
    target_small = cv2.resize(target_eye, (width, height), interpolation=cv2.INTER_AREA)
    target_mask = cv2.resize(
        target_mask_native.astype(np.uint8), (width, height), interpolation=cv2.INTER_AREA
    ) > 0
    best_score = np.zeros((height, width), dtype=np.float32)
    best_index = np.full((height, width), -1, dtype=np.int32)
    best_flow = np.zeros((height, width, 2), dtype=np.float32)
    composed: dict[int, tuple[np.ndarray, np.ndarray]] = {}
    prefer_right = eye == "right"
    background_depth = directional_background(target.depth, target_mask, prefer_right)
    ring_kernel = np.ones((5, 5), dtype=np.uint8)
    ring = cv2.dilate(target_mask.astype(np.uint8), ring_kernel, iterations=1).astype(bool)
    ring &= ~target_mask

    for candidate_index in candidates:
        candidate = frames.get(candidate_index)
        if candidate is None or candidate.scene != target.scene:
            continue
        flow, confidence = compose_flow(frames, target_index, candidate_index)
        composed[candidate_index] = (flow, confidence)
        candidate_eye = getattr(candidate, f"_{eye}_eye")
        candidate_small = cv2.resize(candidate_eye, (width, height), interpolation=cv2.INTER_AREA)
        candidate_mask_native = candidate.left_mask if eye == "left" else candidate.right_mask
        candidate_valid = cv2.resize(
            (~candidate_mask_native).astype(np.uint8),
            (width, height),
            interpolation=cv2.INTER_AREA,
        )
        warped_valid = remap(candidate_valid, flow) > 0.92
        warped_colour = remap(candidate_small, flow)
        colour_error = np.mean(
            np.abs(target_small.astype(np.float32) - warped_colour.astype(np.float32)), axis=2
        ) / 255.0
        ring_valid = ring & warped_valid & (confidence >= minimum_confidence)
        if np.count_nonzero(ring_valid) >= 12:
            photometric = float(np.median(colour_error[ring_valid]))
        else:
            photometric = 1.0
        if photometric > photometric_threshold:
            continue
        warped_depth = remap(candidate.depth, flow)
        depth_ok = (
            (warped_depth <= background_depth + depth_tolerance)
            & (np.abs(warped_depth - background_depth) <= max(0.25, depth_tolerance * 2.5))
        )
        distance = abs(candidate_index - target_index)
        score = confidence * math.exp(-2.5 * photometric) * math.pow(0.985, distance)
        eligible = (
            target_mask
            & warped_valid
            & depth_ok
            & (confidence >= minimum_confidence)
            & (score > best_score)
        )
        best_score[eligible] = score[eligible]
        best_index[eligible] = candidate_index
        best_flow[eligible] = flow[eligible]
    return best_index, best_flow, target_mask, composed


def clustered_hole_boxes(
    holes: np.ndarray, max_regions: int, merge_gap: int
) -> list[tuple[int, int, int, int]]:
    """Group residual holes into a bounded number of nearby neural ROIs.

    DirectML launch overhead dominates when every tiny disocclusion component is
    sent through MI-GAN separately.  The grouping itself runs on a <=1024 px
    mask, while returned boxes are expressed in native coordinates.
    """
    if not np.any(holes) or max_regions <= 0:
        return []
    native_height, native_width = holes.shape
    scale = min(1.0, 1024.0 / max(native_width, native_height))
    small_width = max(1, int(round(native_width * scale)))
    small_height = max(1, int(round(native_height * scale)))
    small = cv2.resize(
        holes.astype(np.uint8), (small_width, small_height), interpolation=cv2.INTER_AREA
    ) > 0
    gap = max(1, int(round(merge_gap * scale)))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (gap * 2 + 1, gap * 2 + 1))
    grouped = cv2.dilate(small.astype(np.uint8), kernel, iterations=1)
    count, _, stats, _ = cv2.connectedComponentsWithStats(grouped, connectivity=8)
    boxes: list[tuple[int, int, int, int]] = []
    inverse = 1.0 / scale
    for label in range(1, count):
        x, y, width, height, area = (int(value) for value in stats[label])
        if area <= 0:
            continue
        x0 = max(0, int(math.floor(x * inverse)))
        y0 = max(0, int(math.floor(y * inverse)))
        x1 = min(native_width, int(math.ceil((x + width) * inverse)))
        y1 = min(native_height, int(math.ceil((y + height) * inverse)))
        boxes.append((x0, y0, x1, y1))

    def distance(first: tuple[int, int, int, int], second: tuple[int, int, int, int]) -> float:
        ax = 0.5 * (first[0] + first[2])
        ay = 0.5 * (first[1] + first[3])
        bx = 0.5 * (second[0] + second[2])
        by = 0.5 * (second[1] + second[3])
        return ((ax - bx) / max(1, native_width)) ** 2 + ((ay - by) / max(1, native_height)) ** 2

    # Deterministically merge the nearest groups until the requested launch
    # budget is met. This is preferable to one enormous full-frame crop at 4K.
    while len(boxes) > max_regions:
        pair = min(
            ((distance(boxes[a], boxes[b]), a, b) for a in range(len(boxes)) for b in range(a + 1, len(boxes))),
            key=lambda item: item[0],
        )
        _, a, b = pair
        first, second = boxes[a], boxes[b]
        boxes[a] = (
            min(first[0], second[0]), min(first[1], second[1]),
            max(first[2], second[2]), max(first[3], second[3]),
        )
        boxes.pop(b)
    return sorted(boxes, key=lambda box: (box[0], box[1]))


class MiganInpainter:
    provider = "disabled"

    def __init__(self, model: Path | None, provider: str, max_regions: int = 2) -> None:
        self.session = None
        self.max_regions = max(1, min(4, max_regions))
        self.last_calls = 0
        if model is None:
            return
        import onnxruntime as ort

        available = ort.get_available_providers()
        if provider == "dml" and "DmlExecutionProvider" in available:
            providers = ["DmlExecutionProvider", "CPUExecutionProvider"]
        else:
            providers = ["CPUExecutionProvider"]
        options = ort.SessionOptions()
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        self.session = ort.InferenceSession(str(model), sess_options=options, providers=providers)
        self.provider = self.session.get_providers()[0]

    def apply(self, image: np.ndarray, holes: np.ndarray) -> tuple[np.ndarray, int]:
        if self.session is None or not np.any(holes):
            self.last_calls = 0
            return image, 0
        result = image.copy()
        merge_gap = max(24, min(96, int(round(max(image.shape[:2]) / 48.0))))
        boxes = clustered_hole_boxes(holes, self.max_regions, merge_gap)
        remaining = holes.copy()
        generated_pixels = 0
        self.last_calls = 0
        for x, y, x2, y2 in boxes:
            local_group = remaining[y:y2, x:x2]
            area = int(np.count_nonzero(local_group))
            if area <= 0:
                continue
            width, height = x2 - x, y2 - y
            padding = max(24, min(96, int(round(0.12 * max(width, height)))))
            x0 = max(0, x - padding)
            y0 = max(0, y - padding)
            x1 = min(image.shape[1], x2 + padding)
            y1 = min(image.shape[0], y2 + padding)
            local_holes = remaining[y0:y1, x0:x1]
            local_image = result[y0:y1, x0:x1].copy()
            # White denotes known content and black denotes the hole.
            known = np.where(local_holes, 0, 255).astype(np.uint8)[None, None]
            rgb = local_image.transpose(2, 0, 1)[None].astype(np.uint8, copy=False)
            output = self.session.run(None, {"image": rgb, "mask": known})[0][0]
            generated = output.transpose(1, 2, 0)
            local_image[local_holes] = generated[local_holes]
            result[y0:y1, x0:x1][local_holes] = local_image[local_holes]
            generated_pixels += int(np.count_nonzero(local_holes))
            remaining[y0:y1, x0:x1][local_holes] = False
            self.last_calls += 1
        return result, generated_pixels


def native_remap_roi(
    candidate: np.ndarray,
    candidate_holes: np.ndarray,
    flow_guide: np.ndarray,
    selection: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, tuple[int, int, int, int] | None]:
    points = cv2.findNonZero(selection.astype(np.uint8))
    if points is None:
        return np.empty((0, 0, 3), np.uint8), np.empty((0, 0), bool), None
    x, y, width, height = cv2.boundingRect(points)
    native_height, native_width = selection.shape
    flow = resize_flow(flow_guide, native_width, native_height)[y : y + height, x : x + width]
    yy, xx = np.mgrid[y : y + height, x : x + width].astype(np.float32)
    map_x = xx + flow[..., 0]
    map_y = yy + flow[..., 1]
    warped = cv2.remap(
        candidate,
        map_x,
        map_y,
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    )
    warped_known = cv2.remap(
        (~candidate_holes).astype(np.uint8),
        map_x,
        map_y,
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0,
    ) > 0.96
    inside = (
        (map_x >= 0.0)
        & (map_x <= native_width - 1.0)
        & (map_y >= 0.0)
        & (map_y <= native_height - 1.0)
    )
    return warped, inside & warped_known, (x, y, width, height)


def repair_eye(
    frames: dict[int, AtlasFrame],
    target_index: int,
    candidate_indices: list[int],
    eye: str,
    minimum_confidence: float,
    photometric_threshold: float,
    depth_tolerance: float,
    inpainter: MiganInpainter,
) -> tuple[np.ndarray, np.ndarray, float, int]:
    target = frames[target_index]
    target_eye: np.ndarray = getattr(target, f"_{eye}_eye")
    target_mask = target.left_mask if eye == "left" else target.right_mask
    choice, _, _, composed = atlas_choice(
        frames,
        target_index,
        candidate_indices,
        eye,
        minimum_confidence,
        photometric_threshold,
        depth_tolerance,
    )
    choice_native = cv2.resize(
        choice.astype(np.float32),
        (target_eye.shape[1], target_eye.shape[0]),
        interpolation=cv2.INTER_NEAREST,
    ).astype(np.int32)
    result = target_eye.copy()
    filled = np.zeros_like(target_mask, dtype=bool)
    for candidate_index in np.unique(choice_native):
        if candidate_index < 0:
            continue
        selection = target_mask & (choice_native == candidate_index)
        candidate_packet = frames[int(candidate_index)]
        candidate_flow = composed[int(candidate_index)][0]
        candidate_eye: np.ndarray = getattr(candidate_packet, f"_{eye}_eye")
        candidate_holes = (
            candidate_packet.left_mask if eye == "left" else candidate_packet.right_mask
        )
        warped, inside, bounds = native_remap_roi(
            candidate_eye, candidate_holes, candidate_flow, selection
        )
        if bounds is None:
            continue
        x, y, width, height = bounds
        local_selection = selection[y : y + height, x : x + width] & inside
        result_roi = result[y : y + height, x : x + width]
        result_roi[local_selection] = warped[local_selection]
        filled[y : y + height, x : x + width][local_selection] = True
    residual = target_mask & ~filled
    result, generated = inpainter.apply(result, residual)
    coverage = float(np.count_nonzero(filled) / max(1, np.count_nonzero(target_mask)))
    return result, residual, coverage, generated


def decoder(
    ffmpeg: Path,
    path: Path,
    width: int,
    height: int,
    frames: int,
    pixel_format: str,
    scale_flags: str = "lanczos",
) -> subprocess.Popen[bytes]:
    command = [
        str(ffmpeg), "-nostdin", "-v", "error", "-i", str(path),
        "-vf", f"scale={width}:{height}:flags={scale_flags},format={pixel_format}",
        "-frames:v", str(frames), "-an", "-f", "rawvideo", "-pix_fmt", pixel_format, "pipe:1",
    ]
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    return process


def read_frame(process: subprocess.Popen[bytes], shape: tuple[int, ...]) -> np.ndarray | None:
    if process.stdout is None:
        return None
    extent = int(np.prod(shape))
    raw = read_exact(process.stdout, extent)
    if not raw:
        return None
    if len(raw) != extent:
        raise ValueError("truncated raw video frame")
    return np.frombuffer(raw, np.uint8).reshape(shape).copy()


def encode_options(codec: str, quality: int) -> list[str]:
    encoder = "hevc_nvenc" if codec == "h265" else "h264_nvenc"
    return ["-c:v", encoder, "-preset", "p2", "-rc", "constqp", "-qp", str(quality), "-pix_fmt", "yuv420p"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--source-video", required=True, type=Path)
    parser.add_argument("--stereo-video", required=True, type=Path)
    parser.add_argument("--left-mask-video", required=True, type=Path)
    parser.add_argument("--right-mask-video", required=True, type=Path)
    parser.add_argument("--depth-directory", required=True, type=Path)
    parser.add_argument("--output-video", required=True, type=Path)
    parser.add_argument("--residual-mask-output", type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--frames", required=True, type=int)
    parser.add_argument("--fps", required=True, type=float)
    parser.add_argument(
        "--layout", choices=["half-sbs", "full-sbs", "half-ou", "full-ou"], default="half-sbs"
    )
    parser.add_argument("--flow-backend", choices=["raft", "dis"], default="raft")
    parser.add_argument("--raft-weights", type=Path)
    parser.add_argument("--raft-updates", type=int, default=4)
    parser.add_argument("--flow-max-side", type=int, default=640)
    parser.add_argument("--lookaround-frames", type=int, default=8)
    parser.add_argument("--minimum-confidence", type=float, default=0.38)
    parser.add_argument("--photometric-threshold", type=float, default=0.18)
    parser.add_argument("--depth-tolerance", type=float, default=0.12)
    parser.add_argument("--scene-cut-threshold", type=float, default=0.16)
    parser.add_argument("--migan-model", type=Path)
    parser.add_argument("--migan-provider", choices=["dml", "cpu"], default="dml")
    parser.add_argument("--max-neural-regions", type=int, default=2)
    parser.add_argument("--codec", choices=["h264", "h265"], default="h265")
    parser.add_argument("--quality", type=int, default=18)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.frames <= 0:
        raise ValueError("frames must be positive")
    eye_width, eye_height, packed_width, packed_height = layout_geometry(
        args.width, args.height, args.layout
    )
    guide_width, guide_height = guide_geometry(args.width, args.height, args.flow_max_side)
    depth_paths = sorted(args.depth_directory.glob("chunk-*.depth"))
    if not depth_paths:
        raise FileNotFoundError(f"no depth chunks in {args.depth_directory}")
    depth_iterator = iter(depth_frames(depth_paths))
    if args.flow_backend == "raft":
        if args.raft_weights is None or not args.raft_weights.exists():
            raise FileNotFoundError("RAFT weights are required for the quality Temporal Atlas")
        flow_estimator: FlowEstimator = RaftFlowEstimator(args.raft_weights, args.raft_updates)
    else:
        flow_estimator = DisFlowEstimator()
    inpainter = MiganInpainter(args.migan_model, args.migan_provider, args.max_neural_regions)
    emit(
        "TEMPORAL_ATLAS_READY",
        flow=flow_estimator.provider,
        inpaint=inpainter.provider,
        max_neural_regions=inpainter.max_regions,
        guide=f"{guide_width}x{guide_height}",
        lookaround=args.lookaround_frames,
        native=f"{packed_width}x{packed_height}",
    )

    source_decoder = decoder(
        args.ffmpeg, args.source_video, guide_width, guide_height, args.frames, "rgb24", "area"
    )
    stereo_decoder = decoder(
        args.ffmpeg, args.stereo_video, packed_width, packed_height, args.frames, "rgb24"
    )
    left_mask_decoder = decoder(
        args.ffmpeg, args.left_mask_video, eye_width, eye_height, args.frames, "gray", "neighbor"
    )
    right_mask_decoder = decoder(
        args.ffmpeg, args.right_mask_video, eye_width, eye_height, args.frames, "gray", "neighbor"
    )
    encoder_command = [
        str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s:v", f"{packed_width}x{packed_height}",
        "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an",
    ] + encode_options(args.codec, args.quality) + [
        "-frames:v", str(args.frames), "-movflags", "+faststart", str(args.output_video)
    ]
    encoder = subprocess.Popen(
        encoder_command,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    residual_encoder = None
    if args.residual_mask_output is not None:
        residual_encoder = subprocess.Popen(
            [
                str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
                "-f", "rawvideo", "-pix_fmt", "gray", "-s:v", f"{packed_width}x{packed_height}",
                "-r", f"{args.fps:.9g}", "-i", "pipe:0", "-an", "-c:v", "ffv1",
                "-frames:v", str(args.frames), str(args.residual_mask_output),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    if encoder.stdin is None:
        raise RuntimeError("could not create Temporal Atlas output pipe")

    window = max(1, min(30, args.lookaround_frames))
    packets: collections.deque[AtlasFrame] = collections.deque()
    packet_map: dict[int, AtlasFrame] = {}
    next_output = 0
    scene = 0
    processed = 0
    atlas_coverage_sum = 0.0
    generated_pixels = 0
    mask_pixels = 0
    started = time.perf_counter()

    def process_ready(final: bool) -> None:
        nonlocal next_output, processed, atlas_coverage_sum, generated_pixels, mask_pixels
        latest = packets[-1].index if packets else -1
        limit = latest if final else latest - window
        offsets = candidate_offsets(window)
        while next_output <= limit and next_output in packet_map:
            target = packet_map[next_output]
            candidates = [next_output + offset for offset in offsets]
            left, left_residual, left_coverage, left_generated = repair_eye(
                packet_map, next_output, candidates, "left",
                args.minimum_confidence, args.photometric_threshold, args.depth_tolerance, inpainter,
            )
            right, right_residual, right_coverage, right_generated = repair_eye(
                packet_map, next_output, candidates, "right",
                args.minimum_confidence, args.photometric_threshold, args.depth_tolerance, inpainter,
            )
            packed = pack_eyes(left, right, args.layout)
            encoder.stdin.write(memoryview(np.ascontiguousarray(packed)).cast("B"))
            if residual_encoder is not None and residual_encoder.stdin is not None:
                residual = pack_eyes(
                    np.repeat(left_residual[..., None], 3, axis=2),
                    np.repeat(right_residual[..., None], 3, axis=2),
                    args.layout,
                )[..., 0]
                residual_encoder.stdin.write(memoryview((residual.astype(np.uint8) * 255)).cast("B"))
            left_mask_count = int(np.count_nonzero(target.left_mask))
            right_mask_count = int(np.count_nonzero(target.right_mask))
            frame_mask_pixels = left_mask_count + right_mask_count
            weighted_coverage = (
                left_coverage * left_mask_count + right_coverage * right_mask_count
            ) / max(1, frame_mask_pixels)
            atlas_coverage_sum += weighted_coverage
            generated_pixels += left_generated + right_generated
            mask_pixels += frame_mask_pixels
            processed += 1
            next_output += 1
            keep_from = next_output - window
            while packets and packets[0].index < keep_from:
                old = packets.popleft()
                packet_map.pop(old.index, None)
            progress_interval = max(5, min(30, args.frames // 20 or 5))
            if processed == 1 or processed % progress_interval == 0 or processed == args.frames:
                elapsed = time.perf_counter() - started
                emit(
                    "TEMPORAL_ATLAS_PROGRESS",
                    frames=processed,
                    total=args.frames,
                    fps=processed / max(elapsed, 1.0e-6),
                    atlas_coverage=atlas_coverage_sum / processed,
                    residual_fraction=generated_pixels / max(1, mask_pixels),
                )

    try:
        previous: AtlasFrame | None = None
        for index in range(args.frames):
            source = read_frame(source_decoder, (guide_height, guide_width, 3))
            stereo = read_frame(stereo_decoder, (packed_height, packed_width, 3))
            left_mask_u8 = read_frame(left_mask_decoder, (eye_height, eye_width))
            right_mask_u8 = read_frame(right_mask_decoder, (eye_height, eye_width))
            if source is None or stereo is None or left_mask_u8 is None or right_mask_u8 is None:
                break
            depth = cv2.resize(next(depth_iterator), (guide_width, guide_height), interpolation=cv2.INTER_LINEAR)
            left_eye, right_eye = split_eyes(stereo, args.layout)
            packet = AtlasFrame(
                index=index,
                scene=scene,
                source=source,
                stereo=stereo,
                left_mask=left_mask_u8 >= 128,
                right_mask=right_mask_u8 >= 128,
                depth=depth,
            )
            setattr(packet, "_left_eye", left_eye)
            setattr(packet, "_right_eye", right_eye)
            if previous is not None:
                scene_delta = float(np.mean(np.abs(source.astype(np.float32) - previous.source.astype(np.float32))) / 255.0)
                if scene_delta >= args.scene_cut_threshold:
                    scene += 1
                    packet.scene = scene
                else:
                    forward, backward, forward_conf, backward_conf = flow_estimator.estimate_pair(
                        previous.source, source
                    )
                    previous.flow_next = forward
                    previous.confidence_next = forward_conf
                    packet.flow_prev = backward
                    packet.confidence_prev = backward_conf
            packets.append(packet)
            packet_map[index] = packet
            previous = packet
            process_ready(False)
        process_ready(True)
    finally:
        encoder.stdin.close()
        if residual_encoder is not None and residual_encoder.stdin is not None:
            residual_encoder.stdin.close()
        for process in (source_decoder, stereo_decoder, left_mask_decoder, right_mask_decoder):
            if process.stdout is not None:
                process.stdout.close()
            process.wait()
        encoder.wait()
        if residual_encoder is not None:
            residual_encoder.wait()

    if encoder.returncode != 0:
        details = encoder.stderr.read().decode("utf-8", errors="replace") if encoder.stderr else ""
        raise RuntimeError("Temporal Atlas output encoder failed: " + details)
    if processed != args.frames:
        raise RuntimeError(f"Temporal Atlas produced {processed} frames, expected {args.frames}")
    elapsed = time.perf_counter() - started
    emit(
        "TEMPORAL_ATLAS_DONE",
        frames=processed,
        elapsed_s=elapsed,
        fps=processed / max(elapsed, 1.0e-6),
        atlas_coverage=atlas_coverage_sum / max(1, processed),
        neural_residual_fraction=generated_pixels / max(1, mask_pixels),
        flow=flow_estimator.provider,
        inpaint=inpainter.provider,
        output=str(args.output_video),
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"TEMPORAL_ATLAS_ERROR {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise
