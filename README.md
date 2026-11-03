# Video Studio for Windows

**An independent video-processing application spanning native GPU work, model orchestration and a desktop product.**

DLSS5 Video Studio combines realtime playback, recording and stereoscopic video workspaces. A native D3D12 host consumes estimated motion/depth guides, integrates optional NVIDIA NGX and Streamline/Reflex components, and sends recording frames through a GPU-resident NVENC path.

[Full Russian documentation](PROJECT_DOCUMENTATION_RU.md) · [Interface guide](INTERFACE_RU.md) · [Version-by-version engineering history](ENGINEERING_HISTORY.md) · [Releases and model packs](https://github.com/Absamad-dew/dlss5-video-studio/releases)

## What to inspect

| Engineering area | Implementation and evidence |
|---|---|
| Native video transport | Bounded shared-memory and GPU frame rings, resource fences, persistent decoding and asynchronous mapping release. [V22 optimization and A/B checks](OPTIMIZATION_V22_RU.md). |
| Recording | Direct D3D12→NVENC path with initialization-only fallback and pixel/timestamp checks against encoding the same captured GPU frames. [Validation](OPTIMIZATION_V22_RU.md). |
| Realtime playback | Buffer telemetry, audio sample-clock alignment, pause/resume and explicit model preflight. [Startup and shutdown fix](REALTIME_DEPTH_FIX_V22_0_1_RU.md). |
| Stereo/VR | Shared stabilized motion/depth cache, native rendering and a separate pinned IW3 reference workspace. [Architecture](NATIVE_VR_RU.md), [QA and limits](NATIVE_VR_QA_RU.md), [IW3 integration](IW3_VR_V22_1_RU.md). |
| Product interface | WPF/PowerShell launcher, simple/expert controls, explicit presets, independent workspace settings and dependency diagnostics. [Interface](INTERFACE_RU.md). |

## A measured optimization

The retained V22 controlled laptop comparison improved native-stage throughput from **24.393 to 29.981 FPS (+22.9%)**. The test used 120 real 1440p frames, one warmup and three repetitions per path. It excludes guide generation and source decoding; the [measurement note](OPTIMIZATION_V22_RU.md) preserves the full settings and separate end-to-end observations.

Encoder parity is checked using the same captured GPU frames, rather than assuming two separate neural-rendering runs are identical. The repository also retains cases where full-pipeline output differs and identifies synthetic transport fixtures separately.

## Build and run

This is a source project, not a one-command portable distribution. Prepare **Windows 10/11 x64**, Visual Studio 2022 Build Tools, the required NGX/Streamline SDKs and the dependencies for your chosen guide engine. Build with:

```bat
build_native.bat
build_ui.bat
```

[Complete build prerequisites and model-pack instructions](ENGINEERING_HISTORY.md#build-prerequisites) explain the required folder layout. Optional installers are explicit; heavyweight checkpoints are not silently downloaded as part of a test.

## Current source / packaged releases

The source documents version 22.3. Existing release model packs supplement prepared portable folders and do not constitute a new prebuilt 22.3 application. Proprietary NVIDIA/ReShade payloads, large model weights, user video and local diagnostics are excluded.

This is an independent project, not an official NVIDIA product. Input video does not contain authoritative engine motion or geometry; estimated guides have content-dependent limitations. Original source is MIT licensed; SDKs, add-ons and models retain their own terms. [Detailed limitations and licensing](ENGINEERING_HISTORY.md#important-limitations).
