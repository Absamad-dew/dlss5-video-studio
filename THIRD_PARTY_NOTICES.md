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
