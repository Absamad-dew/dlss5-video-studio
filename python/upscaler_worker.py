"""Persistent RGB24 video super-resolution worker for DLSS5 Video Studio.

The protocol deliberately uses raw RGB files.  The Studio owns decoding,
motion/depth generation and encoding, while this process keeps the selected
network resident on the GPU for the whole job.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import time
from pathlib import Path

# Keep CUDA modules lazy and reuse Triton kernels between Studio launches.
# Both reduce the large, otherwise silent startup spike of diffusion backends.
os.environ.setdefault("CUDA_MODULE_LOADING", "LAZY")
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault(
    "PYTORCH_CUDA_ALLOC_CONF",
    "garbage_collection_threshold:0.80,max_split_size_mb:128",
)
_cache_base = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "DLSS5VideoStudio" / "triton-cache"
_cache_base.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("TRITON_CACHE_DIR", str(_cache_base))

import numpy as np


def make_console_logging_safe() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="backslashreplace")


make_console_logging_safe()


def atomic_output(path: Path) -> tuple[Path, Path]:
    final = path.resolve()
    final.parent.mkdir(parents=True, exist_ok=True)
    partial = final.with_name(final.name + ".partial")
    partial.unlink(missing_ok=True)
    return final, partial


def import_torch():
    try:
        import torch
    except Exception as exc:  # pragma: no cover - diagnostic path
        raise RuntimeError(
            "PyTorch CUDA runtime is not installed. Run INSTALL_MODELS.cmd once."
        ) from exc
    return torch


def configure_torch(torch) -> None:
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable; neural video upscalers require an NVIDIA GPU")
    torch.backends.cudnn.benchmark = True
    torch.backends.cudnn.allow_tf32 = True
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cuda.enable_flash_sdp(True)
    torch.backends.cuda.enable_mem_efficient_sdp(True)
    torch.backends.cuda.enable_math_sdp(True)
    try:
        torch.set_float32_matmul_precision("high")
    except Exception:
        pass


def emit_status(stage: str, message: str, **details) -> None:
    payload = {"stage": stage, "message": message, **details}
    print("UPSCALER_STATUS " + json.dumps(payload, ensure_ascii=True), flush=True)


def load_state_dict(torch, path: Path) -> dict:
    try:
        checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    except TypeError:
        checkpoint = torch.load(path, map_location="cpu")
    if isinstance(checkpoint, dict):
        for key in ("params_ema", "params", "model_state_dict", "state_dict"):
            if key in checkpoint and isinstance(checkpoint[key], dict):
                return checkpoint[key]
    if not isinstance(checkpoint, dict):
        raise RuntimeError(f"Unsupported checkpoint payload: {path}")
    return checkpoint


def resolve_nanovsr_variant(model_root: Path, variant: str, vram_mb: int) -> tuple[str, Path]:
    if variant == "auto":
        variant = "1.7m" if vram_mb >= 12000 else "644k"
    aliases = {"realtime": "226k", "balanced": "644k", "quality": "1.7m", "max": "5.4m"}
    variant = aliases.get(variant, variant)
    candidate = model_root / "nanovsr" / f"nanovsr_{variant}.pth"
    if not candidate.is_file():
        raise FileNotFoundError(f"NanoVSR checkpoint is missing: {candidate}")
    return variant, candidate


class NanoBackend:
    scale = 4

    def __init__(self, args, torch, vram_mb: int) -> None:
        from torch import nn
        from torch.nn import functional as F

        class RepVGGBlock(nn.Module):
            def __init__(self, in_channels, out_channels):
                super().__init__()
                self.in_channels = in_channels
                self.rbr_identity = nn.BatchNorm2d(in_channels) if out_channels == in_channels else None
                self.rbr_dense = nn.Sequential(
                    nn.Conv2d(in_channels, out_channels, 3, 1, 1, bias=False), nn.BatchNorm2d(out_channels)
                )
                self.rbr_1x1 = nn.Sequential(
                    nn.Conv2d(in_channels, out_channels, 1, 1, 0, bias=False), nn.BatchNorm2d(out_channels)
                )
                self.activation = nn.LeakyReLU(0.1, inplace=True)

            @staticmethod
            def _pad(kernel):
                return 0 if kernel is None else F.pad(kernel, [1, 1, 1, 1])

            def _fuse(self, branch):
                if branch is None:
                    return 0, 0
                if isinstance(branch, nn.Sequential):
                    kernel, bn = branch[0].weight, branch[1]
                else:
                    bn = branch
                    kernel = torch.zeros(
                        (self.in_channels, self.in_channels, 3, 3), dtype=bn.weight.dtype, device=bn.weight.device
                    )
                    idx = torch.arange(self.in_channels, device=bn.weight.device)
                    kernel[idx, idx, 1, 1] = 1
                std = (bn.running_var + bn.eps).sqrt()
                gain = (bn.weight / std).reshape(-1, 1, 1, 1)
                return kernel * gain, bn.bias - bn.running_mean * bn.weight / std

            def switch_to_deploy(self):
                k3, b3 = self._fuse(self.rbr_dense)
                k1, b1 = self._fuse(self.rbr_1x1)
                ki, bi = self._fuse(self.rbr_identity)
                conv = nn.Conv2d(self.rbr_dense[0].in_channels, self.rbr_dense[0].out_channels, 3, 1, 1, bias=True)
                conv.weight.data.copy_(k3 + self._pad(k1) + ki)
                conv.bias.data.copy_(b3 + b1 + bi)
                self.rbr_reparam = conv
                del self.rbr_dense, self.rbr_1x1, self.rbr_identity

            def forward(self, x):
                return self.activation(self.rbr_reparam(x))

        class PixelShuffleBlock(nn.Module):
            def __init__(self, in_channels, out_channels):
                super().__init__()
                self.conv = nn.Conv2d(in_channels, out_channels * 4, 3, 1, 1)
                self.shuffle = nn.PixelShuffle(2)
                self.prelu = nn.PReLU()

            def forward(self, x):
                return self.prelu(self.shuffle(self.conv(x)))

        class NanoVSR(nn.Module):
            def __init__(self, num_feat, num_blocks):
                super().__init__()
                self.feat_extract = RepVGGBlock(3, num_feat)
                self.forward_net = nn.Sequential(*[RepVGGBlock(num_feat, num_feat) for _ in range(num_blocks)])
                self.backward_net = nn.Sequential(*[RepVGGBlock(num_feat, num_feat) for _ in range(num_blocks)])
                self.fusion = nn.Conv2d(num_feat * 2, num_feat, 1)
                self.upsample1 = PixelShuffleBlock(num_feat, num_feat)
                self.upsample2 = PixelShuffleBlock(num_feat, 32)
                self.conv_last = nn.Conv2d(32, 3, 3, 1, 1)

            def switch_to_deploy(self):
                for module in list(self.modules()):
                    if isinstance(module, RepVGGBlock):
                        module.switch_to_deploy()

            def forward(self, x):
                b, t, c, h, w = x.shape
                feats = self.feat_extract(x.reshape(-1, c, h, w)).reshape(b, t, -1, h, w)
                forward_feats, backward_feats = [], []
                prop = torch.zeros_like(feats[:, 0])
                for i in range(t):
                    prop = self.forward_net(feats[:, i] + prop)
                    forward_feats.append(prop)
                prop = torch.zeros_like(feats[:, 0])
                for i in range(t - 1, -1, -1):
                    prop = self.backward_net(feats[:, i] + prop)
                    backward_feats.insert(0, prop)
                outputs = []
                for i in range(t):
                    fused = self.fusion(torch.cat((forward_feats[i], backward_feats[i]), dim=1))
                    out = self.conv_last(self.upsample2(self.upsample1(fused)))
                    outputs.append(out + F.interpolate(x[:, i], scale_factor=4, mode="bilinear", align_corners=False))
                return torch.stack(outputs, dim=1)

        self.variant, checkpoint = resolve_nanovsr_variant(args.model_root, args.variant, vram_mb)
        state = load_state_dict(torch, checkpoint)
        feat_key = next((k for k in state if k.endswith("feat_extract.rbr_dense.0.weight")), None)
        if feat_key is None:
            feat_key = next(k for k in state if "feat_extract" in k and k.endswith("weight"))
        num_feat = int(state[feat_key].shape[0])
        indices = {
            int(k.split(".")[1]) for k in state if k.startswith("forward_net.") and k.split(".")[1].isdigit()
        }
        num_blocks = max(indices) + 1
        model = NanoVSR(num_feat, num_blocks)
        model.load_state_dict(state, strict=True)
        model.switch_to_deploy()
        self.dtype = torch.float16
        self.device = torch.device("cuda:0")
        self.model = model.eval().to(self.device, dtype=self.dtype, memory_format=torch.channels_last)
        self.strength = args.strength

    def process(self, frames: np.ndarray) -> np.ndarray:
        torch = import_torch()
        host = torch.from_numpy(np.ascontiguousarray(frames.transpose(0, 3, 1, 2))).pin_memory()
        x = host.unsqueeze(0).to(self.device, dtype=self.dtype, non_blocking=True).div_(255.0)
        with torch.inference_mode(), torch.autocast("cuda", dtype=self.dtype):
            output = self.model(x)
            if self.strength < 0.999:
                base = torch.nn.functional.interpolate(
                    x.flatten(0, 1), scale_factor=4, mode="bicubic", align_corners=False
                ).reshape_as(output)
                output = torch.lerp(base, output, self.strength)
        result = (
            output.squeeze(0).clamp(0, 1).mul(255).round().to(torch.uint8)
            .permute(0, 2, 3, 1).contiguous().cpu().numpy()
        )
        return result


class AnimeBackend:
    scale = 4

    def __init__(self, args, torch, _vram_mb: int) -> None:
        from torch import nn
        from torch.nn import functional as F

        class ResidualBlockNoBN(nn.Module):
            def __init__(self, num_feat=64):
                super().__init__()
                self.conv1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
                self.conv2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
                self.relu = nn.ReLU(inplace=True)

            def forward(self, x):
                return x + self.conv2(self.relu(self.conv1(x)))

        class MultiScaleCell(nn.Module):
            def __init__(self, num_in_ch=121, num_state_ch=64, num_out_ch=112, num_block=(5, 3, 2)):
                super().__init__()
                self.num_block = num_block
                self.conv_s1_first = nn.Sequential(nn.Conv2d(num_in_ch, num_state_ch, 3, 1, 1), nn.LeakyReLU(0.1, True))
                self.conv_s2_first = nn.Sequential(nn.Conv2d(num_state_ch, num_state_ch, 3, 2, 1), nn.LeakyReLU(0.1, True))
                self.conv_s4_first = nn.Sequential(nn.Conv2d(num_state_ch, num_state_ch, 3, 2, 1), nn.LeakyReLU(0.1, True))
                self.body_s1_first = nn.ModuleList([ResidualBlockNoBN(num_state_ch) for _ in range(num_block[0])])
                self.body_s2_first = nn.ModuleList([ResidualBlockNoBN(num_state_ch) for _ in range(num_block[1])])
                self.body_s4_first = nn.ModuleList([ResidualBlockNoBN(num_state_ch) for _ in range(num_block[2])])
                self.fusion = nn.Sequential(
                    nn.Conv2d(3 * num_state_ch, 2 * num_out_ch, 3, 1, 1), nn.LeakyReLU(0.1, True),
                    nn.Conv2d(2 * num_out_ch, num_out_ch, 3, 1, 1),
                )

            @staticmethod
            def up(x, scale):
                return x if isinstance(x, int) else F.interpolate(x, scale_factor=scale, mode="bilinear", align_corners=False)

            def forward(self, x):
                x1 = self.conv_s1_first(x)
                x2 = self.conv_s2_first(x1)
                x4 = self.conv_s4_first(x2)
                have2 = have4 = False
                for i in range(self.num_block[0]):
                    x1 = self.body_s1_first[i](x1 + (self.up(x2, 2) if have2 else 0) + (self.up(x4, 4) if have4 else 0))
                    if i >= self.num_block[0] - self.num_block[1]:
                        x2 = self.body_s2_first[i - self.num_block[0] + self.num_block[1]](x2 + (self.up(x4, 2) if have4 else 0))
                        have2 = True
                    if i >= self.num_block[0] - self.num_block[2]:
                        x4 = self.body_s4_first[i - self.num_block[0] + self.num_block[2]](x4)
                        have4 = True
                return self.fusion(torch.cat((x1, self.up(x2, 2), self.up(x4, 4)), dim=1))

        class AnimeSR(nn.Module):
            def __init__(self):
                super().__init__()
                self.recurrent_cell = MultiScaleCell()
                self.lrelu = nn.LeakyReLU(0.1)
                self.pixel_shuffle = nn.PixelShuffle(4)

            @staticmethod
            def pixel_unshuffle(x):
                return F.pixel_unshuffle(x, 4)

            def cell(self, x, feedback, state):
                residual = x[:, 3:6]
                merged = torch.cat((x, self.pixel_unshuffle(feedback), state), dim=1)
                out = self.recurrent_cell(merged)
                image = self.pixel_shuffle(out[:, :48]) + F.interpolate(residual, scale_factor=4, mode="bilinear", align_corners=False)
                return image, self.lrelu(out[:, 48:])

        checkpoint = args.model_root / "animesr" / "AnimeSR_v2.pth"
        if not checkpoint.is_file():
            raise FileNotFoundError(f"AnimeSR v2 checkpoint is missing: {checkpoint}")
        model = AnimeSR()
        model.load_state_dict(load_state_dict(torch, checkpoint), strict=True)
        self.dtype = torch.float16
        self.device = torch.device("cuda:0")
        self.model = model.eval().to(self.device, dtype=self.dtype, memory_format=torch.channels_last)
        self.state = None
        self.feedback = None
        self.previous = None
        self.strength = args.strength
        self.output_height = args.output_height
        self.output_width = args.output_width
        self.variant = "v2-fp16-recurrent"

    def process(self, frames: np.ndarray) -> np.ndarray:
        torch = import_torch()
        host = torch.from_numpy(np.ascontiguousarray(frames.transpose(0, 3, 1, 2))).pin_memory()
        x = host.to(self.device, dtype=self.dtype, non_blocking=True).div_(255.0)
        # The two stride-2 branches require an input divisible by four.  Video
        # aspect ratios often produce legal x4 outputs whose low-resolution
        # side is odd (for example 540 -> 135), so pad only inside the model
        # and crop the x4 result back to the exact requested geometry.
        pad_h = (-int(x.shape[-2])) % 4
        pad_w = (-int(x.shape[-1])) % 4
        if pad_h or pad_w:
            x = torch.nn.functional.pad(x, (0, pad_w, 0, pad_h), mode="replicate")
        outputs = []
        with torch.inference_mode(), torch.autocast("cuda", dtype=self.dtype):
            if self.state is None:
                _, _, h, w = x.shape
                self.state = torch.zeros((1, 64, h, w), device=self.device, dtype=self.dtype).to(memory_format=torch.channels_last)
                self.feedback = torch.zeros((1, 3, h * 4, w * 4), device=self.device, dtype=self.dtype).to(memory_format=torch.channels_last)
                self.previous = x[0:1]
            for i in range(x.shape[0]):
                current = x[i : i + 1]
                nxt = x[i + 1 : i + 2] if i + 1 < x.shape[0] else current
                merged = torch.cat((self.previous, current, nxt), dim=1).to(memory_format=torch.channels_last)
                self.feedback, self.state = self.model.cell(merged, self.feedback, self.state)
                out = self.feedback
                if self.strength < 0.999:
                    base = torch.nn.functional.interpolate(current, scale_factor=4, mode="bicubic", align_corners=False)
                    out = torch.lerp(base, out, self.strength)
                outputs.append(out)
                self.previous = current
            output = torch.cat(outputs, dim=0)
            output = output[:, :, : self.output_height, : self.output_width]
        return (
            output.clamp(0, 1).mul(255).round().to(torch.uint8)
            .permute(0, 2, 3, 1).contiguous().cpu().numpy()
        )


def build_backend(args, torch, vram_mb: int):
    if args.backend == "nanovsr":
        return NanoBackend(args, torch, vram_mb)
    if args.backend == "animesr":
        return AnimeBackend(args, torch, vram_mb)
    if args.backend in ("flashvsr", "dloral"):
        module_name = f"{args.backend}_backend"
        sys.path.insert(0, str(args.backend_root.resolve()))
        try:
            module = __import__(module_name)
        except Exception as exc:
            raise RuntimeError(
                f"{args.backend} optimized runtime is not installed correctly: {exc}"
            ) from exc
        return module.Backend(args, torch, vram_mb)
    raise ValueError(f"Unknown upscaler backend: {args.backend}")


def process_chunk(args, backend, command: dict) -> dict:
    torch = import_torch()
    frames_count = int(command["frames"])
    input_path = Path(command["input"])
    output_path = Path(command["output"])
    expected = args.input_width * args.input_height * frames_count * 3
    actual = input_path.stat().st_size
    if actual != expected:
        raise ValueError(f"RGB24 input extent mismatch: expected {expected}, got {actual}")
    frames = np.memmap(
        input_path, dtype=np.uint8, mode="r", shape=(frames_count, args.input_height, args.input_width, 3)
    )
    torch.cuda.reset_peak_memory_stats()
    started = time.perf_counter()
    emit_status(
        "chunk",
        f"{args.backend}: processing chunk {int(command['id']) + 1}",
        chunk_id=int(command["id"]),
        frames=frames_count,
    )
    output = backend.process(np.asarray(frames))
    torch.cuda.synchronize()
    if output.shape != (frames_count, args.output_height, args.output_width, 3):
        raise RuntimeError(f"Model returned unexpected shape {output.shape}")
    final, partial = atomic_output(output_path)
    with partial.open("wb", buffering=8 * 1024 * 1024) as stream:
        stream.write(np.ascontiguousarray(output).tobytes())
    os.replace(partial, final)
    elapsed = time.perf_counter() - started
    return {
        "status": "ok", "id": int(command["id"]), "frames": frames_count,
        "input_geometry": [args.input_width, args.input_height],
        "output_geometry": [args.output_width, args.output_height],
        "elapsed_s": elapsed, "fps": frames_count / elapsed, "output": str(final),
        "peak_vram_mb": int(torch.cuda.max_memory_allocated() / (1024 * 1024)),
        "reserved_vram_mb": int(torch.cuda.max_memory_reserved() / (1024 * 1024)),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", action="store_true")
    parser.add_argument("--backend", required=True, choices=["nanovsr", "animesr", "flashvsr", "dloral"])
    parser.add_argument("--variant", default="auto")
    parser.add_argument("--model-root", required=True, type=Path)
    parser.add_argument("--backend-root", required=True, type=Path)
    parser.add_argument("--third-party-root", required=True, type=Path)
    parser.add_argument("--input-width", required=True, type=int)
    parser.add_argument("--input-height", required=True, type=int)
    parser.add_argument("--output-width", required=True, type=int)
    parser.add_argument("--output-height", required=True, type=int)
    parser.add_argument("--strength", type=float, default=1.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.server:
        raise ValueError("only persistent server mode is supported")
    if args.output_width != args.input_width * 4 or args.output_height != args.input_height * 4:
        raise ValueError("selected models require an exact 4x output geometry")
    if not 0.0 <= args.strength <= 1.0:
        raise ValueError("strength must be in [0, 1]")
    emit_status("runtime", "Loading PyTorch CUDA runtime")
    torch = import_torch()
    configure_torch(torch)
    properties = torch.cuda.get_device_properties(0)
    vram_mb = int(properties.total_memory / (1024 * 1024))
    emit_status(
        "model",
        f"Loading {args.backend} on {properties.name}",
        backend=args.backend,
        requested_variant=args.variant,
        gpu=properties.name,
        vram_mb=vram_mb,
    )
    load_started = time.perf_counter()
    backend = build_backend(args, torch, vram_mb)
    torch.cuda.synchronize()
    emit_status(
        "ready",
        f"{args.backend} is resident and ready",
        backend=args.backend,
        resolved_variant=backend.variant,
        load_s=time.perf_counter() - load_started,
        allocated_vram_mb=int(torch.cuda.memory_allocated() / (1024 * 1024)),
        reserved_vram_mb=int(torch.cuda.memory_reserved() / (1024 * 1024)),
    )
    print(
        "UPSCALER_SERVER_READY "
        + json.dumps(
            {
                "backend": args.backend, "variant": backend.variant,
                "gpu": properties.name, "vram_mb": vram_mb,
                "input_geometry": [args.input_width, args.input_height],
                "output_geometry": [args.output_width, args.output_height],
                "load_s": time.perf_counter() - load_started,
                "torch": torch.__version__, "cuda": torch.version.cuda,
            }, ensure_ascii=True,
        ), flush=True,
    )
    for raw_line in sys.stdin:
        line = raw_line.strip().lstrip("\ufeff")
        if not line:
            continue
        command = json.loads(line[line.find("{") :])
        if command.get("cmd") == "end":
            print("UPSCALER_SERVER_DONE", flush=True)
            return 0
        if command.get("cmd") != "chunk":
            raise ValueError("unknown upscaler server command")
        result = process_chunk(args, backend, command)
        print("UPSCALER_CHUNK_READY " + json.dumps(result, ensure_ascii=True), flush=True)
    raise RuntimeError("upscaler server input closed without end command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"UPSCALER_ERROR {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        raise
