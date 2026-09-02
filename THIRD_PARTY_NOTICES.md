# Third-party notices

This source tree integrates or can download components including NVIDIA Streamline, NVIDIA NGX, ReShade, RenoDX, FFmpeg, yt-dlp, PyTorch/Torchvision, RAFT, ONNX Runtime, OpenCV, NumPy, Depth Anything V2, Video Depth Anything, and Depth Anything 3.

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
# M2SVid

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
