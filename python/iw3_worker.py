"""Studio transport around the unmodified, pinned nunif/iw3 video pipeline.

No Studio depth/warp/comfort/inpaint corrections run in reference mode.
Range preparation is lossless; final audio is always cut from the source timeline.
"""
import argparse
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

COMMIT = 'd23721f1b5f0a4c92c3ee1be013180bf298730c5'
CREATE_NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0)


def emit(kind, value):
    print(kind + ' ' + json.dumps(value, ensure_ascii=False), flush=True)


def schema(root):
    return json.loads((root / 'app/iw3-settings.json').read_text(encoding='utf-8-sig'))['fields']


def validate_settings(root, values):
    fields = schema(root)
    unknown = set(values) - {f['key'] for f in fields}
    if unknown:
        raise ValueError('Unknown iw3 settings: ' + ', '.join(sorted(unknown)))
    result = {}
    for f in fields:
        v = values.get(f['key'], f['default'])
        if f['type'] == 'choice':
            if str(v) not in {str(o['value']) for o in f['options']}:
                raise ValueError('Invalid option: ' + f['key'])
            v = str(v)
        elif f['type'] == 'bool':
            if not isinstance(v, bool):
                raise ValueError('Expected boolean: ' + f['key'])
        else:
            if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
                raise ValueError('Expected finite number: ' + f['key'])
            if not f['min'] <= v <= f['max']:
                raise ValueError('Out of range: ' + f['key'])
            if f['step'] == 1 and int(v) != v:
                raise ValueError('Expected integer: ' + f['key'])
        result[f['key']] = v
    return result


def configure_imports(root):
    code = root / 'third_party/nunif'
    status = root / 'models/iw3/install.json'
    if not status.is_file() or not (code / 'iw3/utils.py').is_file():
        raise RuntimeError('iw3 is not installed. Run INSTALL_IW3.cmd in the program folder.')
    if json.loads(status.read_text(encoding='utf-8'))['commit'] != COMMIT:
        raise RuntimeError('iw3 engine version mismatch. Run INSTALL_IW3.cmd.')
    sys.path[:0] = [str(root / 'models/iw3/site-packages'), str(code)]
    os.environ['NUNIF_HOME'] = str(root / 'models')
    os.environ['TORCH_HOME'] = str(root / 'models/iw3/torch')
    os.environ['HF_HOME'] = str(root / 'models/iw3/huggingface')
    os.environ.setdefault('HF_HUB_DISABLE_SYMLINKS_WARNING', '1')


def build_cli(settings, source, output, codec, quality, source_fps, height=0):
    s = settings
    args = ['-i', str(source), '-o', str(output), '--yes', '--gpu', '0',
            '--method', s['method'], '--depth-model', s['depth_model'],
            '--synthetic-view', s['synthetic_view'], '--convergence-mode', s['convergence_mode'],
            '--divergence', str(s['divergence']), '--convergence', str(s['convergence']),
            '--foreground-scale', str(s['foreground_scale']), '--ipd-offset', str(s['ipd_offset']),
            '--edge-dilation', str(int(s['edge_x'])), str(int(s['edge_y'])),
            '--ema-decay', str(s['ema_decay']), '--ema-buffer', str(int(s['ema_buffer'])),
            '--mask-inner-dilation', str(int(s['mask_inner_dilation'])),
            '--mask-outer-dilation', str(int(s['mask_outer_dilation'])),
            '--batch-size', str(int(s['batch_size'])), '--max-workers', s['max_workers'],
            '--max-fps', str(min(float(s['max_fps']) or source_fps, source_fps)),
            '--video-codec', 'hevc_nvenc' if codec == 'H265' else 'h264_nvenc',
            '--preset', 'p4', '--crf', str(quality), '--pix-fmt', s['pix_fmt'],
            '--scene-cache-dir', str(Path(output).parent / 'scene-cache'),
            '--colorspace', 'auto']
    for key in ('preserve_screen_border', 'limit_resolution', 'depth_aa', 'tta',
                'ema_normalize', 'scene_detect', 'low_vram', 'disable_amp'):
        if s[key]:
            args.append('--' + key.replace('_', '-'))
    for key in ('resolution', 'stereo_width', 'warp_steps', 'inpaint_max_width'):
        if s[key] > 0:
            args += ['--' + key.replace('_', '-'), str(int(s[key]))]
    args += {'FullSBS': [], 'HalfSBS': ['--half-sbs'],
             'FullOU': ['--tb'], 'HalfOU': ['--half-tb']}[s['layout']]
    if height:
        args += ['--vf', f'scale=-2:{height}:flags=lanczos']
    return args


def run(command, log=None):
    with tempfile.TemporaryFile() as errors:
        result = subprocess.run([str(x) for x in command], stdout=subprocess.PIPE,
                                stderr=errors, creationflags=CREATE_NO_WINDOW)
        errors.seek(0)
        detail = errors.read().decode('utf-8', errors='replace')
    if log:
        log.write_text(detail, encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'{Path(str(command[0])).name} failed ({result.returncode}): {detail[-3000:]}')
    return result.stdout.decode('utf-8', errors='replace')


def network_options(headers_path=None, tls=False):
    opts = []
    if headers_path:
        headers = json.loads(Path(headers_path).read_text(encoding='utf-8-sig'))
        if any('\r' in str(k) or '\n' in str(k) or '\r' in str(v) or '\n' in str(v)
               for k, v in headers.items()):
            raise ValueError('Invalid HTTP header')
        opts += ['-headers', ''.join(f'{k}: {v}\r\n' for k, v in headers.items())]
    if tls:
        opts += ['-tls_verify', '0']
    return opts


def probe(root, source, options=(), count=False):
    cmd = [root / 'tools/ffprobe.exe', '-v', 'error', *options]
    if count:
        cmd += ['-count_frames']
    return json.loads(run(cmd + ['-show_streams', '-show_format', '-of', 'json', source]))


def dlss_pass(root, source, output, config, profile, depth_profile):
    command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               root / 'app/process-video.ps1', '-InputVideo', source, '-OutputVideo', output,
               '-ParentWorkDirectory', output.parent,
               '-ConfigPath', config, '-Codec', 'H265', '-Quality', '0', '-OutputMode', 'Source',
               '-PerformanceProfile', profile, '-DepthModelProfile', depth_profile,
               '-RealtimeRenderPreset', 'Native', '-PipelineOrder', 'DLSSOnly', '-VRMode', 'Off',
               '-FrameCount', '0']
    # Stream logs and progress; an inner STUDIO_RESULT is not the outer job result.
    report = None
    child_env = dict(os.environ, TEMP=str(output.parent), TMP=str(output.parent))
    with subprocess.Popen([str(x) for x in command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          encoding='utf-8', errors='replace', creationflags=CREATE_NO_WINDOW, env=child_env) as child:
        for line in child.stdout:
            line = line.rstrip()
            if line.startswith('STUDIO_RESULT '):
                report = json.loads(line.split(' ', 1)[1])
                print('IW3_DLSS_' + line, flush=True)
            elif line.startswith('STUDIO_WORK '):
                print('IW3_DLSS_' + line, flush=True)
            elif line.startswith('STUDIO_PROGRESS_JSON '):
                progress = json.loads(line.split(' ', 1)[1])
                progress['phase'] = 'DLSS5 before iw3'
                progress['percent'] = 3 + .35 * float(progress.get('percent') or 0)
                emit('STUDIO_PROGRESS_JSON', progress)
            else:
                print(line, flush=True)
        if child.wait():
            raise RuntimeError('Optional DLSS5 pass failed; iw3 was not silently substituted.')
    if not report or not output.is_file():
        raise RuntimeError('Optional DLSS5 pass did not publish a complete result.')
    return report


def publish_file(ready, output):
    """Stage on the destination volume before a non-overwriting Windows rename."""
    descriptor, filename = tempfile.mkstemp(prefix='.' + output.stem + '-', suffix='.partial', dir=output.parent)
    pending = Path(filename)
    try:
        with os.fdopen(descriptor, 'wb') as target, ready.open('rb') as source:
            shutil.copyfileobj(source, target, 4 * 1024 * 1024)
        if output.exists():
            raise FileExistsError('Output appeared while processing; refusing to overwrite it.')
        os.rename(pending, output)
    finally:
        pending.unlink(missing_ok=True)


def main(args):
    root = args.root.resolve()
    values = json.loads(args.settings.read_text(encoding='utf-8-sig')) if args.settings else {}
    s = validate_settings(root, values)
    if args.codec == 'H264' and s['pix_fmt'] != 'yuv420p':
        raise ValueError('10-bit iw3 output requires H.265.')
    configure_imports(root)
    manual_depth = {'Any_V2_B':'depth_anything_v2_vitb.pth','Any_V2_L':'depth_anything_v2_vitl.pth'}
    if s['depth_model'] in manual_depth:
        checkpoint = root / 'models/iw3/pretrained_models/hub/checkpoints' / manual_depth[s['depth_model']]
        if not checkpoint.is_file() or checkpoint.stat().st_size == 0:
            raise RuntimeError('Original iw3 requires manual installation of this CC-BY-NC-4.0 model. '
                               'Download the selected Depth-Anything-V2 Base/Large weights from '
                               'huggingface.co/depth-anything and place them at: ' + str(checkpoint))
    source = args.input
    audio_source = source
    video_options, audio_options = [], []
    if args.network:
        net = json.loads(args.network.read_text(encoding='utf-8-sig'))
        source, audio_source = net['MediaUrl'], net['AudioUrl']
        video_options = network_options(net.get('HeadersPath'), net.get('TlsNoVerify'))
        audio_options = network_options(net.get('AudioHeadersPath'), net.get('AudioTlsNoVerify'))
    source_info = probe(root, source, video_options)
    stream = next(x for x in source_info['streams'] if x['codec_type'] == 'video')
    fps = float(Fraction(stream.get('avg_frame_rate') or stream['r_frame_rate']))
    if fps <= 0:
        raise ValueError('Cannot determine source FPS')
    duration = float(stream.get('duration') or source_info['format'].get('duration') or 0)
    if duration and args.start >= duration:
        raise ValueError('Start position is beyond the end of the video')
    if args.frames < 0 or args.start < 0:
        raise ValueError('Negative range')
    source_frames = int(stream.get('nb_frames') or round(duration * fps))
    available = max(0, source_frames - math.ceil(args.start * fps - 1e-6))
    requested = min(args.frames, available) if args.frames and available else args.frames or available
    args.output = args.output.resolve()
    if args.output.exists() or args.output == Path(source):
        raise FileExistsError('Output already exists; choose a new filename.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    height = 0 if args.output_mode == 'Source' else int(args.output_mode.rstrip('p'))
    eye_height = height or stream['height']
    eye_width = round(stream['width'] * eye_height / stream['height'] / 2) * 2
    if s['method'].endswith('inpaint') and s['inpaint_max_width']:
        scale = min(1, s['inpaint_max_width'] / eye_width)
        eye_width, eye_height = round(eye_width * scale), round(eye_height * scale)
    geometry = (eye_width * (2 if s['layout'] == 'FullSBS' else 1),
                eye_height * (2 if s['layout'] == 'FullOU' else 1))
    if args.codec == 'H264' and max(geometry) > 4096:
        raise ValueError('This full-resolution stereo layout exceeds H.264 NVENC dimensions. '
                         'Choose H.265, Half SBS/OU, or a lower output resolution.')
    work_parent = root / 'temp/DLSS5VideoStudio/temp'
    work_parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='job-iw3-', dir=work_parent))
    print('STUDIO_WORK ' + str(work), flush=True)
    begin = time.monotonic()
    ffmpeg = root / 'tools/ffmpeg.exe'
    try:
        engine_source = source
        dlss_report = None
        # Exact fractional seeks and frame ranges are transport concerns. The iw3
        # CLI accepts integer seconds and may include keyframe preroll; prepare a
        # bounded lossless clip instead of changing its temporal algorithms.
        prepare = bool(args.network or args.start or args.frames)
        if prepare:
            emit('STUDIO_PROGRESS_JSON', {'phase': 'Input', 'message': 'Точный отрезок без потери качества',
                                         'percent': 1, 'processed_frames': 0, 'total_frames': requested})
            engine_source = work / 'source-lossless.mkv'
            command = [ffmpeg, '-y', '-v', 'error', *video_options, '-ss', str(args.start), '-i', source,
                       '-map', '0:v:0', '-an']
            if args.frames:
                command += ['-frames:v', str(requested)]
            command += ['-c:v', 'hevc_nvenc', '-preset', 'p1', '-tune', 'lossless',
                        '-rc', 'constqp', '-qp', '0', '-fs', str(8 * 1024**3), engine_source]
            run(command, work / 'prepare.log')
            clip_info = probe(root, engine_source, count=True)
            clip_stream = next(x for x in clip_info['streams'] if x['codec_type'] == 'video')
            actual = int(clip_stream['nb_read_frames'])
            if requested and actual != requested:
                raise RuntimeError(f'Range preparation produced {actual}/{requested} frames. '
                                   'The 8 GiB temporary-file cap may have been reached; use a shorter range.')
            if engine_source.stat().st_size >= 8 * 1024**3:
                raise RuntimeError('Temporary clip reached 8 GiB. Use a local source or shorter range.')
        if s['dlss_mode'] != 'Off':
            if not args.config or not args.config.is_file():
                raise ValueError('DLSS5 settings file is missing')
            dlss_source = work / 'dlss-source.mp4'
            dlss_report = dlss_pass(root, engine_source, dlss_source, args.config, args.profile, args.depth_profile)
            engine_source = dlss_source
        import torch
        from iw3 import utils
        from tqdm import tqdm
        if not torch.cuda.is_available():
            raise RuntimeError('The iw3 Studio mode requires an NVIDIA CUDA GPU.')
        torch.set_num_threads(max(1, min(8, len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else os.cpu_count() or 4)))
        # Use native AMP and official batching. Do not force TF32, compile or
        # replace attention/depth/postprocessing in the reference path.
        total = max(1, round(requested * min(float(s['max_fps']) or fps, fps) / fps))
        class Progress(tqdm):
            def __init__(self, *a, **kw):
                self.desc = kw.get('desc', '')
                kw['disable'] = True
                super().__init__(*a, **kw)
                self.started = time.monotonic()
                self.last_report = 0
                self.count = 0
            def update(self, n=1):
                self.count += n
                self.n = self.count
                now = time.monotonic()
                if now - self.last_report < .5 and self.count < (self.total or total):
                    return
                self.last_report = now
                elapsed = now - self.started
                count_total = self.total or total
                speed = self.count / max(elapsed, 1e-6)
                detection = 'Scene Boundary' in (self.desc or '')
                phase = 'Scene detection' if detection else 'iw3'
                phase_start = (40 if detection else 48) if dlss_report else (2 if detection else 10)
                phase_span = (7 if detection else 42) if dlss_report else (7 if detection else 80)
                emit('STUDIO_PROGRESS_JSON', {'phase': phase, 'message': phase + ' · ' + s['method'],
                     'percent': min(90, phase_start + phase_span * self.count / max(1,count_total)),
                     'processed_frames': self.count, 'total_frames': count_total, 'phase_fps': speed,
                     'eta_seconds': max(0,count_total-self.count)/max(speed,1e-6)})
                if shutil.disk_usage(work).free < 1024**3:
                    raise RuntimeError('Less than 1 GiB free disk space; processing stopped safely.')
        stereo = work / 'iw3-stereo.mp4'
        cli = build_cli(s, engine_source, stereo, args.codec, args.quality, fps, height)
        if s['method'].endswith('inpaint') and s['divergence'] * (1 if s['synthetic_view'] == 'both' else 2) > 5:
            print('IW3_WARNING Strong disparity exceeds the inpaint model training range; '
                  'settings are preserved, but edge artifacts may increase.', flush=True)
        emit('IW3_ENGINE', {'commit': COMMIT, 'method': s['method'], 'depth_model': s['depth_model'],
                           'extras': {'dlss5': s['dlss_mode'], 'target_fps': s['target_fps']}})
        native = utils.create_parser().parse_args(cli)
        utils.set_state_args(native, tqdm_fn=Progress)
        engine_started = time.monotonic()
        utils.iw3_main(native)
        engine_seconds = time.monotonic() - engine_started
        del native
        # Original queues/models are not kept alive during optional interpolation.
        import gc
        gc.collect()
        torch.cuda.empty_cache()
        out_info = probe(root, stereo, count=True)
        out_stream = next(x for x in out_info['streams'] if x['codec_type'] == 'video')
        frame_count = int(out_stream['nb_read_frames'])
        output_fps = float(Fraction(out_stream['avg_frame_rate']))
        if frame_count < 1 or (requested and abs(frame_count-total) > 1):
            raise RuntimeError(f'iw3 returned {frame_count} frames; expected approximately {total}.')
        duration_out = frame_count / output_fps
        final_stage = work / 'final-mux.mp4'
        command = [ffmpeg, '-y', '-v', 'error', '-i', stereo, *audio_options,
                   '-ss', str(args.start), '-i', audio_source,
                   '-map', '0:v:0', '-map', '1:a:0?', '-t', str(duration_out)]
        if int(s['target_fps']):
            command += ['-vf', f"tpad=stop_mode=clone:stop_duration={3/output_fps},"
                        f"minterpolate=fps={s['target_fps']}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1",
                        '-c:v', 'hevc_nvenc' if args.codec == 'H265' else 'h264_nvenc',
                        '-preset', 'p4', '-rc', 'constqp', '-qp', str(args.quality)]
        else:
            command += ['-c:v', 'copy']
        command += ['-af', 'asetpts=PTS-STARTPTS', '-c:a', 'aac', '-b:a', '192k',
                    '-metadata:s:v:0', 'stereo_mode=' + ('top_bottom' if s['layout'].endswith('OU') else 'left_right'),
                    '-movflags', '+faststart', final_stage]
        emit('STUDIO_PROGRESS_JSON', {'phase': 'Audio', 'message': 'Сборка VR и исходного звука',
              'percent': 94, 'processed_frames': frame_count, 'total_frames': frame_count})
        run(command, work / 'mux.log')
        spatial = root / 'tools/spatialmedia/__main__.py'
        ready = work / 'ready.mp4'
        run([sys.executable, '-s', '-B', spatial, '-i', '--v2', '--projection', 'none', '--stereo',
             'top-bottom' if s['layout'].endswith('OU') else 'left-right', final_stage, ready])
        final_info = probe(root, ready, count=True)
        final_stream = next(x for x in final_info['streams'] if x['codec_type'] == 'video')
        final_frames = int(final_stream['nb_read_frames'])
        expected_frames = math.ceil(duration_out * int(s['target_fps']) - 1e-6) if int(s['target_fps']) else frame_count
        if final_frames != expected_frames:
            raise RuntimeError(f'Final mux has {final_frames}/{expected_frames} frames; refusing incomplete output.')
        run([ffmpeg, '-v', 'error', '-i', ready, '-frames:v', '2', '-f', 'null', 'NUL'])
        # Atomic publication: no incomplete file under the final user filename.
        publish_file(ready, args.output)
        result = {'recording': True, 'output_video': str(args.output), 'codec': args.codec,
                  'frames': int(final_stream['nb_read_frames']),
                  'output_geometry': [final_stream['width'], final_stream['height']],
                  'container_geometry': [final_stream['width'], final_stream['height']],
                  'pipeline_label': 'iw3 original' + (' + DLSS5' if s['dlss_mode'] != 'Off' else ''),
                  'iw3_commit': COMMIT, 'iw3_settings': s, 'iw3_seconds': engine_seconds,
                  'iw3_fps': frame_count / engine_seconds, 'elapsed_seconds': time.monotonic()-begin,
                  'end_to_end_fps': frame_count/(time.monotonic()-begin),
                  'dlss5_fps': dlss_report.get('dlss5_fps', 0) if dlss_report else 0,
                  'audio_present': any(x['codec_type']=='audio' for x in final_info['streams']),
                  'source_fps': fps, 'start_seconds': args.start, 'source_frames': requested}
        args.output.with_suffix('.summary.json').write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
        emit('STUDIO_RESULT', result)
    finally:
        if not args.keep_temp and work.resolve().parent == work_parent.resolve() and work.name.startswith('job-iw3-'):
            shutil.rmtree(work)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--input', required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--settings', type=Path)
    p.add_argument('--config', type=Path)
    p.add_argument('--network', type=Path)
    p.add_argument('--codec', choices=['H264','H265'], default='H265')
    p.add_argument('--quality', type=int, choices=range(52), default=18)
    p.add_argument('--output-mode', choices=['Source','2160p','1440p','1080p','720p','540p'], default='Source')
    p.add_argument('--start', type=float, default=0)
    p.add_argument('--frames', type=int, default=0)
    p.add_argument('--profile', default='Medium')
    p.add_argument('--depth-profile', default='DA2Small')
    p.add_argument('--keep-temp', action='store_true')
    try:
        main(p.parse_args())
    except Exception as error:
        print('STUDIO_ERROR ' + str(error), flush=True)
        raise
