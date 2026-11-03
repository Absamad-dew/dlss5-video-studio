# Build Video Studio 22.3 from public source

The source supports three Windows build targets and a cross-platform CPU check. A successful compile is separate from having a complete video-processing runtime.

| Target | Prerequisites | Output / validation |
|---|---|---|
| CPU geometry / settings | Python 3.11+, standard library only | Production geometry preflight and 16 existing CPU contracts |
| Launcher | Windows x64, .NET Framework 4.x compiler, Windows PowerShell 5.1 | `dist/DLSS5 Video Studio.exe`; offscreen `--validate-ui` regression |
| Native host | VS 2022 C++ x64, Windows SDK, NGX SDK, Streamline 2.12.0, pinned NVENC header | `dist/engine/dlss5-video-host.exe`; compilation does not exercise NGX/NVENC |
| Streamline probe | Same C++ tools and Streamline 2.12.0 | `dist/streamline/streamline-probe.exe`; needs external Streamline runtime before execution |

## Clean checkout: supported checks without NVIDIA dependencies

```powershell
git clone https://github.com/Absamad-dew/dlss5-video-studio.git
cd dlss5-video-studio
python -I -S -B scripts/demo-preflight.py
python -I -S -B -m unittest discover -s tests -p test_iw3_worker.py -v
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-BuildPrerequisites.ps1 -Target Launcher -Json
cmd /d /c build_ui.bat
powershell -NoProfile -ExecutionPolicy Bypass -File tests/test-studio-launcher.ps1
```

The launcher test creates isolated directories and loads the real modules/XAML with `--validate-ui`. It never calls `ShowDialog`, starts video processing, installs models or changes persistent execution policy. It checks clean, inherited Restricted and inherited RemoteSigned process-policy cases. An administrator-managed Group Policy is respected; the test deliberately refuses that environment.

`ExecutionPolicy Bypass` above applies only to the launched PowerShell process. Do not change machine/user policy for this build. The CPU commands also work without Windows; launcher/native builds do not.

## Native host with already obtained SDKs

First inspect prerequisites; exit **2** means missing or mismatched requirements. No build preflight or build script downloads dependencies.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-BuildPrerequisites.ps1 -Target Native -Json
```

The defaults are relative to this checkout:

```text
third_party/nvidia_ngx_sdk/include/nvsdk_ngx.h
third_party/nvidia_ngx_sdk/lib/Windows_x86_64/x64/nvsdk_ngx_d.lib
third_party/streamline-sdk-v2.12.0/include/sl.h
third_party/streamline-sdk-v2.12.0/lib/x64/sl.interposer.lib
third_party/nvcodec/include/ffnvcodec/nvEncodeAPI.h
```

You can use an existing SDK installation without copying it into the repository. Set these three directory variables to your own installation, then build:

```powershell
$env:DLSS5_NGX_SDK = 'C:/SDKs/nvidia_ngx_sdk'
$env:DLSS5_STREAMLINE_SDK = 'C:/SDKs/streamline-sdk-v2.12.0'
$env:DLSS5_NVCODEC_INCLUDE = 'C:/SDKs/nvcodec/include'
cmd /d /c build_native.bat
cmd /d /c build_streamline_probe.bat
```

These are illustrative SDK paths, not sibling-checkout dependencies. `DLSS5_BUILD_OUT` and `DLSS5_UI_OUT` still override the host directory and launcher filename. The native host uses C++20/OpenMP and the dynamic MSVC runtime; deployed machines need the corresponding Microsoft Visual C++ x64 runtime.

If you do not already have the dependencies, obtain them explicitly from their official sources after reviewing their applicable terms: [NVIDIA DLSS/NGX SDK](https://github.com/NVIDIA/DLSS), [Streamline 2.12.0](https://github.com/NVIDIA-RTX/Streamline/releases/tag/v2.12.0), and the pinned MIT [NVENC header 13.0.19.0](https://github.com/FFmpeg/nv-codec-headers/tree/n13.0.19.0). `scripts/Install-NvCodecHeaders.ps1` is the explicit header installer and verifies SHA-256. It is no longer invoked implicitly by `build_native.bat`. Preflight checks Streamline version metadata and that pinned NVENC header digest.

## Reproducible source and developer packages

```powershell
python scripts/package_source_build.py --output dist/release-source
```

Packaging requires a Git checkout: the builder uses tracked public source plus explicitly named build helpers, so an untracked Python environment or local source file cannot enter the archive. The resulting source kit has no compiler, model or vendor runtime dependency. A package README explains which checks run independently. The legacy portable packager is not part of this route: it expects a separately prepared base/runtime and is not a clean-checkout build.

After all three build targets succeed, a local binary candidate can be assembled with:

```powershell
python scripts/package_source_build.py --output dist/release-developer --include-build --ngx-license path/to/applicable/NVIDIA_RTX_SDK_LICENSE.txt
```

The binary candidate includes the launcher, the actual NGX/D3D12/NVENC host and Streamline probe. It excludes all SDK headers/libraries, vendor runtime DLLs, FFmpeg, Python/CUDA, models, video, user/runtime settings and logs; tracked public application configuration remains included. It is a **developer build requiring external runtime components**, not a complete portable processing application. The applicable NGX license must accompany the candidate; the script does not download it or decide publication rights. This SDK-linked developer candidate remains local until its distribution conditions are resolved.

For a distributable first-party Windows artifact without SDK-linked native binaries:

```powershell
cmd /d /c build_ui.bat
python scripts/package_source_build.py --output dist/release-launcher --include-launcher
```

This mode packages **Windows launcher + public source**, including the real WPF application/configuration and the compiled first-party `Program.cs` launcher. It contains no native host/probe executable or vendor runtime payload. The launcher can load the interface; video processing still requires a separately built native backend and runtime dependencies. `--include-launcher` and `--include-build` are mutually exclusive.

All modes refuse existing destinations, emit per-file SHA-256 in `manifest.json`, record the source revision plus modified-tree status, and create a ZIP/checksum beside the output directory. Fixed ZIP timestamps, POSIX path ordering and fixed member metadata make packaging repeatable for identical inputs; this does not claim bit-identical compiler outputs across toolchains. Source file hashes in the manifest identify a modified checkout precisely. Published release kits should be generated from the clean committed revision identified in the manifest.

## Runtime and redistribution boundary

Video processing still requires legally obtained compatible NVIDIA/ReShade/add-on runtime components, media tools and the selected models in the expected application layout. Successful native compilation or offscreen UI validation establishes none of their runtime behavior. Do not invoke a native rendering test as a CPU smoke test. The existing native `--test` performs synthetic NGX evaluations and requires the adjacent ReShade/add-on runtime; it is not an SDK-free CPU command. There is no dedicated zero-exit `--help` option: the current parser logs usage and returns 1 before graphics initialization, but static DLL dependencies must still resolve before `main`.

Original project source is MIT. Streamline's [main license](https://github.com/NVIDIA-RTX/Streamline/blob/v2.12.0/license.txt) is MIT with separately identified Nsight files. NGX/DLSS is governed by the [NVIDIA RTX SDK license](https://github.com/NVIDIA/DLSS/blob/main/LICENSE.txt), including conditional integrated-object-code distribution requirements, notices/protective terms and commercial-release notification. The NGX-linked executable is therefore not an MIT-only artifact merely because SDK DLLs are excluded. Review the applicable SDK terms before distribution; this build does not automatically publish binaries or accept a new SDK agreement. [Third-party notices](THIRD_PARTY_NOTICES.md) remain applicable.

## CI and recorded local verification

CI runs the CPU contracts on Linux/Windows, compiles the Windows launcher, and exercises the actual offscreen policy regression. Default hosted jobs obtain no NVIDIA SDKs or checkpoints. An optional manually dispatched native compile uses an owner-provisioned Windows runner labelled `studio-native-sdk`, with already accepted SDKs; it compiles only and does not upload licensed binaries or run GPU work.

On 2026-11-03 the public source compiled successfully on Windows with MSVC **19.44.35228.0**, Windows SDK **10.0.26100.0** and installed SDKs: launcher, native host and Streamline probe. The native compile retained one existing C4996 `std::filesystem::u8path` deprecation warning. The offscreen launcher passed all three policy cases without changing persistent policies. [Source fingerprints and observed build checks](docs/build-verification-2026-11-03.json) record local verification. [Hosted CI passed at revision 89fd98e](https://github.com/Absamad-dew/dlss5-video-studio/actions/runs/41682392495): Linux/Windows CPU contracts, source packaging, Windows launcher build and offscreen checks. No rendering/model/encoding run or new performance measurement was performed. The existing [V22 performance evidence](https://github.com/Absamad-dew/dlss5-video-studio/blob/73aa3f77e7295b8fb0b1a371eb55a3b11c29141a/OPTIMIZATION_V22_RU.md) retains its historical scope.
