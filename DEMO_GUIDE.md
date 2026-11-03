# Three-minute demo

[README](README.md) · [Engineering overview](ENGINEERING_OVERVIEW.md) · [Decision timeline](docs/DECISION_TIMELINE.md)

Start with a real CPU-only geometry check, then follow one frame through the native architecture and inspect the measured optimization. The public walkthrough needs Python 3.11+ and this checkout. It downloads nothing and does not require Windows, an NVIDIA GPU, FFmpeg, a model or an SDK. It produces a geometry plan, not processed video.

## Public walkthrough: three minutes

Run from the repository root. `-I -S -B` isolates Python from user/site packages and suppresses bytecode files.

| Time | Show / do | What the viewer can verify |
|---|---|---|
| 0:00–0:35 | `python -I -S -B scripts/demo-preflight.py` | The actual worker plans a 3840×1632 source as Full-SBS 7680×1632, preserving ultrawide geometry rather than forcing a 2160-pixel height |
| 0:35–1:00 | `python -I -S -B scripts/demo-preflight.py --width 5082 --height 2160 --output-mode Source` | Rejected 10164×2160 stereo output exceeds the H.265 width limit; JSON says `accepted: false`, exit code **2** is expected |
| 1:00–1:35 | Open the [frame-path diagram](media/video-dataflow.svg) and [ownership table](ENGINEERING_OVERVIEW.md#frame-ownership-and-backpressure) | Input ACK retires shared mappings; separate GPU/encoder completion protects slot reuse. This is an architecture visualization, not GPU execution |
| 1:35–2:15 | Open [V22 measurements](OPTIMIZATION_V22_RU.md) | Native median 24.393→29.981 FPS; distinguish it from native-process launch time and the separate complete recording |
| 2:15–2:40 | Follow one [decision and its commit](docs/DECISION_TIMELINE.md) | Why fixed byte pipes became complete-frame queues, or why throughput telemetry cannot be an audio clock |
| 2:40–3:00 | `python -I -S -B -m unittest discover -s tests -p test_iw3_worker.py -v` | Existing CPU contracts: geometry rejection, settings forwarding, preflight order and preservation of an existing output file |

The wrapper calls the production `validate_settings`, `plan_geometry` and `require_geometry` functions. It reports hashes of the worker/settings files, real geometry results and a meaningful exit status. The 16 tests use synthetic dimensions and mocks at external/model boundaries; they exercise CPU contracts, not pixel quality or the native GPU path. Recorded local check on 2026-11-03: **16 passed**, Windows / Python 3.13.15; no models or third-party Python packages were loaded.

## First live product demo on a prepared Windows machine

This is a separate, operator-run path. No public product recording is supplied. Prepare the machine **before** the three-minute presentation: Windows 10/11 x64, supported NVIDIA hardware/driver, a locally built or legally prepared application/runtime, FFmpeg, and the already-installed models selected by the profile. Use [build prerequisites](ENGINEERING_HISTORY.md#build-prerequisites), [build scripts](README.md#build-and-run), [model status/installation](REALTIME_DEPTH_FIX_V22_0_1_RU.md) and [interface controls](INTERFACE_RU.md). The V11 release is a model supplement, not a complete application or a new 22.3 binary distribution. Do not install SDKs or download checkpoints during the presentation.

Use a short video that you own or have permission to demonstrate. Keep paths, titles and output folders free of private information before screen capture. No private source footage is needed by the public walkthrough above.

| Time | Live action | Evidence to retain |
|---|---|---|
| 0:00–0:45 | Open `DLSS5 Video Studio.exe`, choose **Реалтайм**, select the permitted local clip and an installed fast profile; leave optional frame generation off for the first demonstration | Actual selected source, profile and dependency status; no claim that a source-only checkout is ready to play |
| 0:45–1:20 | Start playback, wait for the prepared buffer, pause once and resume | Actual progress/buffer state and the audio transition; report a missing dependency or startup failure if it occurs |
| 1:20–2:20 | Choose **Запись видео**, a short range, H.265 and a fresh output name; disable recording preview if demonstrating direct NVENC | Inspect `recording_encoder_requested`, `recording_encoder_active` and `recording_encoder_fallback` in the saved run report. Finish time is hardware/content dependent; do not promise completion inside this slot |
| 2:20–3:00 | Open a completed output only if that run actually finished. Otherwise show its genuine progress/cancellation state; explain the SBS geometry preflight separately | File/metadata and actual backend from that run. A completed recording is not evidence that every stereo mode runs in realtime |

For a shorter demo, present only playback plus the CPU geometry check. Stereo output and expensive restoration are optional follow-ups with [their own QA limits](NATIVE_VR_QA_RU.md).

## How to read the published performance

| Published observation | Scope |
|---|---|
| 24.393→29.981 FPS, **+22.9%** | Controlled native-stage A/B on RTX 4060 Laptop: 120 real 1440p frames, neutral guides, matched H.265 P1/LL/QP18, one warmup and three repetitions; excludes decode/guides |
| 7.745→6.963 seconds | The same isolated native benchmark process including launch; still not whole-application time |
| 22.86 seconds / 10.50 FPS for 240 frames | Separate complete recording with model loading, guides and audio; not a paired application-wide speedup |

Same-frame encoder parity compares decoded pixels, timing and color metadata from the exact GPU frames captured in one run. Separate NGX runs can differ. [The original note](OPTIMIZATION_V22_RU.md) retains individual repeats, limits and synthetic-fixture distinctions; none of these numbers were newly benchmarked for this guide.

## Available public assets

The tracked visual is the [architecture SVG](media/video-dataflow.svg). Repository inventory and [the sole public release](https://github.com/Absamad-dew/dlss5-video-studio/releases/tag/v11.0.1), checked 2026-11-03, contain **no captured product screenshots or video clips**. The release contains a core-model ZIP and its checksum; it excludes the application and proprietary/runtime dependencies. A diagram or geometry result should therefore be labelled as such, not presented as a recording of GPU processing.
