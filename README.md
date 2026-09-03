# DLSS5 Video Studio 22

Windows video player/processor that reconstructs motion and depth from ordinary video, evaluates NVIDIA NGX through a D3D12 host, and can present the result with official NVIDIA DLSS Frame Generation through Streamline + Reflex.

The repository contains source code and dependency installers. It intentionally excludes proprietary NVIDIA DLLs, the user's custom `nvngx_dlssnr.dll`, FFmpeg binaries, ReShade binaries, portable Python, and very large optional model weights. A small open-licensed core model pack for an existing V11 portable folder is available from [GitHub Releases](https://github.com/Absamad-dew/dlss5-video-studio/releases).

## Version 22 highlights

Recording now uses GPU-resident D3D12 NVENC with explicit resource fences and an initialization-time compatibility fallback. The old FFmpeg path now receives correct input BT.709 metadata, avoiding a hidden CPU YUV→RGB→YUV conversion. Startup-only full-size upload allocations are released in both recording and realtime (about 183 MiB at 1440p / 411 MiB at 4K).

A controlled laptop native-stage benchmark measured 24.393→29.981 FPS (+22.9%). This excludes guide generation and source decoding. Pixel/timestamp parity is tested by encoding the exact same captured GPU frames with both backends. See [V22 validation and limitations](OPTIMIZATION_V22_RU.md). Older constant-color transport benchmarks below are not representative video-quality evidence.

## Version 21.1 highlights

- the fast DIS path keeps ordinary 4:2:0 input as compact NV12 through persistent decode and pagefile-backed shared memory; D3D12 reconstructs RGB while expanding motion/depth guides;
- realtime and recording keep four complete frames in the D3D12 ring, exactly matching the host's twelve command allocators at three submissions per frame; three 120-frame A/B pairs improved median native throughput by 1.23% and all six encoded files were byte-identical;
- DLSS output is converted to NV12 on the GPU, so CPU readback and the continuous NVENC feed move 1.5 rather than 4 bytes per output pixel;
- the encoder pipe holds four complete NV12 frames, bounded to 16-64 MiB, and recording permits two prepared DIS chunks in flight without unbounded RAM growth;
- periodic depth prefetch survives ordinary chunk boundaries and is discarded only when a scene cut or adaptive refresh actually changes the schedule;
- realtime audio uses one measured sample-clock endpoint across normal pause and rebuffering, with startup/device latency compensated only when an endpoint truly has to reopen.

An exact 120-frame 1440p native+NVENC A/B improved from 13.047 FPS with the old fixed 4 MiB pipe to 22.128 FPS (1.70x) with the complete-frame queue. Decoded frame SSIM is 1.000000. A warmed 300-frame UHD-to-1440p laptop recording completed at 17.76 FPS end to end: 22.26 FPS DLSS+NVENC delivery, 32.61 FPS guide generation, and 81.22 FPS persistent decode. The HEVC+AAC result contains all 300 frames/12.00 seconds and fully decodes with the same depth cadence and image settings.

Version 21 retains all Version 20 improvements:

- recording now uses the same source-resolution pagefile-backed RGB transport and native D3D12 cubic expansion as realtime, avoiding a full CPU resize/copy at every frame;
- recording chunk completion uses a monotonic shared-memory counter and ordered asynchronous mapping release instead of blocking on redirected text protocol responses;
- guide/decode, native DLSS submission, and the controller receive separate hardware-sized CPU lanes; below-normal NVENC conversion can borrow the complete worker pool without starving guide generation;
- ordinary recording feeds one persistent NV12/NVENC process directly from the native output ring, eliminating RGB chunk files, repeated encoder startup and FFmpeg RGB conversion; VSR-after-DLSS retains bounded asynchronous chunk encoding for its required intermediate hand-off;
- `.run.json` schema 10 reports the hardware partition, acknowledgement transport, encoder time, blocking wait, and successfully overlapped NVENC time.
- the portable packager now includes the Streamline/Reflex runtime beside the native host, preventing the missing-DLL exit that could occur before `HOST_STREAM_READY`.

Version 20 retains all Version 19 features:

- three dedicated workspaces: Realtime, Recording, and VR / 3D;
- five universal profiles — Ultra Fast, Fast, Medium, Heavy, and Maximum — with automatic adaptation by VRAM, resolution, and CPU capacity;
- true multi-chunk prebuffering, adjustable 3–30 second startup buffer and chunk size, plus measured underrun diagnostics;
- exact live buffer telemetry in seconds with refill FPS/rate, optional maximum-speed pause filling, and a measured sample-clock/displayed-frame timeline instead of an independent wall-clock audio process;
- audio is decoded and its SDL/WASAPI endpoint is prewarmed while the neural buffer fills, so playback starts on the same media clock; pause/rebuffer freeze the real sample clock, and periodic drift muting/restarts have been removed;
- unconditional loading and log validation of the adjacent ReShade/DLSS5 add-on, so Feature 18 is active even when NVIDIA Frame Generation is disabled;
- source-resolution RGB transport through pagefile-backed shared memory, followed by a single D3D12 cubic expansion pass that also reconstructs compact motion/depth guides;
- an isolated portable Python runtime, preventing a user-level CPU-only ONNX Runtime from shadowing the bundled DirectML provider;
- official fixed DLSS-G/MFG x2, x3, and x4 plus Dynamic MFG targets of 60/72/90/120 FPS, with capability checks reported by Streamline instead of silent fallback;
- persistent upload mappings and hardware-sized guide worker/batch scheduling, removing repeated map/unmap and undersized-batch overhead without changing image processing;
- periodic neural-depth inference is prefetched on the GPU while CPU motion/confidence maps are built, preserving the same depth frames and quality while removing most of the serial DML wait;
- portable GPU motion-compensated x2 fallback when DLSS-G is unavailable;
- Depth Anything V2 Small, Video Depth Anything Small, and Depth Anything 3 Small/Base/Large;
- true depth-warped stereoscopic VR output after the DLSS5 pass, with fast inverse warp, layered z-splat, and a new gradient-aware Temporal LDI renderer that reconstructs a far background plate and repairs disocclusions spatially and across time;
- Temporal Atlas 2K/4K stereo repair: sparse bidirectional motion/depth checks recover hidden background from past and future frames, accepted RGB is sampled at native resolution, and MI-GAN runs only on at most two grouped residual ROIs per eye; Moebius and M2SVid remain separate experiments;
- robust percentile depth normalization, temporally stabilized depth range, subject/comfort/manual convergence, cinematic/comfort/linear disparity curves, independent foreground/background parallax, configurable 2–12 LDI layers, edge protection, comfort limiting, and repaired-region sharpening;
- explicit VR DLSS5 policy: one genuine Feature 18 pass before stereo, or a maximum-quality mode that splits the generated stereo view and performs a second genuine DLSS5 pass independently for each eye before restacking;
- headset-safe H.264 High and HEVC Main/Main10 export, exact video-frame-preserving audio muxing, and a mandatory decode/profile check that rejects the HEVC Rext/GBR combination responsible for black playback;
- local files and supported network video URLs, buffering, audio, fullscreen, pause, and seeking;
- selectable source-stream resolution for network URLs and an optional right-hand preview pane;
- H.264/H.265 recording from local files or supported page URLs, with automatic output names;
- fine recording and VR overrides for guide resolution, depth cadence, adaptive thresholds, scene cuts, DIS/RAFT motion, RAFT updates, and chunk size.
- recording and VR reuse realtime's pagefile-backed RGB/guide transport and bounded passive OpenMP scheduling; depth VR preserves only the sidecars it needs instead of writing full RGB chunks to disk;
- adaptive stereo comfort measures robust motion and vector confidence, damps unsafe parallax on difficult motion, ramps depth after shot cuts, and slowly returns full 3D impact without breathing;
- the CUDA stereo worker reuses page-locked input/output buffers, removing repeated large host allocations and `tobytes()` copies from high-resolution VR export.

The program no longer exposes GPU-model-specific profiles. `Auto` classifies available VRAM internally, while the five user-facing levels control the accuracy/cadence of guide, motion, and depth generation. Output geometry and the internal DLSS render preset remain independent controls.

Laptop validation used the same 300-frame 960x540 source, 2560x1440 output, Medium guide settings, explicit DirectML depth, H.265 QP 18, and an eight-physical-core CoreBroker allocation for both builds. End-to-end recording rose from 8.98 FPS in Version 19 to 9.68 FPS in Version 20 (+7.8%); the native DLSS+encode delivery stage rose from 24.00 to 28.87 FPS (+20.3%). The remaining limit was guide generation at about 17.2 FPS. Both outputs contain exactly 300 frames, 12.00 seconds of video and AAC audio, fully decode, and compare at SSIM 0.9922; the small difference is the explicit one-pass BT.709 NV12 conversion rather than reduced render or guide quality. A second H.264/Auto run confirmed that recording keeps DirectML instead of inheriting realtime's high-resolution CPU latency fallback.

Dynamic MFG is used only when Streamline reports support. Fixed x3/x4 is likewise rejected when `numFramesToGenerateMax` is too low, so the UI never labels an ordinary blend as NVIDIA MFG. VR recording at 72/90/120 FPS uses bidirectional motion-compensated interpolation after DLSS5 and stereo synthesis; it is separate from display-only MFG.

Validation on the high-VRAM test PC (1080p output, external VSR off) reported 217.85 displayed FPS for fixed x4 from a 49 FPS source. Dynamic MFG on a 15 FPS source reported 89.32 displayed FPS for a 90 FPS target, with 85 generated frames across 20 rendered frames after startup adaptation. A separate DepthSBS smoke test produced a verified 1280×720, 72 FPS HEVC VR file after the DLSS5 pass.

The 13.5 high-resolution path was also validated on the RTX 5080 with a 2880×1620 DLSS input and 3840×2160 display output. With genuine Feature 18 active, the native stage reached 84.55 FPS, guide generation 40.45 FPS, persistent decode 653.74 FPS, and the paced display held 30.14 FPS with zero buffer underruns. Compared with the previous full-resolution CPU transport, the estimated steady pipeline rose from 18.39 to 27.36 FPS and the planned shared RGB reserve fell from 2402.7 MB to 118.7 MB for the test source.

Version 13.6 pipelines the next scheduled depth inference with the intervening motion/postprocessing work. On the RTX 4060 Laptop, an identical 240-frame 2880×1620 guide workload increased from 57.27 to 93.89 FPS (1.64×); 1.61 of 2.02 seconds of DML work was overlapped. The heavier portrait 302×540 guide grid reached 62.36 FPS after allocation-light confidence and flow kernels. A complete pause/resume test confirmed one audio start and the same decoder PID before and after the pause. Repeating the 4K RTX 5080 test raised guide throughput from 40.45 to 63.95 FPS and estimated steady throughput from 27.36 to 34.49 FPS; 4K display held 30.21 FPS with zero underruns.

Version 13.7 replaces process suspension with a real ffplay/SDL device pause and reads the live audio sample clock through a non-buffered byte stream. Audio is initially aligned to the newest displayed-frame position; sustained render slowdown selects a pitch-preserving tempo, while a hysteretic hold/release guard bounds residual lead. Native buffer events are drained in one controller tick and completed BUFFERING/READY pairs are coalesced. Pause requests arriving before the audio window exists are deferred rather than destroying the decoder. Regression tests cover a frozen sample clock, the same PID across pause/resume, long playback, and a heavy RAFT startup race.

Version 13.8 removes the remaining high-resolution realtime stalls. RGB plus packed V3 motion/depth sidecars stay in named shared memory; completed chunks are reported through a monotonic shared-memory counter instead of delayed redirected stdout. Retired mappings are released asynchronously after the replacement chunk is published. The native OpenMP pool is bounded and uses passive waits, while the lightweight buffer controller gets deterministic scheduling. Sustained 600-frame tests on the RTX 4060 Laptop held 29.996 FPS at 1080p and 29.991 FPS at 1440p from a 30 FPS source, with zero buffer underruns in both cases. At 1080p the native DLSS path delivered 218.10 FPS and guide generation reached 77.48 FPS; at 1440p they retained 62.14 and 33.43 FPS respectively. For 1440p on the standard-VRAM path, Auto moves the same sparse DA2 model to a bounded CPU executor so depth does not contend with a nearly saturated DLSS GPU queue; explicit backend choices remain respected. Audio now keeps one normal-speed ffplay endpoint instead of reopening it from transient startup-rate telemetry; a 15-second run and three pause/resume cycles both retained one PID and a frozen paused sample clock.

Version 14 rebuilds DepthSBS output around a motion-stabilized layered renderer. Laptop tests rendered the new depth stereo stage at 76.46 FPS for a 60-frame 606×1080 Half-SBS job and 57.88 FPS at 810×1440 using one anchored source eye. Both produced all 60 requested frames and validated as HEVC Main/yuv420p. The optional DA3 Large checkpoint also completed together with DLSS5 and RAFT inside the RTX 4060 Laptop's 8 GB VRAM; after warm-up its individual 392-pixel depth passes were about 87–141 ms, so it is exposed as an offline maximum-quality choice rather than a realtime default.

Version 15 adds Temporal LDI and three VR presets. A laptop end-to-end smoke test completed source decoding, guide generation, genuine Feature 18, stereo synthesis, audio mux, metadata injection, and first-frame validation for all eight requested frames. The direct 604×540 Full-SBS Temporal LDI stage measured 19.19 FPS including both generated eyes. A separate test verified the maximum path with three genuine Feature 18 evaluations: one before stereo and one independently for each eye; the resulting HEVC Main/yuv420p file contained every requested frame and decoded successfully.

Version 19 replaces per-frame diffusion as the default VR repair with Temporal Atlas. GAPW emits strict left/right visibility masks; the worker uses sparse lookaround distances, bidirectional RAFT/DIS consistency, photometric rejection, background-biased depth checks, and scene boundaries before copying real neighbouring-frame pixels at native resolution. Only the residual mask reaches the compact MI-GAN ONNX pipeline, grouped into at most two DirectML launches per eye. `INSTALL_VR_MODELS.cmd` downloads the verified resumable 28 MB model; Moebius and M2SVid remain optional experiments.

Laptop validation on a moving 40-frame person clip recovered 66.96% of disocclusion pixels from real frames and left 32.22% for neural filling. Full-SBS 810x1440 Atlas ran at 0.85 FPS. A true UHD portrait-eye test (2160x3840 per eye, 4320x3840 container) ran at 0.56 FPS; its GAPW stage reached 3.21 FPS. Bounded ROI grouping improved the smaller control case from 0.23 to 1.23 FPS.

Version 16 removes the recurring audio hold/release loop. A 25-second laptop playback kept one prewarmed audio PID and produced no forced holds; the stricter sampled-clock regression measured at most 51 ms steady drift. Three pause/resume cycles preserved the same device and the paused sample clock moved by at most 38 ms. Recording and DepthSBS smoke tests used shared RGB memory, completed every requested frame, and decoded successfully. The adaptive Temporal LDI test reports its actual scene/motion stereo scale in progress telemetry rather than silently changing strength.

The model and renderer trade-offs, including Moebius, DepthCrafter, StereoCrafter, and experimental M2SVid, are documented in VR_RESEARCH_RU.md.

## Build prerequisites

- Windows 10/11 x64 and Visual Studio 2022 Build Tools;
- NVIDIA NGX SDK placed in `third_party/nvidia_ngx_sdk`;
- NVIDIA Streamline SDK 2.12.0 (`scripts/Get-StreamlineSdk.ps1`);
- ReShade and a legally obtained compatible neural-rendering add-on/runtime for local packaging;
- Python/CUDA dependencies and model weights for the selected guide engines.

Build the native host with `build_native.bat` and the WPF launcher with `build_ui.bat`. `scripts/Install-DepthModels.ps1` downloads the open depth checkpoints into a prepared portable runtime.

## Main model pack

Extract `DLSS5_VIDEO_STUDIO_MAIN_MODELS_V19.zip` directly into the program folder. It installs DA2 Small, DA3 Small, TorchVision RAFT Small, and MI-GAN for Temporal Atlas into their exact paths. Run `VERIFY_MAIN_MODELS.cmd` after extraction. DA3 Large, Moebius, and M2SVid remain separate. See `MODEL_PACK_MAIN_RU.md`; the archive supplements an existing portable build and does not contain the application or proprietary NVIDIA runtime.

## Important limitations

Ordinary video has no authoritative game-engine motion vectors, geometry, material buffers, or camera matrices. The project estimates them, so temporal stability depends on content and profile. Advanced depth models are intended for recording and 3D VR; the realtime default remains the smaller DA2 model.

NVIDIA Optical Flow FRUC is not bundled because its SDK requires a separate license acceptance. The included `MotionGPU` path is the portable non-NVIDIA fallback.

## Licensing

Original project code is MIT-licensed. Third-party components and model weights retain their own licenses. The core pack includes only the open-licensed small checkpoints listed in its manifest and license folder. Proprietary NVIDIA binaries and large optional weights are not distributed in the repository or core pack.
