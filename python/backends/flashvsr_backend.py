"""FlashVSR v1.1 adapter using Sparse-Sage LCSA for Windows RTX GPUs.

The Sparse-Sage implementation preserves locality-constrained sparse attention,
supports SM 8.9/12.x, and avoids the low-quality dense-attention fallback.
"""

from __future__ import annotations

import math
import json
import sys

import numpy as np


class Backend:
    scale = 4

    def __init__(self, args, torch, vram_mb: int) -> None:
        source = args.third_party_root / "FlashVSR_Ultra_Fast"
        if not source.is_dir():
            source = args.third_party_root / "ComfyUI-FlashVSR_Ultra_Fast"
        weights = args.model_root / "flashvsr-v1.1"
        required = [
            weights / "diffusion_pytorch_model_streaming_dmd.safetensors",
            weights / "LQ_proj_in.ckpt",
            weights / "TCDecoder.ckpt",
            source / "posi_prompt.pth",
        ]
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise FileNotFoundError("FlashVSR v1.1 files are missing: " + ", ".join(missing))
        sys.path.insert(0, str(source))
        print(
            "UPSCALER_STATUS "
            + json.dumps({"stage": "flash-import", "message": "FlashVSR: loading Sparse-Sage runtime"}),
            flush=True,
        )
        try:
            from src import ModelManager, FlashVSRTinyLongPipeline
            from src.models.TCDecoder import build_tcdecoder
            from src.models.utils import Causal_LQ4x_Proj
            from src.models import wan_video_dit
        except (ImportError, ModuleNotFoundError) as exc:
            raise RuntimeError(
                "FlashVSR Sparse-Sage runtime is incomplete. Run INSTALL_MODELS.cmd once."
            ) from exc

        wan_video_dit.USE_BLOCK_ATTN = False
        dtype = torch.bfloat16
        print(
            "UPSCALER_STATUS "
            + json.dumps({"stage": "flash-weights", "message": "FlashVSR: reading v1.1 BF16 weights"}),
            flush=True,
        )
        manager = ModelManager(torch_dtype=dtype, device="cpu")
        manager.load_models([str(required[0])])
        pipe = FlashVSRTinyLongPipeline.from_model_manager(manager, device="cuda:0")
        pipe.TCDecoder = build_tcdecoder(
            new_channels=[512, 256, 128, 128], device="cuda:0", dtype=dtype,
            new_latent_channels=784,
        )
        pipe.TCDecoder.load_state_dict(
            torch.load(required[2], map_location="cpu", weights_only=True), strict=False
        )
        pipe.TCDecoder.clean_mem()
        pipe.denoising_model().LQ_proj_in = Causal_LQ4x_Proj(
            in_dim=3, out_dim=1536, layer_num=1
        ).to("cuda:0", dtype=dtype)
        pipe.denoising_model().LQ_proj_in.load_state_dict(
            torch.load(required[1], map_location="cpu", weights_only=True), strict=True
        )
        pipe.to("cuda:0", dtype=dtype)
        # Keep the model persistent for the complete video.  Per-chunk CPU
        # offload made an 8 GB GPU look hung because several GB were copied
        # again before every chunk; spatial tiles already cap activation VRAM.
        pipe.enable_vram_management(num_persistent_param_in_dit=None)
        print(
            "UPSCALER_STATUS "
            + json.dumps({"stage": "flash-cache", "message": "FlashVSR: preparing prompt and sparse-attention cache"}),
            flush=True,
        )
        pipe.init_cross_kv(prompt_path=str(required[3]))
        pipe.load_models_to_device(["dit", "vae"])
        pipe.offload_model()

        self.pipe = pipe
        self.torch = torch
        self.dtype = dtype
        self.input_height = args.input_height
        self.input_width = args.input_width
        self.height = args.output_height
        self.width = args.output_width
        self.strength = args.strength
        variant = args.variant
        if variant == "auto":
            variant = "balanced" if vram_mb < 12000 else "quality"
        self.local_range = 9 if variant in ("realtime", "quality") else 11
        self.sparse_ratio = 1.5 if variant in ("realtime", "balanced") else 2.0
        self.kv_ratio = 1.0 if variant == "realtime" else (2.0 if variant == "balanced" else 3.0)
        self.color_fix = variant in ("quality", "max")
        self.unload_intermediates = vram_mb < 12000
        self.low_vram = vram_mb < 12000
        self.tile_size = 128 if self.low_vram else (192 if variant in ("realtime", "balanced") else 256)
        self.tile_overlap = max(16, self.tile_size // 8)
        self._feather_cache = {}
        self.variant = (
            f"v1.1-tiny-long-sparse-sage-{variant}-tile{self.tile_size}"
            f"-s{self.sparse_ratio:g}-kv{self.kv_ratio:g}-r{self.local_range}"
        )

    @staticmethod
    def padded_count(count: int) -> int:
        return max(25, int(math.ceil((count + 3) / 8.0)) * 8 + 1)

    @staticmethod
    def tile_starts(length: int, tile: int, overlap: int) -> list[int]:
        if length <= tile:
            return [0]
        stride = tile - overlap
        starts = list(range(0, max(1, length - tile + 1), stride))
        final = length - tile
        if starts[-1] != final:
            starts.append(final)
        return starts

    def feather(self, height: int, width: int, x1: int, y1: int, x2: int, y2: int):
        torch = self.torch
        key = (height, width, x1 > 0, x2 < self.input_width, y1 > 0, y2 < self.input_height)
        cached = self._feather_cache.get(key)
        if cached is not None:
            return cached
        overlap = self.tile_overlap * 4
        mask = torch.ones((1, height, width, 1), dtype=torch.float16)
        if x1 > 0:
            mask[:, :, :overlap, :] *= torch.linspace(0, 1, overlap).view(1, 1, -1, 1)
        if x2 < self.input_width:
            mask[:, :, -overlap:, :] *= torch.linspace(1, 0, overlap).view(1, 1, -1, 1)
        if y1 > 0:
            mask[:, :overlap, :, :] *= torch.linspace(0, 1, overlap).view(1, -1, 1, 1)
        if y2 < self.input_height:
            mask[:, -overlap:, :, :] *= torch.linspace(1, 0, overlap).view(1, -1, 1, 1)
        self._feather_cache[key] = mask
        return mask

    def run_tile(self, frames, count: int):
        torch = self.torch
        padded = self.padded_count(count)
        if padded > count:
            frames = torch.cat((frames, frames[-1:].expand(padded - count, -1, -1, -1)), dim=0)
        high = torch.nn.functional.interpolate(
            frames.to("cuda:0", dtype=torch.float32, non_blocking=True), scale_factor=4,
            mode="bicubic", align_corners=False,
        ).clamp_(0, 1)
        target_height, target_width = int(high.shape[-2]), int(high.shape[-1])
        # Wan's patch embed divides by 16 and Sparse-Sage partitions the
        # resulting latent grid into 8x8 windows.  The pixel-domain tile must
        # therefore be a multiple of 128, not merely 16.
        pad_h = (-target_height) % 128
        pad_w = (-target_width) % 128
        if pad_h or pad_w:
            high = torch.nn.functional.pad(high, (0, pad_w, 0, pad_h), mode="replicate")
        height, width = int(high.shape[-2]), int(high.shape[-1])
        lq = high.mul(2).sub(1).to(self.dtype).permute(1, 0, 2, 3).unsqueeze(0).cpu()
        del high
        video = self.pipe(
            prompt="", negative_prompt="", cfg_scale=1.0, num_inference_steps=1, seed=0,
            tiled=True, LQ_video=lq, num_frames=padded, height=height, width=width,
            is_full_block=False, if_buffer=True,
            progress_bar_cmd=lambda iterable: iterable,
            topk_ratio=self.sparse_ratio * 768 * 1280 / (height * width),
            kv_ratio=self.kv_ratio, local_range=self.local_range, color_fix=self.color_fix,
            unload_dit=self.unload_intermediates, force_offload=False,
        )
        restored = video[:, :count].permute(1, 2, 3, 0).float().add(1).mul(0.5).clamp(0, 1)
        return restored[:, :target_height, :target_width].cpu()

    def process(self, frames: np.ndarray) -> np.ndarray:
        torch = self.torch
        count = int(frames.shape[0])
        source = (
            torch.from_numpy(np.ascontiguousarray(frames.transpose(0, 3, 1, 2)))
            .pin_memory().float().div_(255.0)
        )
        xs = self.tile_starts(self.input_width, self.tile_size, self.tile_overlap)
        ys = self.tile_starts(self.input_height, self.tile_size, self.tile_overlap)
        canvas = torch.zeros((count, self.height, self.width, 3), dtype=torch.float16)
        weights = torch.zeros((1, self.height, self.width, 1), dtype=torch.float16)
        for y1 in ys:
            for x1 in xs:
                y2 = min(self.input_height, y1 + self.tile_size)
                x2 = min(self.input_width, x1 + self.tile_size)
                tile = source[:, :, y1:y2, x1:x2]
                restored = self.run_tile(tile, count).to(torch.float16)
                oh, ow = restored.shape[1:3]
                oy, ox = y1 * 4, x1 * 4
                mask = self.feather(oh, ow, x1, y1, x2, y2)
                canvas[:, oy:oy + oh, ox:ox + ow] += restored * mask
                weights[:, oy:oy + oh, ox:ox + ow] += mask
                del restored, tile
                if self.low_vram:
                    # On an 8 GB card the next spatial tile otherwise starts
                    # with ~7.7 GB still reserved and Windows begins paging GPU
                    # allocations.  That is far slower than this synchronization.
                    torch.cuda.empty_cache()
        torch.cuda.empty_cache()
        output = canvas.float().div(weights.clamp_min(1e-4).float()).clamp(0, 1)
        if self.strength < 0.999:
            base = torch.nn.functional.interpolate(
                source, size=(self.height, self.width), mode="bicubic", align_corners=False
            ).permute(0, 2, 3, 1).clamp(0, 1)
            output = torch.lerp(base, output, self.strength)
        return output.mul(255).round().to(torch.uint8).contiguous().numpy()
