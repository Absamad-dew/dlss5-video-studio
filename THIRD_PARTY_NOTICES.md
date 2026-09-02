# Third-party notices

This source tree integrates or can download components including NVIDIA Streamline, NVIDIA NGX, ReShade, RenoDX, FFmpeg, yt-dlp, PyTorch/Torchvision, RAFT, ONNX Runtime, OpenCV, NumPy, Depth Anything V2, Video Depth Anything, Depth Anything 3, and MI-GAN.

Each component remains subject to its upstream license. The installers download open model checkpoints from their official upstream projects. Proprietary NVIDIA runtimes and the user's custom neural-rendering DLL are deliberately excluded from this repository.

Relevant upstream projects:

- NVIDIA Streamline: https://github.com/NVIDIA-RTX/Streamline
- ReShade: https://github.com/crosire/reshade
- RenoDX: https://github.com/clshortfuse/renodx
- Depth Anything V2: https://github.com/DepthAnything/Depth-Anything-V2
- Video Depth Anything: https://github.com/DepthAnything/Video-Depth-Anything
- Depth Anything 3: https://github.com/ByteDance-Seed/Depth-Anything-3
- Torchvision RAFT: https://github.com/pytorch/vision
- FFmpeg: https://github.com/FFmpeg/FFmpeg
- yt-dlp: https://github.com/yt-dlp/yt-dlp

## Core model pack

- Depth Anything V2 Small: Apache-2.0; https://github.com/DepthAnything/Depth-Anything-V2
- Depth Anything 3 Small: Apache-2.0; https://huggingface.co/depth-anything/DA3-SMALL
- TorchVision RAFT Small C_T_V2: BSD-3-Clause code distribution; https://docs.pytorch.org/vision/main/models/generated/torchvision.models.optical_flow.raft_small.html

The release archive carries local copies of the applicable license texts. Dataset-derived restrictions, if any, remain the responsibility of the user as described by the upstream TorchVision documentation.

# MI-GAN (Temporal Atlas residual inpainting)

Temporal Atlas uses the official pre-converted MI-GAN-512 Places2 ONNX pipeline only on residual disocclusion regions after multi-frame reprojection. The upstream repository is MIT-licensed and documents this ONNX pipeline, including its uint8 image/mask interface and arbitrary-resolution crop/resize/composite behavior.

- Project: https://github.com/Picsart-AI-Research/MI-GAN
- ONNX pipeline: https://huggingface.co/andraniksargsyan/migan/blob/main/migan_pipeline_v2.onnx
- Repository license: MIT
- Local license: `licenses/vr/MI-GAN-MIT.txt`

The Hugging Face model repository does not currently carry separate license metadata for the weights. Redistribution and commercial use of the checkpoint should therefore be checked against the current upstream terms; the standard installer downloads the checkpoint directly from its upstream author-owned repository.

# Moebius and PixelHacker VAE

The optional experimental sparse generative VR backend uses the official HUST-VL Moebius source and Places2 checkpoint, pinned by the installer to commit `b88d462bacb9af6e7128a3b4cc4a07418bedfd61`, together with the official PixelHacker VAE. The installer disables one unused eager teacher import in `model_lib/__init__.py`; the installed file carries a modification notice. The inference architecture and checkpoint are otherwise loaded through the upstream pipeline.

- Moebius project: https://github.com/hustvl/Moebius
- PixelHacker project: https://github.com/hustvl/PixelHacker
- License: Apache License 2.0
- Local licenses after installation: `licenses/vr/Moebius-Apache-2.0.txt` and `licenses/vr/PixelHacker-Apache-2.0.txt`
# M2SVid (experimental)

Optional generative VR inference uses the official Google Research M2SVid source and checkpoint, pinned by the installer to commit `11b0133093d6abfcc6ff953890edf05457975318`.

- Project: https://github.com/google-research/m2svid
- License: Apache License 2.0
- Local license after installation: `licenses/vr/M2SVid-Apache-2.0.txt`

# OpenCLIP

M2SVid conditioning uses the LAION OpenCLIP ViT-H-14 checkpoint through OpenCLIP.

- Project: https://github.com/mlfoundations/open_clip
- Checkpoint: https://huggingface.co/laion/CLIP-ViT-H-14-laion2B-s32B-b79K
- License: MIT
- Local license after installation: `licenses/vr/OpenCLIP-MIT.txt`
