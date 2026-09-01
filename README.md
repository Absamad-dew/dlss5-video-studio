# DLSS5 Video Studio V11

Windows video player/processor that reconstructs motion and depth from ordinary video, evaluates NVIDIA NGX through a D3D12 host, and can present the result with official NVIDIA DLSS Frame Generation through Streamline + Reflex.

The repository contains source code and dependency installers. It intentionally excludes proprietary NVIDIA DLLs, the user's custom `nvngx_dlssnr.dll`, FFmpeg binaries, ReShade binaries, portable Python, and very large optional model weights. A small open-licensed core model pack for an existing V11 portable folder is available from [GitHub Releases](https://github.com/Absamad-dew/dlss5-video-studio/releases).

## V11 highlights

- hardware-aware realtime profiles: RTX laptop 1080p/1440p and RTX 5080 4K;
- official DLSS-G x2 presentation with frame-aligned depth, motion, HUD-less color, common constants, and Reflex markers;
- portable GPU motion-compensated x2 fallback when DLSS-G is unavailable;
- Depth Anything V2 Small, Video Depth Anything Small, and Depth Anything 3 Small/Base;
- true depth-warped stereoscopic VR output with separate left/right views;
- simplified Quick Start UI plus an optional expert panel;
- local files and supported network video URLs, buffering, audio, fullscreen, pause, and seeking;
- H.264/H.265 recording with automatic output names.

Validated on an RTX 4060 Laptop GPU at 50.63 display FPS for 1080p and 50.44 FPS for 1440p from a 25 FPS source with official DLSS-G x2. The RTX 5080 profile renders at 2560x1440 and presents at 4K.

## Build prerequisites

- Windows 10/11 x64 and Visual Studio 2022 Build Tools;
- NVIDIA NGX SDK placed in `third_party/nvidia_ngx_sdk`;
- NVIDIA Streamline SDK 2.12.0 (`scripts/Get-StreamlineSdk.ps1`);
- ReShade and a legally obtained compatible neural-rendering add-on/runtime for local packaging;
- Python/CUDA dependencies and model weights for the selected guide engines.

Build the native host with `build_native.bat` and the WPF launcher with `build_ui.bat`. `scripts/Install-DepthModels.ps1` downloads the open depth checkpoints into a prepared portable runtime.

## Core model pack

Extract `DLSS5_VIDEO_STUDIO_CORE_MODELS_V11.zip` directly into the V11 program folder. It installs DA2 Small, DA3 Small, and TorchVision RAFT Small into their exact runtime paths. See `MODEL_PACK_CORE_RU.md` for the included profiles and verification command. The archive supplements an existing portable build; it is not the application or NVIDIA runtime.

## Important limitations

Ordinary video has no authoritative game-engine motion vectors, geometry, material buffers, or camera matrices. The project estimates them, so temporal stability depends on content and profile. Advanced depth models are intended for recording and 3D VR; the realtime default remains the smaller DA2 model.

NVIDIA Optical Flow FRUC is not bundled because its SDK requires a separate license acceptance. The included `MotionGPU` path is the portable non-NVIDIA fallback.

## Licensing

Original project code is MIT-licensed. Third-party components and model weights retain their own licenses. The core pack includes only the open-licensed small checkpoints listed in its manifest and license folder. Proprietary NVIDIA binaries and large optional weights are not distributed in the repository or core pack.
