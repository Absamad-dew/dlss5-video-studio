"""Persistent motion/depth guide generator for DLSS5 Video Studio."""

from __future__ import annotations

import argparse
import json
import math
import mmap
import os
import subprocess
import struct
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort


ort.set_default_logger_severity(3)


def make_console_logging_safe() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(errors="backslashreplace")


make_console_logging_safe()


MOTION_MAGIC = b"D5MV0002"
DEPTH_MAGIC = b"D5DP0002"
MOTION_HEADER = struct.Struct("<8sIIIIIIII")
DEPTH_HEADER = struct.Struct("<8sIIIII")
MOTION_DTYPE = np.dtype(
    [("dx", "<f2"), ("dy", "<f2"), ("valid", "u1"), ("confidence", "u1")]
)


def atomic_path(path: Path) -> tuple[Path, Path]:
    final = path.resolve()
    final.parent.mkdir(parents=True, exist_ok=True)
    partial = final.with_name(final.name + ".partial")
    partial.unlink(missing_ok=True)
    return final, partial


def is_shared_rgb(reference: str | Path) -> bool:
    return str(reference).startswith("shm://")


def shared_rgb_tag(reference: str | Path) -> str:
    text = str(reference)
    if not text.startswith("shm://") or len(text) <= len("shm://"):
        raise ValueError("invalid shared RGB reference")
    name = text[len("shm://") :]
    if any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for character in name):
        raise ValueError("shared RGB name contains unsupported characters")
    return "Local\\" + name


def resize_rgb(frame: np.ndarray, width: int, height: int) -> np.ndarray:
    interpolation = cv2.INTER_AREA if frame.shape[1] > width else cv2.INTER_CUBIC
    return cv2.resize(frame, (width, height), interpolation=interpolation)


def normalized_gray(frame: np.ndarray, width: int, height: int) -> np.ndarray:
    return cv2.cvtColor(resize_rgb(frame, width, height), cv2.COLOR_RGB2GRAY)


def provider_candidates(backend: str, cache_dir: Path) -> list[list[object]]:
    available = set(ort.get_available_providers())
    cache_dir.mkdir(parents=True, exist_ok=True)
    candidates: list[list[object]] = []

    def add(name: str, options: dict[str, object] | None = None, fallbacks: list[str] | None = None) -> None:
        if name not in available:
            return
        providers: list[object] = [(name, options or {})] if options else [name]
        for fallback in fallbacks or []:
            if fallback in available:
                providers.append(fallback)
        candidates.append(providers)

    if backend in ("auto", "tensorrt-rtx"):
        add(
            "NvTensorRtRtxExecutionProvider",
            {"enable_cuda_graph": True, "nv_runtime_cache_path": str(cache_dir.resolve())},
            ["CUDAExecutionProvider", "CPUExecutionProvider"],
        )
    if backend in ("auto", "tensorrt"):
        add(
            "TensorrtExecutionProvider",
            {
                "trt_fp16_enable": True,
                "trt_engine_cache_enable": True,
                "trt_engine_cache_path": str(cache_dir.resolve()),
                "trt_timing_cache_enable": True,
                "trt_timing_cache_path": str(cache_dir.resolve()),
            },
            ["CUDAExecutionProvider", "CPUExecutionProvider"],
        )
    if backend in ("auto", "cuda"):
        add(
            "CUDAExecutionProvider",
            {"enable_cuda_graph": "1", "prefer_nhwc": "1"},
            ["CPUExecutionProvider"],
        )
    if backend in ("auto", "dml"):
        add("DmlExecutionProvider", fallbacks=["CPUExecutionProvider"])
    if backend in ("auto", "cpu"):
        add("CPUExecutionProvider")
    return candidates


def normalize_depth_map(prediction: np.ndarray, output_width: int, output_height: int) -> np.ndarray:
    depth = cv2.resize(
        np.asarray(prediction, dtype=np.float32),
        (output_width, output_height),
        interpolation=cv2.INTER_CUBIC,
    )
    low, high = np.quantile(depth[::4, ::4], (0.02, 0.98))
    if not np.isfinite(low) or not np.isfinite(high) or high <= low + 1e-6:
        return np.full((output_height, output_width), 0.5, dtype=np.float32)
    depth = np.clip((depth - float(low)) / float(high - low), 0.0, 1.0)
    return (0.02 + 0.96 * np.power(depth, 0.8)).astype(np.float32)


class DepthRuntime:
    def __init__(self, model: Path, backend: str, cache_dir: Path) -> None:
        options = ort.SessionOptions()
        options.enable_mem_pattern = False
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        failures: list[str] = []
        self.session: ort.InferenceSession | None = None
        for providers in provider_candidates(backend, cache_dir):
            try:
                self.session = ort.InferenceSession(
                    str(model.resolve()), sess_options=options, providers=providers
                )
                break
            except Exception as exc:
                failures.append(f"{providers[0]}: {exc}")
                if backend != "auto":
                    raise
        if self.session is None:
            details = "; ".join(failures) if failures else "no requested execution provider is installed"
            raise RuntimeError(f"cannot create depth session: {details}")

        self.input_name = self.session.get_inputs()[0].name
        self.output_name = self.session.get_outputs()[0].name
        self.provider = self.session.get_providers()[0]
        self.binding = None
        self.input_value = None
        self.output_value = None
        provider_lower = self.provider.lower()
        if "cuda" in provider_lower or "tensorrt" in provider_lower:
            try:
                self.input_value = ort.OrtValue.ortvalue_from_shape_and_type(
                    [1, 3, 518, 518], np.float32, "cuda", 0
                )
                self.output_value = ort.OrtValue.ortvalue_from_shape_and_type(
                    [1, 518, 518], np.float32, "cuda", 0
                )
                self.binding = self.session.io_binding()
                self.binding.bind_ortvalue_input(self.input_name, self.input_value)
                self.binding.bind_ortvalue_output(self.output_name, self.output_value)
            except Exception as exc:
                print(f"GUIDE_WARNING CUDA I/O binding disabled: {exc}", flush=True)
                self.binding = None
                self.input_value = None
                self.output_value = None

    def infer(self, tensor: np.ndarray) -> np.ndarray:
        assert self.session is not None
        if self.binding is not None and self.input_value is not None and self.output_value is not None:
            self.input_value.update_inplace(tensor)
            self.session.run_with_iobinding(self.binding)
            return np.asarray(self.output_value.numpy()).squeeze().astype(np.float32)
        return np.asarray(self.session.run(None, {self.input_name: tensor})[0]).squeeze().astype(np.float32)

    def infer_frame(self, frame: np.ndarray, output_width: int, output_height: int) -> np.ndarray:
        image = cv2.resize(frame, (518, 518), interpolation=cv2.INTER_CUBIC).astype(np.float32) / 255.0
        image = (image - np.array([0.485, 0.456, 0.406], dtype=np.float32)) / np.array(
            [0.229, 0.224, 0.225], dtype=np.float32
        )
        tensor = np.transpose(image, (2, 0, 1))[None].astype(np.float32, copy=False)
        return normalize_depth_map(self.infer(tensor), output_width, output_height)


class VideoDepthRuntime:
    """Temporally coherent CVPR 2025 Video Depth Anything streaming runtime."""

    provider = "torch-video-depth-anything-small-cuda"

    def __init__(self, model: Path, code_root: Path) -> None:
        if str(code_root.resolve()) not in sys.path:
            sys.path.insert(0, str(code_root.resolve()))
        import torch
        from video_depth_anything.video_depth_stream import VideoDepthAnything

        if not torch.cuda.is_available():
            raise RuntimeError("Video Depth Anything requires CUDA")
        torch.backends.cudnn.benchmark = True
        torch.set_float32_matmul_precision("high")
        config = {"encoder": "vits", "features": 64, "out_channels": [48, 96, 192, 384]}
        self.torch = torch
        self.model = VideoDepthAnything(**config)
        state = torch.load(model, map_location="cpu", weights_only=True)
        self.model.load_state_dict(state, strict=True)
        self.model = self.model.cuda().eval()

    def infer_frame(self, frame: np.ndarray, output_width: int, output_height: int) -> np.ndarray:
        prediction = self.model.infer_video_depth_one(
            frame, input_size=392, device="cuda", fp32=False
        )
        return normalize_depth_map(prediction, output_width, output_height)


class DepthAnything3Runtime:
    """Depth Anything 3 runtime with depth, confidence and camera-pose capable weights."""

    provider = "torch-depth-anything-3-cuda"

    def __init__(self, model: Path, code_root: Path) -> None:
        source_root = code_root / "src"
        if str(source_root.resolve()) not in sys.path:
            sys.path.insert(0, str(source_root.resolve()))
        import torch
        from depth_anything_3.api import DepthAnything3

        if not torch.cuda.is_available():
            raise RuntimeError("Depth Anything 3 requires CUDA")
        torch.backends.cudnn.benchmark = True
        torch.set_float32_matmul_precision("high")
        self.model = DepthAnything3.from_pretrained(str(model.resolve())).cuda().eval()

    def infer_frame(self, frame: np.ndarray, output_width: int, output_height: int) -> np.ndarray:
        prediction = self.model.inference(
            [frame], process_res=392, process_res_method="upper_bound_resize"
        )
        return normalize_depth_map(np.asarray(prediction.depth)[0], output_width, output_height)


def create_depth_runtime(args: argparse.Namespace):
    if args.depth_engine == "video-depth-small":
        if args.depth_code_root is None:
            raise ValueError("video-depth-small requires --depth-code-root")
        return VideoDepthRuntime(args.depth_model, args.depth_code_root)
    if args.depth_engine in ("da3-small", "da3-base"):
        if args.depth_code_root is None:
            raise ValueError("Depth Anything 3 requires --depth-code-root")
        return DepthAnything3Runtime(args.depth_model, args.depth_code_root)
    return DepthRuntime(args.depth_model, args.depth_backend, args.cache_dir)


def infer_depth(
    runtime,
    frame: np.ndarray,
    output_width: int,
    output_height: int,
) -> np.ndarray:
    return runtime.infer_frame(frame, output_width, output_height)


def flow_confidence(
    current: np.ndarray,
    previous: np.ndarray,
    flow: np.ndarray,
    xx: np.ndarray | None = None,
    yy: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    height, width = current.shape
    if xx is None or yy is None:
        yy, xx = np.mgrid[0:height, 0:width].astype(np.float32)
    map_x = xx + flow[..., 0]
    map_y = yy + flow[..., 1]
    in_bounds = (map_x >= 0) & (map_x <= width - 1) & (map_y >= 0) & (map_y <= height - 1)
    warped = cv2.remap(previous, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    error = np.abs(warped.astype(np.float32) - current.astype(np.float32)) / 255.0
    confidence = np.exp(-6.0 * error).astype(np.float32)
    return confidence, in_bounds


def stabilize_flow(
    flow: np.ndarray,
    previous_flow: np.ndarray | None,
    confidence: np.ndarray,
    xx: np.ndarray,
    yy: np.ndarray,
) -> np.ndarray:
    """Damp frame-to-frame vector jitter without lagging real acceleration."""
    if previous_flow is None:
        return flow
    previous_warped = cv2.remap(
        previous_flow,
        xx + flow[..., 0],
        yy + flow[..., 1],
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_REPLICATE,
    )
    acceleration = np.linalg.norm(flow - previous_warped, axis=2)
    history = 0.22 * confidence * np.exp(-acceleration / 1.5)
    return flow * (1.0 - history[..., None]) + previous_warped * history[..., None]


def occlusion_aware_confidence(
    confidence: np.ndarray,
    valid: np.ndarray,
    flow: np.ndarray,
) -> np.ndarray:
    """Lower history confidence around motion discontinuities/disocclusions."""
    grad = np.maximum(
        np.abs(cv2.Sobel(flow[..., 0], cv2.CV_32F, 1, 0, ksize=3)),
        np.abs(cv2.Sobel(flow[..., 0], cv2.CV_32F, 0, 1, ksize=3)),
    )
    grad = np.maximum(
        grad,
        np.maximum(
            np.abs(cv2.Sobel(flow[..., 1], cv2.CV_32F, 1, 0, ksize=3)),
            np.abs(cv2.Sobel(flow[..., 1], cv2.CV_32F, 0, 1, ksize=3)),
        ),
    )
    boundary = np.exp(-0.18 * grad)
    return np.where(valid, confidence * boundary, 0.0).astype(np.float32)


def align_depth_to_history(
    current: np.ndarray,
    history: np.ndarray | None,
    confidence: np.ndarray | None,
) -> tuple[np.ndarray, float, float]:
    """Remove per-frame affine scale/offset breathing from monocular depth."""
    if history is None or confidence is None:
        return current, 1.0, 0.0
    mask = (confidence > 0.62) & np.isfinite(current) & np.isfinite(history)
    sampled = mask[::2, ::2]
    if int(np.count_nonzero(sampled)) < 192:
        return current, 1.0, 0.0
    cur = current[::2, ::2][sampled]
    ref = history[::2, ::2][sampled]
    cq = np.quantile(cur, (0.1, 0.5, 0.9))
    rq = np.quantile(ref, (0.1, 0.5, 0.9))
    spread = float(cq[2] - cq[0])
    if spread <= 1e-5:
        return current, 1.0, 0.0
    scale = float(np.clip((rq[2] - rq[0]) / spread, 0.72, 1.38))
    offset = float(np.clip(rq[1] - scale * cq[1], -0.20, 0.20))
    return np.clip(current * scale + offset, 0.02, 0.98), scale, offset


def guided_depth(gray: np.ndarray, depth: np.ndarray) -> np.ndarray:
    """Fast edge-aware refinement at guide resolution (constant-time box filters)."""
    guide = gray.astype(np.float32) / 255.0
    ksize = (5, 5)
    mean_i = cv2.boxFilter(guide, cv2.CV_32F, ksize, normalize=True)
    mean_p = cv2.boxFilter(depth, cv2.CV_32F, ksize, normalize=True)
    corr_i = cv2.boxFilter(guide * guide, cv2.CV_32F, ksize, normalize=True)
    corr_ip = cv2.boxFilter(guide * depth, cv2.CV_32F, ksize, normalize=True)
    variance = corr_i - mean_i * mean_i
    covariance = corr_ip - mean_i * mean_p
    a = covariance / (variance + 0.0025)
    b = mean_p - a * mean_i
    mean_a = cv2.boxFilter(a, cv2.CV_32F, ksize, normalize=True)
    mean_b = cv2.boxFilter(b, cv2.CV_32F, ksize, normalize=True)
    refined = mean_a * guide + mean_b
    return np.clip(0.35 * depth + 0.65 * refined, 0.02, 0.98).astype(np.float32)


@dataclass
class GuideState:
    previous_gray: np.ndarray | None = None
    previous_color: np.ndarray | None = None
    previous_depth: np.ndarray | None = None
    previous_flow: np.ndarray | None = None
    frames_since_depth: int = 1_000_000
    global_frame: int = 0


@dataclass
class GuideGeometry:
    tile: int
    width: int
    height: int


def guide_geometry(width: int, height: int, requested_width: int) -> GuideGeometry:
    tile = max(1, int(math.ceil(width / max(64, requested_width))))
    return GuideGeometry(tile, int(math.ceil(width / tile)), int(math.ceil(height / tile)))


class DisMotion:
    provider = "opencv-dis"

    def __init__(self, preset: str) -> None:
        self.dis = create_dis(preset)

    def prepare(
        self,
        colors: list[np.ndarray],
        previous_color: np.ndarray | None,
        grays: list[np.ndarray] | None = None,
        previous_gray: np.ndarray | None = None,
    ) -> list[np.ndarray | None]:
        flows: list[np.ndarray | None] = [None] * len(colors)
        if grays is None:
            grays = [cv2.cvtColor(color, cv2.COLOR_RGB2GRAY) for color in colors]
        previous = previous_gray
        if previous is None and previous_color is not None:
            previous = cv2.cvtColor(previous_color, cv2.COLOR_RGB2GRAY)
        for index, current in enumerate(grays):
            if previous is not None:
                flows[index] = self.dis.calc(current, previous, None).astype(np.float32)
            previous = current
        return flows


class RaftMotion:
    provider = "torchvision-raft-small-cuda"

    def __init__(self, weights_path: Path, updates: int, batch_size: int) -> None:
        import torch
        from torchvision.models.optical_flow import raft_small

        if not torch.cuda.is_available():
            raise RuntimeError("RAFT motion requires a CUDA GPU")
        # Realtime chunks always use one fixed guide geometry.  On current
        # Windows CUDA builds cuDNN autotuning costs several seconds on the
        # first RAFT batch while the deterministic heuristic is already fast.
        torch.backends.cudnn.benchmark = False
        torch.set_float32_matmul_precision("high")
        state = torch.load(weights_path, map_location="cpu", weights_only=True)
        self.torch = torch
        self.model = raft_small(weights=None, progress=False).eval().cuda()
        self.model.load_state_dict(state)
        self.updates = updates
        self.batch_size = batch_size

    def prepare(
        self,
        colors: list[np.ndarray],
        previous_color: np.ndarray | None,
        grays: list[np.ndarray] | None = None,
        previous_gray: np.ndarray | None = None,
    ) -> list[np.ndarray | None]:
        torch = self.torch
        flows: list[np.ndarray | None] = [None] * len(colors)
        pairs: list[tuple[int, np.ndarray, np.ndarray]] = []
        previous = previous_color
        for index, color in enumerate(colors):
            if previous is not None:
                pairs.append((index, color, previous))  # current -> previous, matching DIS convention
            previous = color
        for offset in range(0, len(pairs), self.batch_size):
            batch = pairs[offset : offset + self.batch_size]
            current_np = np.stack([item[1] for item in batch]).astype(np.float32, copy=False)
            previous_np = np.stack([item[2] for item in batch]).astype(np.float32, copy=False)
            current = torch.from_numpy(current_np).permute(0, 3, 1, 2).cuda(non_blocking=True)
            previous_tensor = torch.from_numpy(previous_np).permute(0, 3, 1, 2).cuda(non_blocking=True)
            current = current.div_(127.5).sub_(1.0)
            previous_tensor = previous_tensor.div_(127.5).sub_(1.0)
            height, width = current.shape[-2:]
            raft_height = max(128, (height + 7) // 8 * 8)
            raft_width = max(128, (width + 7) // 8 * 8)
            if (raft_height, raft_width) != (height, width):
                current = torch.nn.functional.interpolate(
                    current, (raft_height, raft_width), mode="bilinear", align_corners=False
                )
                previous_tensor = torch.nn.functional.interpolate(
                    previous_tensor, (raft_height, raft_width), mode="bilinear", align_corners=False
                )
            with torch.inference_mode(), torch.autocast("cuda", dtype=torch.float16):
                predicted = self.model(current, previous_tensor, num_flow_updates=self.updates)[-1]
                if (raft_height, raft_width) != (height, width):
                    predicted = torch.nn.functional.interpolate(
                        predicted, (height, width), mode="bilinear", align_corners=False
                    )
                    predicted[:, 0].mul_(width / raft_width)
                    predicted[:, 1].mul_(height / raft_height)
            predicted_np = predicted.permute(0, 2, 3, 1).float().cpu().numpy()
            for item, flow in zip(batch, predicted_np, strict=True):
                flows[item[0]] = flow
        return flows


def create_motion_estimator(args: argparse.Namespace) -> DisMotion | RaftMotion:
    if args.motion_backend == "raft":
        assert args.raft_weights is not None
        return RaftMotion(args.raft_weights, args.raft_updates, args.raft_batch_size)
    return DisMotion(args.motion_preset)


def generate_chunk(
    args: argparse.Namespace,
    runtime: DepthRuntime,
    motion_estimator: DisMotion | RaftMotion,
    state: GuideState,
    input_path: Path | str,
    frames_count: int,
    motion_output: Path,
    depth_output: Path,
    shared_inputs: dict[str, mmap.mmap] | None = None,
) -> dict[str, object]:
    expected = args.input_width * args.input_height * frames_count * 3
    if is_shared_rgb(input_path):
        if shared_inputs is None or str(input_path) not in shared_inputs:
            raise ValueError(f"shared RGB input is not available: {input_path}")
        shared_mapping = shared_inputs[str(input_path)]
        frames = np.ndarray(
            (frames_count, args.input_height, args.input_width, 3),
            dtype=np.uint8,
            buffer=shared_mapping,
        )
    else:
        resolved_input = Path(input_path)
        if resolved_input.stat().st_size != expected:
            raise ValueError(
                f"RGB24 extent mismatch: expected {expected}, got {resolved_input.stat().st_size}"
            )
        frames = np.memmap(
            resolved_input,
            dtype=np.uint8,
            mode="r",
            shape=(frames_count, args.input_height, args.input_width, 3),
        )
    geom = guide_geometry(args.width, args.height, args.guide_width)
    motion_final, motion_partial = atomic_path(motion_output)
    depth_final, depth_partial = atomic_path(depth_output)
    records = np.zeros((geom.height, geom.width), dtype=MOTION_DTYPE)
    yy, xx = np.mgrid[0 : geom.height, 0 : geom.width].astype(np.float32)
    depth_frames = 0
    scene_cuts = 0
    adaptive_frames = 0
    low_confidence_pixels = 0
    motion_pixels = 0
    refresh_deltas: list[float] = []
    depth_scales: list[float] = []
    started = time.perf_counter()
    depth_infer_s = 0.0
    write_s = 0.0
    commit_s = 0.0

    guide_colors = [
        resize_rgb(np.asarray(frames[index]), geom.width, geom.height)
        for index in range(frames_count)
    ]
    # DIS and the temporal/depth stages consume the same grayscale guide.
    # Computing it once saves two conversions per frame in the old DIS path.
    guide_grays = [cv2.cvtColor(color, cv2.COLOR_RGB2GRAY) for color in guide_colors]
    flow_started = time.perf_counter()
    prepared_flows = motion_estimator.prepare(
        guide_colors, state.previous_color, guide_grays, state.previous_gray
    )
    flow_prepare_s = time.perf_counter() - flow_started

    try:
        with motion_partial.open("wb") as motion_stream, depth_partial.open("wb") as depth_stream:
            motion_stream.write(
                MOTION_HEADER.pack(
                    MOTION_MAGIC,
                    args.width,
                    args.height,
                    geom.tile,
                    frames_count,
                    geom.width,
                    geom.height,
                    MOTION_DTYPE.itemsize,
                    1,
                )
            )
            depth_stream.write(
                DEPTH_HEADER.pack(
                    DEPTH_MAGIC,
                    args.width,
                    args.height,
                    frames_count,
                    2,
                    1 | (geom.tile << 8),
                )
            )

            for local_index in range(frames_count):
                frame = np.asarray(frames[local_index])
                guide_color = guide_colors[local_index]
                gray = guide_grays[local_index]
                records.fill(0)
                scene_cut = False
                flow = None
                confidence = None
                warped_depth = None
                mean_confidence = 1.0
                p95_motion = 0.0

                if state.previous_gray is not None:
                    scene_mae = float(
                        np.mean(np.abs(gray.astype(np.float32) - state.previous_gray.astype(np.float32)))
                        / 255.0
                    )
                    scene_cut = scene_mae >= args.scene_cut_threshold
                    if scene_cut:
                        scene_cuts += 1
                        state.previous_flow = None
                    else:
                        flow = prepared_flows[local_index]
                        if flow is None:
                            raise RuntimeError("motion estimator did not return a consecutive-frame flow")
                        if state.previous_flow is not None:
                            initial_confidence, _ = flow_confidence(
                                gray, state.previous_gray, flow, xx, yy
                            )
                            flow = stabilize_flow(
                                flow, state.previous_flow, initial_confidence, xx, yy
                            )
                        confidence, valid = flow_confidence(
                            gray, state.previous_gray, flow, xx, yy
                        )
                        confidence = occlusion_aware_confidence(confidence, valid, flow)
                        valid = valid & (confidence >= 0.08)
                        valid_confidence = confidence[valid]
                        if valid_confidence.size:
                            mean_confidence = float(np.mean(valid_confidence))
                        if args.adaptive_motion > 0:
                            magnitude = np.sqrt(
                                flow[..., 0] * flow[..., 0] + flow[..., 1] * flow[..., 1]
                            )
                            p95_motion = float(np.quantile(magnitude[::2, ::2], 0.95))
                        records["dx"] = np.clip(
                            flow[..., 0] * (args.width / geom.width), -32752, 32752
                        ).astype(np.float16)
                        records["dy"] = np.clip(
                            flow[..., 1] * (args.height / geom.height), -32752, 32752
                        ).astype(np.float16)
                        records["valid"] = valid.astype(np.uint8)
                        records["confidence"] = np.rint(np.clip(confidence, 0, 1) * 255).astype(np.uint8)
                        low_confidence_pixels += int(np.count_nonzero(confidence < 0.55))
                        motion_pixels += int(confidence.size)
                        if state.previous_depth is not None:
                            warped_depth = cv2.remap(
                                state.previous_depth,
                                xx + flow[..., 0],
                                yy + flow[..., 1],
                                cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_REPLICATE,
                            )

                periodic_due = state.frames_since_depth >= max(0, args.depth_interval - 1)
                adaptive_due = False
                if state.frames_since_depth >= max(0, args.depth_min_interval - 1):
                    adaptive_due = (
                        (args.adaptive_confidence > 0 and mean_confidence < args.adaptive_confidence)
                        or (args.adaptive_motion > 0 and p95_motion > args.adaptive_motion)
                    )
                needs_depth = state.previous_depth is None or scene_cut or periodic_due or adaptive_due
                if needs_depth:
                    depth_started = time.perf_counter()
                    depth = infer_depth(runtime, frame, geom.width, geom.height)
                    depth_infer_s += time.perf_counter() - depth_started
                    depth_frames += 1
                    if adaptive_due and not periodic_due and not scene_cut:
                        adaptive_frames += 1
                    state.frames_since_depth = 0
                    depth, depth_scale, _ = align_depth_to_history(depth, warped_depth, confidence)
                    depth_scales.append(depth_scale)
                    if warped_depth is not None and confidence is not None and args.temporal_depth > 0:
                        blend = np.clip(args.temporal_depth * confidence, 0, 0.75)
                        depth = depth * (1.0 - blend) + warped_depth * blend
                        refresh_deltas.append(float(np.mean(np.abs(depth - warped_depth))))
                elif warped_depth is not None:
                    depth = warped_depth
                    state.frames_since_depth += 1
                else:
                    depth_started = time.perf_counter()
                    depth = infer_depth(runtime, frame, geom.width, geom.height)
                    depth_infer_s += time.perf_counter() - depth_started
                    depth_frames += 1
                    state.frames_since_depth = 0

                depth = guided_depth(gray, depth)

                write_started = time.perf_counter()
                records.tofile(motion_stream)
                np.clip(depth, 0.02, 0.98).astype("<f2").tofile(depth_stream)
                write_s += time.perf_counter() - write_started
                state.previous_gray = gray
                state.previous_color = guide_color
                state.previous_depth = depth.astype(np.float32, copy=False)
                state.previous_flow = None if flow is None else flow.astype(np.float32, copy=False)
                state.global_frame += 1
                if args.verbose_frames:
                    print(
                        f"GUIDE_FRAME {state.global_frame} cut={int(scene_cut)} depth={int(needs_depth)} "
                        f"confidence={mean_confidence:.3f} motion95={p95_motion:.3f} provider={runtime.provider}",
                        flush=True,
                    )

        commit_started = time.perf_counter()
        os.replace(motion_partial, motion_final)
        os.replace(depth_partial, depth_final)
        commit_s += time.perf_counter() - commit_started
    except BaseException:
        motion_partial.unlink(missing_ok=True)
        depth_partial.unlink(missing_ok=True)
        raise
    finally:
        del frames

    elapsed = time.perf_counter() - started
    return {
        "status": "ok",
        "frames": frames_count,
        "geometry": [args.width, args.height],
        "guide_geometry": [geom.width, geom.height],
        "tile": geom.tile,
        "motion": str(motion_final),
        "depth": str(depth_final),
        "depth_provider": runtime.provider,
        "motion_provider": motion_estimator.provider,
        "depth_frames": depth_frames,
        "adaptive_depth_frames": adaptive_frames,
        "scene_cuts": scene_cuts,
        "low_confidence_fraction": low_confidence_pixels / max(1, motion_pixels),
        "depth_refresh_delta_mean": float(np.mean(refresh_deltas)) if refresh_deltas else 0.0,
        "depth_scale_stddev": float(np.std(depth_scales)) if depth_scales else 0.0,
        "elapsed_s": elapsed,
        "flow_prepare_s": flow_prepare_s,
        "depth_infer_s": depth_infer_s,
        "write_s": write_s,
        "commit_s": commit_s,
        "cpu_post_s": max(0.0, elapsed - flow_prepare_s - depth_infer_s - write_s - commit_s),
        "fps": frames_count / elapsed,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", action="store_true")
    parser.add_argument("--input", type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--input-width", type=int, default=0)
    parser.add_argument("--input-height", type=int, default=0)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--motion-output", type=Path)
    parser.add_argument("--depth-output", type=Path)
    parser.add_argument("--depth-model", required=True, type=Path)
    parser.add_argument(
        "--depth-engine",
        choices=["da2-small", "video-depth-small", "da3-small", "da3-base"],
        default="da2-small",
    )
    parser.add_argument("--depth-code-root", type=Path)
    parser.add_argument("--depth-backend", choices=["auto", "tensorrt-rtx", "tensorrt", "cuda", "dml", "cpu"], default="auto")
    parser.add_argument("--cache-dir", type=Path, default=Path("depth-cache"))
    parser.add_argument("--guide-width", type=int, default=480)
    parser.add_argument("--depth-interval", type=int, default=2)
    parser.add_argument("--depth-min-interval", type=int, default=2)
    parser.add_argument("--scene-cut-threshold", type=float, default=0.12)
    parser.add_argument("--adaptive-confidence", type=float, default=0.45)
    parser.add_argument("--adaptive-motion", type=float, default=10.0)
    parser.add_argument("--temporal-depth", type=float, default=0.35)
    parser.add_argument("--motion-preset", choices=["quality", "balanced", "realtime"], default="balanced")
    parser.add_argument("--motion-backend", choices=["dis", "raft"], default="dis")
    parser.add_argument("--raft-weights", type=Path)
    parser.add_argument("--raft-updates", type=int, default=4)
    parser.add_argument("--raft-batch-size", type=int, default=4)
    parser.add_argument("--opencv-threads", type=int, default=0)
    parser.add_argument("--verbose-frames", action="store_true")
    parser.add_argument("--decode-video")
    parser.add_argument("--ffmpeg", type=Path)
    parser.add_argument("--input-headers-json", type=Path)
    parser.add_argument("--input-tls-no-verify", action="store_true")
    parser.add_argument("--start-seconds", type=float, default=0.0)
    parser.add_argument("--fps", type=int, default=0)
    parser.add_argument("--frame-interpolation", choices=["off", "blend"], default="off")
    parser.add_argument("--total-frames", type=int, default=0)
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.input_width <= 0:
        args.input_width = args.width
    if args.input_height <= 0:
        args.input_height = args.height
    if args.width < 64 or args.height < 64:
        raise ValueError("invalid input geometry")
    if (
        args.input_width < 64
        or args.input_height < 64
        or args.input_width > args.width
        or args.input_height > args.height
    ):
        raise ValueError("invalid compact RGB geometry")
    if args.depth_engine.startswith("da3-"):
        if not args.depth_model.is_dir():
            raise FileNotFoundError(args.depth_model)
    elif not args.depth_model.is_file():
        raise FileNotFoundError(args.depth_model)
    if args.depth_engine != "da2-small" and (
        args.depth_code_root is None or not args.depth_code_root.is_dir()
    ):
        raise FileNotFoundError(args.depth_code_root or "depth code root")
    if args.depth_interval < 1 or args.depth_min_interval < 1:
        raise ValueError("depth intervals must be positive")
    if args.depth_min_interval > args.depth_interval:
        raise ValueError("depth-min-interval cannot exceed depth-interval")
    if not 0 < args.scene_cut_threshold <= 1:
        raise ValueError("scene-cut-threshold must be in (0, 1]")
    if args.motion_backend == "raft":
        if args.raft_weights is None or not args.raft_weights.is_file():
            raise FileNotFoundError(args.raft_weights or "RAFT weights")
        if args.raft_updates < 1 or args.raft_updates > 12:
            raise ValueError("raft-updates must be in [1, 12]")
        if args.raft_batch_size < 1 or args.raft_batch_size > 16:
            raise ValueError("raft-batch-size must be in [1, 16]")
    if args.opencv_threads < 0 or args.opencv_threads > 16:
        raise ValueError("opencv-threads must be in [0, 16]")
    if args.decode_video is not None:
        if not args.server:
            raise ValueError("persistent video decode is available only in server mode")
        if args.ffmpeg is None or not args.ffmpeg.is_file():
            raise FileNotFoundError(args.ffmpeg or "ffmpeg")
        is_network_source = args.decode_video.startswith(("http://", "https://"))
        if not is_network_source and not Path(args.decode_video).is_file():
            raise FileNotFoundError(args.decode_video)
        if args.input_headers_json is not None and not args.input_headers_json.is_file():
            raise FileNotFoundError(args.input_headers_json)
        if args.fps < 1 or args.total_frames < 1 or args.start_seconds < 0:
            raise ValueError("decode-video requires valid fps, total-frames and start-seconds")
    if not args.server and (
        args.input is None
        or args.frames is None
        or args.frames < 1
        or args.motion_output is None
        or args.depth_output is None
    ):
        raise ValueError("single mode requires input, frames, motion-output and depth-output")


def create_dis(preset: str) -> cv2.DISOpticalFlow:
    cv_preset = {
        "quality": cv2.DISOPTICAL_FLOW_PRESET_MEDIUM,
        "balanced": cv2.DISOPTICAL_FLOW_PRESET_FAST,
        "realtime": cv2.DISOPTICAL_FLOW_PRESET_ULTRAFAST,
    }[preset]
    dis = cv2.DISOpticalFlow_create(cv_preset)
    dis.setUseSpatialPropagation(True)
    # Realtime uses the higher-resolution guide grid plus our temporal vector
    # stabilizer; an extra variational pass mostly duplicates that work and
    # steals GPU/CPU headroom from the live DLSS stage.
    dis.setVariationalRefinementIterations({"quality": 5, "balanced": 2, "realtime": 0}[preset])
    return dis


def run_server(args: argparse.Namespace, runtime: DepthRuntime) -> int:
    motion_estimator = create_motion_estimator(args)
    state = GuideState()
    decoder: subprocess.Popen[bytes] | None = None
    decoder_next_frame = 0
    prefetch_thread: threading.Thread | None = None
    prefetch_spec: tuple[str, int, int] | None = None
    prefetch_result: dict[str, object] = {}
    shared_inputs: dict[str, mmap.mmap] = {}

    # Keep one decoder alive for the entire job.  The previous implementation
    # launched FFmpeg and performed a fresh seek for every chunk; besides the
    # process/seek cost, that made the first frame of every chunk stall.  A
    # single stdout stream starts filling while the NGX host is still loading
    # and guarantees exact sequential frame delivery.
    if args.decode_video is not None:
        input_options: list[str] = []
        if args.input_tls_no_verify:
            input_options += ["-tls_verify", "0"]
        if args.input_headers_json is not None:
            with args.input_headers_json.open("r", encoding="utf-8") as stream:
                headers = json.load(stream)
            if not isinstance(headers, dict):
                raise ValueError("input headers JSON must contain an object")
            header_block = "\r\n".join(
                f"{name}: {value}" for name, value in headers.items() if value is not None
            ) + "\r\n"
            if header_block != "\r\n":
                input_options += ["-headers", header_block]
        video_filter = f"scale={args.input_width}:{args.input_height}:flags=lanczos"
        if args.frame_interpolation == "blend":
            video_filter += f",minterpolate=fps={args.fps}:mi_mode=blend"
        else:
            video_filter += f",fps={args.fps}"
        video_filter += ",format=rgb24"
        decoder = subprocess.Popen(
            [
                str(args.ffmpeg), "-nostdin", "-v", "error",
                *input_options,
                "-ss", f"{args.start_seconds:.9g}", "-i", str(args.decode_video),
                "-vf", video_filter,
                "-frames:v", str(args.total_frames), "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=8 * 1024 * 1024,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

    def decode_chunk(reference: str, frames_count: int, first_frame: int) -> None:
        nonlocal decoder_next_frame
        if args.decode_video is None:
            return
        if decoder is None or decoder.stdout is None:
            raise RuntimeError("persistent ffmpeg decoder is unavailable")
        if first_frame != decoder_next_frame:
            raise RuntimeError(
                f"decoder request is not sequential: expected frame {decoder_next_frame}, got {first_frame}"
            )
        expected = args.input_width * args.input_height * frames_count * 3
        remaining = expected
        buffer = bytearray(min(8 * 1024 * 1024, expected))
        shared_mapping: mmap.mmap | None = None
        output_view: memoryview | None = None
        final: Path | None = None
        partial: Path | None = None
        try:
            if is_shared_rgb(reference):
                if reference in shared_inputs:
                    raise RuntimeError(f"shared RGB mapping already exists: {reference}")
                shared_mapping = mmap.mmap(
                    -1, expected, tagname=shared_rgb_tag(reference), access=mmap.ACCESS_WRITE
                )
                output_view = memoryview(shared_mapping)
                offset = 0
                while remaining:
                    view = output_view[offset : offset + min(len(buffer), remaining)]
                    received = decoder.stdout.readinto(view)
                    if not received:
                        code = decoder.poll()
                        details = ""
                        if code is not None and decoder.stderr is not None:
                            details = decoder.stderr.read().decode("utf-8", errors="replace").strip()
                        raise RuntimeError(
                            f"ffmpeg decoder ended early at frame {decoder_next_frame}"
                            + (f" ({details})" if details else "")
                        )
                    offset += received
                    remaining -= received
                output_view.release()
                output_view = None
                shared_inputs[reference] = shared_mapping
                shared_mapping = None
            else:
                path = Path(reference)
                path.parent.mkdir(parents=True, exist_ok=True)
                final, partial = atomic_path(path)
                with partial.open("wb", buffering=8 * 1024 * 1024) as stream:
                    while remaining:
                        view = memoryview(buffer)[: min(len(buffer), remaining)]
                        received = decoder.stdout.readinto(view)
                        if not received:
                            code = decoder.poll()
                            details = ""
                            if code is not None and decoder.stderr is not None:
                                details = decoder.stderr.read().decode("utf-8", errors="replace").strip()
                            raise RuntimeError(
                                f"ffmpeg decoder ended early at frame {decoder_next_frame}"
                                + (f" ({details})" if details else "")
                            )
                        stream.write(view[:received])
                        remaining -= received
                os.replace(partial, final)
            decoder_next_frame += frames_count
        except BaseException:
            if output_view is not None:
                output_view.release()
            if shared_mapping is not None:
                shared_mapping.close()
            if partial is not None:
                partial.unlink(missing_ok=True)
            raise

    def await_prefetch(reference: str, frames_count: int, first_frame: int) -> float | None:
        nonlocal prefetch_thread, prefetch_spec, prefetch_result
        if prefetch_thread is None:
            return None
        expected_spec = (reference, frames_count, first_frame)
        if prefetch_spec != expected_spec:
            raise RuntimeError(f"prefetch order mismatch: expected {prefetch_spec}, got {expected_spec}")
        prefetch_thread.join()
        error = prefetch_result.get("error")
        elapsed = float(prefetch_result.get("elapsed_s", 0.0))
        prefetch_thread = None
        prefetch_spec = None
        prefetch_result = {}
        if isinstance(error, BaseException):
            raise error
        return elapsed

    def start_prefetch(spec: object) -> None:
        nonlocal prefetch_thread, prefetch_spec, prefetch_result
        if not isinstance(spec, dict):
            return
        if prefetch_thread is not None:
            raise RuntimeError("decoder prefetch is already active")
        reference = str(spec["input"])
        frames_count = int(spec["frames"])
        first_frame = int(spec["first_frame"])
        prefetch_spec = (reference, frames_count, first_frame)
        prefetch_result = {}

        def worker() -> None:
            started = time.perf_counter()
            try:
                decode_chunk(reference, frames_count, first_frame)
            except BaseException as exc:
                prefetch_result["error"] = exc
            finally:
                prefetch_result["elapsed_s"] = time.perf_counter() - started

        prefetch_thread = threading.Thread(target=worker, name="guide-decode-prefetch", daemon=True)
        prefetch_thread.start()
    print(
        "GUIDE_SERVER_READY "
        + json.dumps(
            {
                "provider": runtime.provider,
                "motion_provider": motion_estimator.provider,
                "geometry": [args.width, args.height],
                "rgb_geometry": [args.input_width, args.input_height],
                "guide_width": args.guide_width,
                "depth_interval": args.depth_interval,
            },
            ensure_ascii=True,
        ),
        flush=True,
    )
    try:
        for raw_line in sys.stdin:
            line = raw_line.strip().lstrip("\ufeff")
            json_start = line.find("{")
            if json_start > 0:
                line = line[json_start:]
            if not line:
                continue
            try:
                command = json.loads(line)
            except json.JSONDecodeError:
                print(f"GUIDE_BAD_COMMAND {line!r}", file=sys.stderr, flush=True)
                raise
            if command.get("cmd") == "end":
                print("GUIDE_SERVER_DONE", flush=True)
                return 0
            command_name = command.get("cmd")
            if command_name == "release":
                references = command.get("inputs", [])
                if not isinstance(references, list):
                    raise ValueError("release inputs must be a list")
                released = 0
                for reference_value in references:
                    reference = str(reference_value)
                    mapping = shared_inputs.pop(reference, None)
                    if mapping is not None:
                        mapping.close()
                        released += 1
                print(
                    "GUIDE_RELEASED "
                    + json.dumps({"released": released, "requested": len(references)}, ensure_ascii=True),
                    flush=True,
                )
                continue
            if command_name not in ("chunk", "decode", "guides"):
                raise ValueError("unknown guide server command")
            chunk_id = int(command["id"])
            chunk_input = str(command["input"])
            if command_name in ("chunk", "decode"):
                decode_started = time.perf_counter()
                frames_count = int(command["frames"])
                first_frame = int(command.get("first_frame", 0))
                prefetched_elapsed = await_prefetch(chunk_input, frames_count, first_frame)
                if prefetched_elapsed is None:
                    decode_chunk(chunk_input, frames_count, first_frame)
                    decode_elapsed = time.perf_counter() - decode_started
                else:
                    decode_elapsed = prefetched_elapsed
            else:
                decode_elapsed = 0.0
            start_prefetch(command.get("prefetch"))
            if command_name == "decode":
                print(
                    "GUIDE_DECODE_READY "
                    + json.dumps(
                        {
                            "id": chunk_id,
                            "input": str(chunk_input),
                            "frames": int(command["frames"]),
                            "elapsed_s": decode_elapsed,
                            "persistent": True,
                        },
                        ensure_ascii=True,
                    ),
                    flush=True,
                )
                continue
            result = generate_chunk(
                args,
                runtime,
                motion_estimator,
                state,
                chunk_input,
                int(command["frames"]),
                Path(command["motion_output"]),
                Path(command["depth_output"]),
                shared_inputs,
            )
            result["id"] = chunk_id
            result["decode_s"] = decode_elapsed
            result["persistent_decode"] = decoder is not None
            print("GUIDE_CHUNK_READY " + json.dumps(result, ensure_ascii=True), flush=True)
        raise RuntimeError("guide server input closed without end command")
    finally:
        if prefetch_thread is not None:
            prefetch_thread.join(timeout=5)
        for mapping in shared_inputs.values():
            try:
                mapping.close()
            except BufferError:
                pass
        shared_inputs.clear()
        if decoder is not None:
            if decoder.stdout is not None:
                decoder.stdout.close()
            if decoder.poll() is None:
                decoder.terminate()
            try:
                decoder.wait(timeout=5)
            except subprocess.TimeoutExpired:
                decoder.kill()


def main() -> int:
    args = parse_args()
    validate_args(args)
    if args.opencv_threads:
        cv2.setNumThreads(args.opencv_threads)
    print("GUIDE_STAGE loading depth runtime", flush=True)
    runtime = create_depth_runtime(args)
    if args.server:
        return run_server(args, runtime)
    assert args.input is not None and args.frames is not None
    assert args.motion_output is not None and args.depth_output is not None
    result = generate_chunk(
        args,
        runtime,
        create_motion_estimator(args),
        GuideState(),
        args.input,
        args.frames,
        args.motion_output,
        args.depth_output,
    )
    print("GUIDE_RESULT " + json.dumps(result, ensure_ascii=True), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"GUIDE_ERROR {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise
