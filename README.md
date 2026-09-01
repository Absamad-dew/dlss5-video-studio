# DLSS5 Video Studio 13

Windows video player/processor that reconstructs motion and depth from ordinary video, evaluates NVIDIA NGX through a D3D12 host, and can present the result with official NVIDIA DLSS Frame Generation through Streamline + Reflex.

The repository contains source code and dependency installers. It intentionally excludes proprietary NVIDIA DLLs, the user's custom `nvngx_dlssnr.dll`, FFmpeg binaries, ReShade binaries, portable Python, and very large optional model weights. A small open-licensed core model pack for an existing V11 portable folder is available from [GitHub Releases](https://github.com/Absamad-dew/dlss5-video-studio/releases).

## Version 13 highlights

- three dedicated workspaces: Realtime, Recording, and VR / 3D;
- five universal profiles — Ultra Fast, Fast, Medium, Heavy, and Maximum — with automatic adaptation by VRAM, resolution, and CPU capacity;
- true multi-chunk prebuffering, adjustable 3–30 second startup buffer and chunk size, plus measured underrun diagnostics;
- exact live buffer telemetry in seconds with refill FPS/rate, optional maximum-speed pause filling, and synchronized audio/video rebuffer recovery instead of audio drift or catch-up playback;
- unconditional loading and log validation of the adjacent ReShade/DLSS5 add-on, so Feature 18 is active even when NVIDIA Frame Generation is disabled;
- source-resolution RGB transport through pagefile-backed shared memory, followed by a single D3D12 cubic expansion pass that also reconstructs compact motion/depth guides;
- an isolated portable Python runtime, preventing a user-level CPU-only ONNX Runtime from shadowing the bundled DirectML provider;
- official fixed DLSS-G/MFG x2, x3, and x4 plus Dynamic MFG targets of 60/72/90/120 FPS, with capability checks reported by Streamline instead of silent fallback;
- persistent upload mappings and hardware-sized guide worker/batch scheduling, removing repeated map/unmap and undersized-batch overhead without changing image processing;
- portable GPU motion-compensated x2 fallback when DLSS-G is unavailable;
- Depth Anything V2 Small, Video Depth Anything Small, and Depth Anything 3 Small/Base;
- true depth-warped stereoscopic VR output after the DLSS5 pass, with SBS/Over-Under layouts, 72/90/120 FPS output, bounded disparity, occlusion fill, edge feathering, depth gamma, temporal stabilization, and eye swapping;
- local files and supported network video URLs, buffering, audio, fullscreen, pause, and seeking;
- selectable source-stream resolution for network URLs and an optional right-hand preview pane;
- H.264/H.265 recording from local files or supported page URLs, with automatic output names;
- fine recording and VR overrides for guide resolution, depth cadence, adaptive thresholds, scene cuts, DIS/RAFT motion, RAFT updates, and chunk size.

The program no longer exposes GPU-model-specific profiles. `Auto` classifies available VRAM internally, while the five user-facing levels control the accuracy/cadence of guide, motion, and depth generation. Output geometry and the internal DLSS render preset remain independent controls.

Dynamic MFG is used only when Streamline reports support. Fixed x3/x4 is likewise rejected when `numFramesToGenerateMax` is too low, so the UI never labels an ordinary blend as NVIDIA MFG. VR recording at 72/90/120 FPS uses bidirectional motion-compensated interpolation after DLSS5 and stereo synthesis; it is separate from display-only MFG.

Validation on the high-VRAM test PC (1080p output, external VSR off) reported 217.85 displayed FPS for fixed x4 from a 49 FPS source. Dynamic MFG on a 15 FPS source reported 89.32 displayed FPS for a 90 FPS target, with 85 generated frames across 20 rendered frames after startup adaptation. A separate DepthSBS smoke test produced a verified 1280×720, 72 FPS HEVC VR file after the DLSS5 pass.

The 13.5 high-resolution path was also validated on the RTX 5080 with a 2880×1620 DLSS input and 3840×2160 display output. With genuine Feature 18 active, the native stage reached 84.55 FPS, guide generation 40.45 FPS, persistent decode 653.74 FPS, and the paced display held 30.14 FPS with zero buffer underruns. Compared with the previous full-resolution CPU transport, the estimated steady pipeline rose from 18.39 to 27.36 FPS and the planned shared RGB reserve fell from 2402.7 MB to 118.7 MB for the test source.

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
