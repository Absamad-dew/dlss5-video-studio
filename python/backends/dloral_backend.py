"""DLoRAL one-step dual-LoRA adapter with temporal pair reuse and tiled VAE."""

from __future__ import annotations

import sys
import types
import json
from pathlib import Path

import numpy as np


def install_openmmlab_compat(torch, local_spynet: Path | None = None) -> None:
    """Provide the small MMCV/MMEngine surface DLoRAL needs on Windows.

    The original mmcv-full wheel is tied to old PyTorch/CUDA builds.  Current
    torchvision exposes the same modulated deform-convolution primitive.
    """
    from torch import nn
    from torchvision.ops import deform_conv2d

    class BaseModule(nn.Module):
        def __init__(self, *args, **kwargs):
            super().__init__()

    class ConvModule(nn.Module):
        def __init__(self, in_channels, out_channels, kernel_size, stride=1, padding=0,
                     dilation=1, groups=1, bias=True, norm_cfg=None, act_cfg=None, **kwargs):
            super().__init__()
            # Match MMCV's public submodule name so official SPyNet state
            # dict keys remain `...conv.weight` rather than `...0.weight`.
            self.conv = nn.Conv2d(in_channels, out_channels, kernel_size, stride, padding,
                                  dilation=dilation, groups=groups, bias=bias)
            self.activate = None
            if act_cfg:
                self.activate = nn.ReLU(inplace=True) if act_cfg.get("type") == "ReLU" else nn.LeakyReLU(0.1, True)

        def forward(self, x):
            x = self.conv(x)
            return self.activate(x) if self.activate is not None else x

    class ModulatedDeformConv2d(nn.Conv2d):
        def __init__(self, *args, deform_groups=1, **kwargs):
            if kwargs.get("bias") == "auto":
                kwargs["bias"] = True
            super().__init__(*args, **kwargs)
            self.deform_groups = deform_groups

    def modulated(input, offset, mask, weight, bias, stride, padding, dilation, groups=1, deform_groups=1):
        return deform_conv2d(input, offset, weight, bias, stride, padding, dilation, mask)

    def constant_init(target, val=0, bias=0):
        if isinstance(target, torch.Tensor):
            nn.init.constant_(target, val)
            return
        if getattr(target, "weight", None) is not None:
            nn.init.constant_(target.weight, val)
        if getattr(target, "bias", None) is not None:
            nn.init.constant_(target.bias, bias)

    def load_checkpoint(module, filename, strict=False, logger=None, **kwargs):
        if str(filename).startswith(("http://", "https://")):
            if local_spynet is not None and local_spynet.is_file():
                payload = torch.load(local_spynet, map_location="cpu", weights_only=True)
            else:
                payload = torch.hub.load_state_dict_from_url(str(filename), map_location="cpu", progress=False)
        else:
            payload = torch.load(filename, map_location="cpu", weights_only=True)
        state = payload.get("state_dict", payload) if isinstance(payload, dict) else payload
        module.load_state_dict(state, strict=strict)
        return payload

    class MMLogger:
        @staticmethod
        def get_current_instance():
            return None

    mmcv = types.ModuleType("mmcv")
    mmcv_ops = types.ModuleType("mmcv.ops")
    mmcv_cnn = types.ModuleType("mmcv.cnn")
    mmcv_ops.ModulatedDeformConv2d = ModulatedDeformConv2d
    mmcv_ops.modulated_deform_conv2d = modulated
    mmcv_cnn.ConvModule = ConvModule
    mmengine = types.ModuleType("mmengine")
    mmengine_model = types.ModuleType("mmengine.model")
    mmengine_runner = types.ModuleType("mmengine.runner")
    mmengine_weight = types.ModuleType("mmengine.model.weight_init")
    mmengine_model.BaseModule = BaseModule
    mmengine_runner.load_checkpoint = load_checkpoint
    mmengine_weight.constant_init = constant_init
    mmengine.MMLogger = MMLogger
    mmengine.print_log = lambda *a, **k: None
    for name, module in {
        "mmcv": mmcv, "mmcv.ops": mmcv_ops, "mmcv.cnn": mmcv_cnn,
        "mmengine": mmengine, "mmengine.model": mmengine_model,
        "mmengine.runner": mmengine_runner, "mmengine.model.weight_init": mmengine_weight,
    }.items():
        sys.modules[name] = module


class Backend:
    scale = 4

    def __init__(self, args, torch, vram_mb: int) -> None:
        source = args.third_party_root / "DLoRAL"
        weights = args.model_root / "dloral"
        checkpoint = weights / "model.pkl"
        sd21 = weights / "stable-diffusion-2-1-base"
        spynet = weights / "spynet_20210409-c6c1bd09.pth"
        missing = [str(path) for path in (source, checkpoint, sd21) if not path.exists()]
        if missing:
            raise FileNotFoundError("DLoRAL files are missing: " + ", ".join(missing))
        sys.path.insert(0, str(source))

        print(
            "UPSCALER_STATUS "
            + json.dumps({"stage": "dloral-runtime", "message": "DLoRAL: preparing SDPA and tiled VAE runtime"}),
            flush=True,
        )
        install_openmmlab_compat(torch, spynet)

        # The original 2025 code requires xFormers 0.0.20.  Current PyTorch
        # uses fused SDPA on Ada/Blackwell, so the old hook is intentionally a
        # no-op and avoids pinning the portable build to an obsolete wheel.
        from diffusers import AutoencoderKL, UNet2DConditionModel
        from transformers import CLIPTextModel
        original_unet_loader = UNet2DConditionModel.from_pretrained
        original_vae_loader = AutoencoderKL.from_pretrained
        original_text_loader = CLIPTextModel.from_pretrained

        def fp16_loader(original):
            def load(_cls, *loader_args, **loader_kwargs):
                loader_kwargs.setdefault("variant", "fp16")
                loader_kwargs.setdefault("torch_dtype", torch.float16)
                return original(*loader_args, **loader_kwargs)
            return classmethod(load)

        UNet2DConditionModel.from_pretrained = fp16_loader(original_unet_loader)
        AutoencoderKL.from_pretrained = fp16_loader(original_vae_loader)
        CLIPTextModel.from_pretrained = fp16_loader(original_text_loader)
        UNet2DConditionModel.enable_xformers_memory_efficient_attention = lambda self, *a, **k: None
        from src import DLoRAL_model as dloral_model
        Generator_eval = dloral_model.Generator_eval
        from src.my_utils import vaehook

        class QuietProgress:
            def __init__(self, *progress_args, **progress_kwargs):
                pass

            def update(self, *progress_args, **progress_kwargs):
                pass

            def close(self):
                pass

        # The Studio owns progress reporting.  Letting tqdm write hundreds of
        # carriage-return updates to redirected stderr can fill the Windows
        # pipe and block the worker before its protocol reply.
        vaehook.tqdm = QuietProgress

        tile = 64 if vram_mb < 12000 else 96
        options = types.SimpleNamespace(
            pretrained_path=str(checkpoint), pretrained_model_path=str(sd21),
            pretrained_model_name_or_path=str(sd21),
            vae_encoder_tiled_size=768 if vram_mb < 12000 else 1024,
            vae_decoder_tiled_size=192 if vram_mb < 12000 else 256,
            latent_tiled_size=tile, latent_tiled_overlap=max(16, tile // 3),
            merge_and_unload_lora=False, load_cfr=True,
        )
        # Keep PyTorch's restricted checkpoint loader explicit.  The verified
        # checkpoint contains only tensors, OrderedDicts and primitive LoRA
        # metadata, so arbitrary pickle globals are neither required nor run.
        original_torch_load = torch.load
        def dloral_load(*load_args, **load_kwargs):
            load_kwargs.setdefault("weights_only", True)
            return original_torch_load(*load_args, **load_kwargs)
        torch.load = dloral_load
        try:
            print(
                "UPSCALER_STATUS "
                + json.dumps({"stage": "dloral-weights", "message": "DLoRAL: loading SD 2.1 and Dual-LoRA weights"}),
                flush=True,
            )
            model = Generator_eval(options)
        finally:
            torch.load = original_torch_load
        model.set_eval()
        self.dtype = torch.float16
        model.vae.to(dtype=self.dtype)
        model.unet.to(dtype=self.dtype)
        model.cfr_main_net.to(dtype=self.dtype)
        model.text_encoder.to(dtype=self.dtype)
        prompt = "high quality, highly detailed, sharp, natural texture"
        prompt_embedding = model.encode_prompt([prompt]).to(dtype=self.dtype)
        model.encode_prompt = lambda _batch: prompt_embedding
        model.text_encoder.to("cpu")
        torch.cuda.empty_cache()
        variant = args.variant
        if variant == "auto":
            variant = "balanced" if vram_mb < 10000 else "quality"
        stage = 0 if variant in ("realtime", "balanced") else 1
        consistency_adapters = [
            "default_encoder_consistency", "default_decoder_consistency", "default_others_consistency"
        ]
        quality_adapters = [
            "default_encoder_quality", "default_decoder_quality", "default_others_quality"
        ]
        active_adapters = consistency_adapters if stage == 0 else quality_adapters + consistency_adapters

        # DLoRAL's paper inference path merges the selected C-LoRA/D-LoRA into
        # the frozen UNet.  Keeping six live PEFT branches wastes VRAM and adds
        # adapter dispatch to every tile.  Fuse once, then remove the branches.
        print(
            "UPSCALER_STATUS "
            + json.dumps({"stage": "dloral-fuse", "message": "DLoRAL: fusing active Dual-LoRA adapters"}),
            flush=True,
        )
        dloral_model.set_weights_and_activate_adapters(
            model.unet, active_adapters, [1.0] * len(active_adapters)
        )
        from peft.tuners.tuners_utils import BaseTunerLayer
        for module in model.unet.modules():
            if isinstance(module, BaseTunerLayer):
                module.merge(safe_merge=False, adapter_names=active_adapters)
        from diffusers.utils import recurse_remove_peft_layers
        recurse_remove_peft_layers(model.unet)
        if hasattr(model.unet, "peft_config"):
            del model.unet.peft_config
        dloral_model.set_weights_and_activate_adapters = lambda *_args, **_kwargs: None
        torch.cuda.empty_cache()
        self.model = model
        self.torch = torch
        self.stage = stage
        self.previous = None
        self.target_height = args.output_height
        self.target_width = args.output_width
        # CFR requires at least 64x64 after its internal 1/8 reduction and
        # SD's VAE is happiest on multiples of eight.  Align only inside the
        # diffusion backend; the worker crops back to the exact UI geometry.
        self.height = max(512, ((args.output_height + 7) // 8) * 8)
        self.width = max(512, ((args.output_width + 7) // 8) * 8)
        self.strength = args.strength
        self.variant = f"dual-lora-stage{stage}-{variant}-fused-sdpa-fp16-tile{tile}"

    def process(self, frames: np.ndarray) -> np.ndarray:
        torch = self.torch
        host = torch.from_numpy(
            np.ascontiguousarray(frames.transpose(0, 3, 1, 2))
        ).pin_memory()
        outputs = []
        for index in range(host.shape[0]):
            current = host[index : index + 1].to(
                "cuda", dtype=self.dtype, non_blocking=True
            ).div_(255.0)
            current = torch.nn.functional.interpolate(
                current, size=(self.height, self.width), mode="bicubic", align_corners=False
            ).clamp_(0, 1)
            previous = current if self.previous is None else self.previous.to(
                "cuda", dtype=self.dtype, non_blocking=True
            )
            pair = torch.stack((previous[0], current[0]), dim=0).unsqueeze(0)
            gray = pair.mean(dim=2)
            gray = torch.nn.functional.interpolate(
                gray.flatten(0, 1).unsqueeze(1), scale_factor=0.125, mode="bilinear", align_corners=False
            ).reshape(1, 2, 1, self.height // 8, self.width // 8)
            variance = gray.var(dim=1, unbiased=False)
            threshold = variance.mean()
            mask = (variance >= threshold).to(dtype=self.dtype).unsqueeze(1)
            generated, _, _, _, _ = self.model(
                stages=self.stage, c_t=pair.mul(2).sub(1), uncertainty_map=mask,
                prompt="", weight_dtype=self.dtype,
            )
            restored = generated.float().add(1).mul(0.5).clamp(0, 1)
            if self.strength < 0.999:
                restored = torch.lerp(current.float(), restored, self.strength)
            outputs.append(restored[:, :, : self.target_height, : self.target_width].cpu())
            self.previous = current.detach().cpu().pin_memory()
            del pair, gray, variance, mask, generated, restored, previous, current
        torch.cuda.empty_cache()
        output = torch.cat(outputs, dim=0)
        return (
            output.mul(255).round().to(torch.uint8).permute(0, 2, 3, 1)
            .contiguous().cpu().numpy()
        )
