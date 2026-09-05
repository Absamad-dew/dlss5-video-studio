"""Studio VR-only raw disparity contract. Never changes the IW3 reference mode.

The NGX texture is a consumer, not the canonical depth storage. VR receives
float32 model-resolution disparity before guide clipping/gamma/temporal filters.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import struct
import sys
import numpy as np

HEADER = struct.Struct('<8sIIII')
FRAME = struct.Struct('<QB')
MAGIC = b'D5VRD001'


@dataclass
class DepthSample:
    guide: np.ndarray
    disparity: np.ndarray
    normalization: str = 'minmax'


class RawDepthWriter:
    def __init__(self, path: Path, count: int, first: int, limit_bytes=8 * 1024**3,
                 planned_total: int | None = None):
        self.path = path
        self.partial = path.with_suffix(path.suffix + '.partial')
        self.count, self.first, self.written = count, first, 0
        self.limit_bytes = limit_bytes
        self.planned_total = planned_total
        self.stream = None
        self.shape = None
        if count < 1 or first < 0:
            raise ValueError('Raw depth requires a positive count and nonnegative first index')
        if planned_total is not None and planned_total < first + count:
            raise ValueError('Planned raw-depth frame count is shorter than this chunk')

    def write(self, sample: DepthSample, scene_cut: bool):
        raw = np.ascontiguousarray(sample.disparity, dtype='<f4')
        if raw.ndim != 2 or not np.isfinite(raw).all():
            raise ValueError('VR raw disparity must be finite HxW float32')
        if self.stream is None:
            self.shape = raw.shape
            # Budget the whole selected range as soon as the first real model
            # output supplies its geometry, not after hours of completed chunks.
            # One file header per frame is a safe upper bound for any chunking.
            if self.planned_total is not None:
                bytes_per_frame = raw.nbytes + FRAME.size + HEADER.size
                if self.planned_total * bytes_per_frame > self.limit_bytes:
                    safe_frames = self.limit_bytes // bytes_per_frame
                    raise RuntimeError(
                        f'VR raw-depth cache needs more than {self.limit_bytes / 1024**3:.2f} GiB '
                        f'for {self.planned_total} frames at {raw.shape[1]}x{raw.shape[0]}. '
                        f'Select at most {safe_frames} frames per part; no frames were '
                        'published by this chunk.')
            expected = self.count * (raw.nbytes + FRAME.size) + HEADER.size
            used = sum(p.stat().st_size for p in self.path.parent.glob('chunk-*.vrd'))
            if expected + used > self.limit_bytes:
                raise RuntimeError('VR raw-depth cache would exceed 8 GiB. Select a shorter range.')
            self.stream = self.partial.open('wb')
            self.stream.write(HEADER.pack(MAGIC, raw.shape[1], raw.shape[0], self.count,
                                          int(sample.normalization == 'max')))
        if raw.shape != self.shape:
            raise ValueError('VR depth resolution changed within a chunk')
        self.stream.write(FRAME.pack(self.first + self.written, bool(scene_cut)))
        self.stream.write(memoryview(raw).cast('B'))
        self.written += 1

    def close(self, success: bool):
        if self.stream is not None:
            self.stream.close()
        if success and self.written == self.count:
            self.partial.replace(self.path)
        else:
            self.partial.unlink(missing_ok=True)
            if success:
                raise ValueError(f'Incomplete VR depth cache: {self.written}/{self.count}')


def raw_depth_frames(paths, expected_index=0):
    for path in paths:
        with Path(path).open('rb') as stream:
            header = stream.read(HEADER.size)
            if len(header) != HEADER.size:
                raise ValueError(f'Truncated VR depth header: {path}')
            magic, width, height, count, mode = HEADER.unpack(header)
            expected_bytes = HEADER.size + count*(FRAME.size+width*height*4)
            if (magic != MAGIC or min(width,height,count)<1 or max(width,height)>8192
                or mode not in (0,1) or Path(path).stat().st_size != expected_bytes):
                raise ValueError(f'Invalid VR depth header: {path}')
            for _ in range(count):
                frame = stream.read(FRAME.size)
                if len(frame) != FRAME.size:
                    raise ValueError(f'Truncated VR depth frame: {path}')
                index, cut = FRAME.unpack(frame)
                if cut not in (0,1):
                    raise ValueError('Invalid raw-depth scene marker')
                if index != expected_index:
                    raise ValueError(f'VR depth timeline mismatch: {index}/{expected_index}')
                values = np.fromfile(stream, dtype='<f4', count=width * height)
                if values.size != width * height or not np.isfinite(values).all():
                    raise ValueError(f'Invalid VR depth samples: {path}')
                yield index, values.reshape(height, width), bool(cut), 'max' if mode else 'minmax'
                expected_index += 1
            if stream.read(1):
                raise ValueError(f'Trailing VR depth data: {path}')


class SharedDepthRuntime:
    def __init__(self, base):
        self.base = base
        self.provider = base.provider + '+vr-raw'

    def infer_frame(self, frame, output_width, output_height):
        from guidegen import normalize_depth_map
        prediction = np.asarray(self.base.infer_raw_frame(frame), np.float32)
        # DA3 predicts distance; DA2 / VDA predict inverse depth.
        if getattr(self.base, 'is_distance', False):
            raw = 1.0 / (np.maximum(prediction, 0) + 0.2)
            normalization = 'max'
        else:
            raw, normalization = prediction, 'minmax'
        return DepthSample(normalize_depth_map(raw, output_width, output_height), raw, normalization)


class ReplayDepthRuntime:
    """Per-eye DLSS consumer: replay the projected depth, never run another net."""
    def __init__(self, directory):
        paths=sorted(Path(directory).glob('chunk-*.vrd'))
        if not paths:
            raise FileNotFoundError('Projected VR depth not found: '+str(directory))
        self.frames=iter(raw_depth_frames(paths))
        self.provider='studio-vr-projected-depth-replay'

    def infer_frame(self, frame, output_width, output_height):
        from guidegen import normalize_depth_map
        try:
            _,raw,_,_=next(self.frames)
        except StopIteration as error:
            raise RuntimeError('Projected VR depth ended before the eye video') from error
        return normalize_depth_map(raw,output_width,output_height)


class StudioDA3Runtime:
    """Read-only provider reuse; no patching of iw3 modules, weights or settings."""
    def __init__(self, root, name, resolution, executor='eager'):
        sys.path.insert(0, str(root / 'tools/iw3'))
        from iw3_worker import configure_imports
        configure_imports(root)
        from iw3_da3 import create_provider, is_da3
        from iw3_worker import validate_settings
        import torch
        self.torch = torch
        settings = validate_settings(root, {'depth_model': name, 'resolution': resolution})
        if is_da3(root, name):
            self.depth = create_provider(root, settings)
        else:
            from iw3.depth_model_factory import create_depth_model
            self.depth = create_depth_model(name)
        self.depth.load(gpu=0, resolution=resolution, limit_resolution=True)
        self.provider = 'studio-vr-' + name
        from vr_depth_execution import install_depth_only_head
        # This loaded instance belongs to Studio, never to the separate IW3 worker.
        # Only the auxiliary ray head is omitted; depth/confidence retain their
        # weights, precision and complete execution at the selected resolution.
        depth_only = install_depth_only_head(self.depth.model)
        print('VR_DEPTH_EXECUTION ' + json.dumps({'model':name,
              'depth_only_head':depth_only, 'precision_unchanged':True}), flush=True)
        self.graph = None
        self.executor = executor
        if executor == 'cuda-graph':
            from vr_cuda_graph import ValidatedCudaGraph
            # Capture the pure model, not Python validation / data-dependent sky logic.
            self.graph = ValidatedCudaGraph(self.depth.model)
            self.depth.model = self.graph

    def infer_frame(self, frame, output_width, output_height):
        from guidegen import normalize_depth_map
        array = np.ascontiguousarray(frame)
        if not array.flags.writeable:
            array = array.copy()
        tensor = self.torch.from_numpy(array).permute(2, 0, 1)
        with self.torch.inference_mode():
            raw = self.depth.infer(tensor.float().div_(255), enable_amp=True).squeeze().cpu().numpy()
        return DepthSample(normalize_depth_map(raw, output_width, output_height), raw, 'max')
