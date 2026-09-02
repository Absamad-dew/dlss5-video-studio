"""Chunked M2SVid right-eye generation for DLSS5 Video Studio.

The official 3DV 2026 model accepts a left video, a depth-warped right-eye
seed and its disocclusion mask.  This adapter keeps the 4.64 GB network loaded
once, processes long clips in overlapping windows of at most 25 frames, and
uses native PyTorch SDPA when xFormers is unavailable on Windows.
"""

from __future__ import annotations

import argparse
import gc
import json
import logging
import math
import os
import subprocess
import sys
import time
import warnings
from pathlib import Path
from typing import BinaryIO

import numpy as np

# Third-party training helpers emit noisy platform/deprecation warnings during
# import.  They are unrelated to inference and used to make Windows PowerShell
# treat a healthy process as failed before exit-code handling was hardened.
logging.getLogger("torch.distributed.elastic.multiprocessing.redirects").setLevel(logging.ERROR)
warnings.filterwarnings("ignore", message="The parameter 'pretrained' is deprecated.*")
warnings.filterwarnings("ignore", message="Arguments other than a weight enum.*")


def emit(kind: str, **payload: object) -> None:
    print(
        f"VR_GENERATIVE_{kind} " + json.dumps(payload, ensure_ascii=True, separators=(",", ":")),
        flush=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--open-clip", required=True, type=Path)
    parser.add_argument("--input-video", type=Path)
    parser.add_argument("--reprojected-video", type=Path)
    parser.add_argument("--mask-video", type=Path)
    parser.add_argument("--output-video", type=Path)
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--fps", type=float)
    parser.add_argument("--max-side", type=int, default=0)
    parser.add_argument("--chunk-frames", type=int, default=0)
    parser.add_argument("--overlap-frames", type=int, default=2)
    parser.add_argument("--seed", type=int, default=24062026)
    return parser.parse_args()


def validate_install(args: argparse.Namespace) -> None:
    required = [
        args.ffmpeg,
        args.repository / "LICENSE",
        args.repository / "configs" / "m2svid.yaml",
        args.repository / "m2svid" / "models_for_sgm" / "m2svid_model.py",
        args.repository / "third_party" / "Hi3D-Official" / "sgm" / "util.py",
        args.checkpoint,
        args.open_clip,
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise FileNotFoundError(
            "M2SVid is not fully installed; run INSTALL_VR_MODELS.cmd. Missing: "
            + "; ".join(missing)
        )
    if args.checkpoint.stat().st_size < 4_900_000_000:
        raise ValueError("M2SVid checkpoint is incomplete")
    if args.open_clip.stat().st_size < 3_900_000_000:
        raise ValueError("OpenCLIP ViT-H checkpoint is incomplete")


def configure_imports(args: argparse.Namespace):
    repository = args.repository.resolve()
    sys.path.insert(0, str(repository))
    sys.path.insert(0, str(repository / "third_party" / "Hi3D-Official"))
    bundled_msssim = repository / "third_party" / "pytorch-msssim"
    if bundled_msssim.is_dir():
        sys.path.insert(0, str(bundled_msssim))

    try:
        import torch
        import torch.nn.functional as functional
        from omegaconf import OmegaConf
        from sgm.util import instantiate_from_config
    except Exception as exc:  # pragma: no cover - installation diagnostic
        raise RuntimeError(
            "M2SVid Python dependencies are missing. Run INSTALL_VR_MODELS.cmd again. "
            f"Import error: {type(exc).__name__}: {exc}"
        ) from exc
    return torch, functional, OmegaConf, instantiate_from_config


def configure_cuda(torch) -> tuple[int, int]:
    if not torch.cuda.is_available():
        raise RuntimeError("M2SVid requires an NVIDIA CUDA GPU")
    torch.set_grad_enabled(False)
    torch.backends.cudnn.benchmark = True
    torch.backends.cudnn.allow_tf32 = True
    torch.backends.cuda.matmul.allow_tf32 = True
    # Keep every native PyTorch 2.x SDPA implementation available.  The
    # dispatcher selects Flash/Efficient attention when the tensor shape and
    # GPU support it, then falls back to the math kernel without requiring a
    # separately compiled Windows xFormers wheel.
    try:
        torch.backends.cuda.enable_flash_sdp(True)
        torch.backends.cuda.enable_mem_efficient_sdp(True)
        torch.backends.cuda.enable_math_sdp(True)
    except Exception:
        pass
    try:
        torch.set_float32_matmul_precision("high")
    except Exception:
        pass
    vram_mb = int(torch.cuda.get_device_properties(0).total_memory // (1024 * 1024))
    return vram_mb, int(torch.cuda.get_device_capability(0)[0])


def auto_limits(vram_mb: int, requested_side: int, requested_chunk: int) -> tuple[int, int]:
    if requested_side > 0:
        max_side = max(256, min(1024, requested_side))
    elif vram_mb < 10_000:
        max_side = 384
    elif vram_mb < 15_000:
        max_side = 512
    elif vram_mb < 22_000:
        max_side = 640
    else:
        max_side = 768

    if requested_chunk > 0:
        chunk = max(3, min(25, requested_chunk))
    elif vram_mb < 10_000:
        chunk = 6
    elif vram_mb < 15_000:
        chunk = 10
    elif vram_mb < 22_000:
        chunk = 16
    else:
        chunk = 25
    return max_side, chunk


def model_geometry(width: int, height: int, max_side: int) -> tuple[int, int, int, int, int, int]:
    scale = max_side / float(max(width, height))
    inner_width = max(64, int(round(width * scale / 2.0)) * 2)
    inner_height = max(64, int(round(height * scale / 2.0)) * 2)
    canvas_width = int(math.ceil(inner_width / 64.0) * 64)
    canvas_height = int(math.ceil(inner_height / 64.0) * 64)
    pad_x = (canvas_width - inner_width) // 2
    pad_y = (canvas_height - inner_height) // 2
    return inner_width, inner_height, canvas_width, canvas_height, pad_x, pad_y


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
        raise EOFError(f"video decoder ended after {offset} of {size} bytes")
    return bytes(target)


def start_decoder(
    ffmpeg: Path,
    path: Path,
    frames: int,
    inner_width: int,
    inner_height: int,
    canvas_width: int,
    canvas_height: int,
    pix_fmt: str,
    interpolation: str,
) -> subprocess.Popen:
    filter_graph = (
        f"scale={inner_width}:{inner_height}:flags={interpolation},"
        f"pad={canvas_width}:{canvas_height}:(ow-iw)/2:(oh-ih)/2:black,format={pix_fmt}"
    )
    command = [
        str(ffmpeg), "-nostdin", "-v", "error", "-i", str(path), "-vf", filter_graph,
        "-frames:v", str(frames), "-an", "-f", "rawvideo", "-pix_fmt", pix_fmt, "pipe:1",
    ]
    return subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )


def load_model(args: argparse.Namespace, torch, OmegaConf, instantiate_from_config):
    config = OmegaConf.load(args.repository / "configs" / "m2svid.yaml")
    config.model.params.conditioner_config.params.emb_models[0].params.open_clip_embedding_config.params.version = str(
        args.open_clip.resolve()
    )
    # Native PyTorch scaled-dot-product attention uses Flash/Efficient SDPA on
    # modern RTX cards and avoids a binary xFormers dependency on Windows.
    try:
        import xformers  # noqa: F401
        attention_backend = "xformers"
    except Exception:
        config.model.params.network_config.params.spatial_transformer_attn_type = "softmax"
        # The two conditioning encoders in the upstream YAML request
        # vanilla-xformers independently from the main UNet.  Convert those
        # to the PyTorch-2 AttnBlock too or Windows inference still reaches an
        # unavailable xFormers symbol during its first forward pass.
        for embedder in config.model.params.conditioner_config.params.emb_models:
            try:
                ddconfig = embedder.params.encoder_config.params.ddconfig
                if ddconfig.attn_type == "vanilla-xformers":
                    ddconfig.attn_type = "vanilla"
            except Exception:
                continue
        attention_backend = "torch-sdpa"
    config.model.params.network_config.params.use_checkpoint = False
    # The configured OneStepLoss is training-only, but its LPIPS branch is
    # still constructed by DiffusionEngine and downloads/keeps a 528 MB VGG16
    # network.  Preserve the harmless L2 loss object required by the class
    # while disabling image metrics that generate() never calls.
    config.model.params.loss_fn_config.params.image_loss_types = []

    # VideoLDM's constructor creates a VGG/LPIPS network solely for test-set
    # metrics. `generate()` never reads it, yet upstream inference downloads a
    # separate 528 MB VGG checkpoint and keeps the unused network in memory.
    # Replace only that metrics hook before instantiation; all generative model
    # modules and checkpoint tensors remain untouched.
    import m2svid.models_for_sgm.m2svid_model as m2svid_model

    class InferenceOnlyLPIPS(torch.nn.Module):
        def forward(self, *unused_args, **unused_kwargs):  # pragma: no cover
            raise RuntimeError("LPIPS metrics are disabled in inference mode")

    m2svid_model.LPIPS = InferenceOnlyLPIPS

    previous = Path.cwd()
    os.chdir(args.repository)
    try:
        model = instantiate_from_config(config.model).cpu()
        try:
            checkpoint = torch.load(
                args.checkpoint.resolve(), map_location="cpu", weights_only=True, mmap=True
            )
        except (TypeError, RuntimeError):
            checkpoint = torch.load(
                args.checkpoint.resolve(), map_location="cpu", weights_only=True
            )
        raw_state = checkpoint.get("module", checkpoint)
        generation_state = {}
        skipped_metrics = 0
        for raw_name, value in raw_state.items():
            name = raw_name[len("module."):] if raw_name.startswith("module.") else raw_name
            if name.startswith("loss_fn.lpips."):
                skipped_metrics += 1
                continue
            generation_state[name] = value
        missing, unexpected = model.load_state_dict(generation_state, strict=False)
        if missing or unexpected:
            raise RuntimeError(
                "M2SVid generation checkpoint does not match the pinned source: "
                f"missing={missing[:8]}, unexpected={unexpected[:8]}"
            )
        del generation_state, raw_state, checkpoint
        gc.collect()
        emit("STATUS", stage="weights-loaded", skipped_training_metrics=skipped_metrics)
    finally:
        os.chdir(previous)
    model.requires_grad_(False)
    # Cast on the host first.  `.cuda().half()` briefly materializes the
    # complete FP32 network in VRAM and can OOM on an 8 GB laptop even though
    # the actual FP16 model fits.
    model = model.half().cuda().eval()
    emit("STATUS", stage="model-ready", attention=attention_backend)
    return model, attention_backend


def close_process(process: subprocess.Popen, name: str, timeout: int = 120) -> None:
    if process.stdout is not None:
        process.stdout.close()
    process.wait(timeout=timeout)
    if process.returncode != 0:
        details = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
        raise RuntimeError(f"{name} failed: {details.strip()}")


def main() -> int:
    args = parse_args()
    validate_install(args)
    torch, functional, OmegaConf, instantiate_from_config = configure_imports(args)
    if args.check:
        emit("STATUS", stage="installation-ready", repository=str(args.repository))
        return 0

    for name in ("input_video", "reprojected_video", "mask_video", "output_video"):
        if getattr(args, name) is None:
            raise ValueError(f"--{name.replace('_', '-')} is required")
    if not args.width or not args.height or not args.frames or not args.fps:
        raise ValueError("--width, --height, --frames and --fps must be positive")

    vram_mb, compute_major = configure_cuda(torch)
    max_side, chunk_frames = auto_limits(vram_mb, args.max_side, args.chunk_frames)
    overlap = max(0, min(8, args.overlap_frames, chunk_frames - 2))
    geometry = model_geometry(args.width, args.height, max_side)
    inner_width, inner_height, canvas_width, canvas_height, pad_x, pad_y = geometry
    emit(
        "STATUS",
        stage="initializing",
        gpu=torch.cuda.get_device_name(0),
        vram_mb=vram_mb,
        compute_major=compute_major,
        model_canvas=f"{canvas_width}x{canvas_height}",
        model_content=f"{inner_width}x{inner_height}",
        chunk_frames=chunk_frames,
        overlap_frames=overlap,
    )

    model, attention_backend = load_model(args, torch, OmegaConf, instantiate_from_config)
    left_decoder = start_decoder(
        args.ffmpeg, args.input_video, args.frames, inner_width, inner_height,
        canvas_width, canvas_height, "rgb24", "lanczos",
    )
    seed_decoder = start_decoder(
        args.ffmpeg, args.reprojected_video, args.frames, inner_width, inner_height,
        canvas_width, canvas_height, "rgb24", "lanczos",
    )
    mask_decoder = start_decoder(
        args.ffmpeg, args.mask_video, args.frames, inner_width, inner_height,
        canvas_width, canvas_height, "gray", "neighbor",
    )
    if not left_decoder.stdout or not seed_decoder.stdout or not mask_decoder.stdout:
        raise RuntimeError("could not start M2SVid input decoders")

    encoder_command = [
        str(args.ffmpeg), "-y", "-nostdin", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s:v", f"{canvas_width}x{canvas_height}",
        "-r", f"{args.fps:.9g}", "-i", "pipe:0",
        "-vf", f"crop={inner_width}:{inner_height}:{pad_x}:{pad_y}",
        "-an", "-c:v", "ffv1", "-level", "3", "-coder", "1", "-context", "1",
        "-pix_fmt", "bgr0", "-frames:v", str(args.frames), str(args.output_video),
    ]
    encoder = subprocess.Popen(
        encoder_command,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if encoder.stdin is None:
        raise RuntimeError("could not start M2SVid output encoder")

    rgb_bytes = canvas_width * canvas_height * 3
    mask_bytes = canvas_width * canvas_height

    def read_frames(count: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        left = np.empty((count, canvas_height, canvas_width, 3), dtype=np.uint8)
        seed = np.empty_like(left)
        mask = np.empty((count, canvas_height, canvas_width), dtype=np.uint8)
        for index in range(count):
            left[index] = np.frombuffer(read_exact(left_decoder.stdout, rgb_bytes), np.uint8).reshape(
                canvas_height, canvas_width, 3
            )
            seed[index] = np.frombuffer(read_exact(seed_decoder.stdout, rgb_bytes), np.uint8).reshape(
                canvas_height, canvas_width, 3
            )
            mask[index] = np.frombuffer(read_exact(mask_decoder.stdout, mask_bytes), np.uint8).reshape(
                canvas_height, canvas_width
            )
        return left, seed, mask

    def infer_chunk(left_np: np.ndarray, seed_np: np.ndarray, mask_np: np.ndarray, chunk_index: int) -> np.ndarray:
        torch.manual_seed(args.seed + chunk_index)
        torch.cuda.manual_seed_all(args.seed + chunk_index)
        left = torch.from_numpy(left_np).cuda(non_blocking=False).permute(3, 0, 1, 2).float().div_(127.5).sub_(1.0)
        seed = torch.from_numpy(seed_np).cuda(non_blocking=False).permute(3, 0, 1, 2).float().div_(255.0)
        mask = torch.from_numpy(mask_np).cuda(non_blocking=False)[:, None].float().div_(255.0)
        mask = (mask > 0.35).float()
        # Match the official closing + dilation preprocessing without a CPU
        # OpenCV roundtrip.  Contiguous masks make the full-attention tokens
        # focus on actual disocclusions instead of isolated depth noise.
        closing_kernel = 7
        dilated = functional.max_pool2d(mask, closing_kernel, stride=1, padding=closing_kernel // 2)
        mask = -functional.max_pool2d(-dilated, closing_kernel, stride=1, padding=closing_kernel // 2)
        mask = functional.max_pool2d(mask, 3, stride=1, padding=1).clamp_(0.0, 1.0)
        seed = seed.masked_fill(mask.permute(1, 0, 2, 3).expand_as(seed) > 0.5, 0.0)
        seed = seed.mul_(2.0).sub_(1.0)
        latent_mask = functional.interpolate(
            mask, size=(canvas_height // 8, canvas_width // 8), mode="nearest"
        )
        latent_mask = latent_mask.permute(1, 0, 2, 3).mul_(2.0).sub_(1.0)
        batch = {
            "video": left[None],
            "video_2nd_view": left[None],
            "reprojected_video": seed[None],
            "reprojected_mask": latent_mask[None],
            "fps_id": torch.tensor([int(round(args.fps))], device="cuda"),
            "caption": [""],
            "motion_bucket_id": torch.tensor([127], device="cuda"),
        }
        try:
            with torch.inference_mode(), torch.autocast(device_type="cuda", dtype=torch.float16):
                generated = model.generate(batch)["generated-video"][0]
            result = (
                generated.detach().float().add_(1.0).mul_(127.5).clamp_(0, 255)
                .byte().permute(1, 2, 3, 0).cpu().numpy()
            )
        except torch.OutOfMemoryError as exc:
            torch.cuda.empty_cache()
            raise RuntimeError(
                f"M2SVid ran out of VRAM at {canvas_width}x{canvas_height} / {len(left_np)} frames. "
                "Choose a smaller generative resolution or chunk size."
            ) from exc
        finally:
            del batch, left, seed, mask, latent_mask
        return result

    def write_frames(frames: np.ndarray) -> None:
        encoder.stdin.write(memoryview(np.ascontiguousarray(frames)).cast("B"))

    started = time.perf_counter()
    processed = 0
    consumed = 0
    chunk_index = 0
    pending_generated: np.ndarray | None = None
    tail_inputs: tuple[np.ndarray, np.ndarray, np.ndarray] | None = None
    try:
        first_count = min(chunk_frames, args.frames)
        current = read_frames(first_count)
        consumed = first_count
        while True:
            generated = infer_chunk(*current, chunk_index)
            is_last = consumed >= args.frames
            if pending_generated is None:
                if is_last or overlap == 0:
                    ready = generated
                    pending_generated = None
                else:
                    ready = generated[:-overlap]
                    pending_generated = generated[-overlap:].copy()
            else:
                overlap_count = min(overlap, len(pending_generated), len(generated))
                weights = np.linspace(0.25, 0.75, overlap_count, dtype=np.float32)[:, None, None, None]
                blended = (
                    pending_generated[-overlap_count:].astype(np.float32) * (1.0 - weights)
                    + generated[:overlap_count].astype(np.float32) * weights
                ).clip(0, 255).astype(np.uint8)
                if is_last:
                    ready = np.concatenate((blended, generated[overlap_count:]), axis=0)
                    pending_generated = None
                else:
                    keep_start = len(generated) - overlap
                    ready = np.concatenate((blended, generated[overlap_count:keep_start]), axis=0)
                    pending_generated = generated[keep_start:].copy()
            if len(ready):
                write_frames(ready)
                processed += len(ready)
            elapsed = time.perf_counter() - started
            emit(
                "PROGRESS",
                frames=processed,
                total=args.frames,
                chunks=chunk_index + 1,
                fps=processed / max(elapsed, 1.0e-6),
                model_canvas=f"{canvas_width}x{canvas_height}",
            )
            if is_last:
                break
            if overlap:
                tail_inputs = tuple(part[-overlap:].copy() for part in current)
            new_count = min(chunk_frames - overlap, args.frames - consumed)
            new_frames = read_frames(new_count)
            consumed += new_count
            if overlap and tail_inputs is not None:
                current = tuple(
                    np.concatenate((tail, fresh), axis=0)
                    for tail, fresh in zip(tail_inputs, new_frames)
                )
            else:
                current = new_frames
            chunk_index += 1
    finally:
        encoder.stdin.close()

    close_process(left_decoder, "left-eye decoder")
    close_process(seed_decoder, "right-eye seed decoder")
    close_process(mask_decoder, "disocclusion-mask decoder")
    encoder.wait(timeout=300)
    if encoder.returncode != 0:
        details = encoder.stderr.read().decode("utf-8", errors="replace") if encoder.stderr else ""
        raise RuntimeError("M2SVid output encoder failed: " + details.strip())
    if processed != args.frames:
        raise RuntimeError(f"M2SVid produced {processed} frames, expected {args.frames}")
    elapsed = time.perf_counter() - started
    emit(
        "DONE",
        frames=processed,
        elapsed_s=elapsed,
        fps=processed / max(elapsed, 1.0e-6),
        attention=attention_backend,
        model_canvas=f"{canvas_width}x{canvas_height}",
        output=str(args.output_video),
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        emit("ERROR", type=type(exc).__name__, message=str(exc))
        raise
