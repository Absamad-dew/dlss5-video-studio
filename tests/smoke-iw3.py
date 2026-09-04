"""Opt-in NVIDIA laptop integration checks. Run under CoreBroker --lock gpu-0."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--case', default='all')
    p.add_argument('--config', type=Path)
    args = p.parse_args()
    output = Path(tempfile.mkdtemp(prefix='iw3-check-', dir=REPO / 'qa-output'))
    print('QA_OUTPUT ' + str(output), flush=True)
    source = REPO / 'qa-output/v22-record-real-1440p.mp4'
    cases = {
        'mlbw-inpaint': ({'method':'mlbw_l2_inpaint','mask_outer_dilation':2}, '1080p', 17, 0.12),
        'forward-inpaint': ({'method':'forward_inpaint','mask_outer_dilation':2}, '1440p', 13, 0),
        'rowflow-4k': ({'method':'row_flow_v3'}, '2160p', 9, 0),
        'vda': ({'method':'mlbw_l4','depth_model':'VDA_S'}, '1080p', 17, 0),
        'interpolate': ({'method':'row_flow_v3','layout':'HalfOU','target_fps':'72'}, '540p', 17, 0.2),
        'dlss': ({'method':'row_flow_v3','dlss_mode':'PreStereo'}, '1080p', 8, 0),
        'person-4k': ({'method':'row_flow_v3'}, 'Source', 8, 0),
        'tokyo-inpaint': ({'method':'mlbw_l2_inpaint','mask_outer_dilation':2}, 'Source', 45, 0),
    }
    if args.case != 'all':
        cases = {args.case: cases[args.case]}
    results = []
    for name, (settings, resolution, frames, start) in cases.items():
        if name == 'dlss' and not args.config:
            continue
        config = output / (name+'.json')
        config.write_text(json.dumps(settings), encoding='utf-8')
        target = output / (name+'.mp4')
        case_source = source
        if name == 'person-4k':
            case_source = REPO/'qa-output/temporal-atlas-v39/person-source-uhd-portrait.mp4'
        elif name == 'tokyo-inpaint':
            case_source = REPO/'temp/depth-v22-fix/source/Video-Depth-Anything-4f5ae23172ba60fd7bc11ef671cca678842c7072/assets/example_videos/Tokyo-Walk_rgb.mp4'
        command = [sys.executable, '-s', '-B', str(REPO/'python/iw3_worker.py'),
                   '--root', str(args.root), '--input', str(case_source), '--output', str(target),
                   '--frames', str(frames), '--start', str(start), '--settings', str(config),
                   '--output-mode', resolution]
        if args.config:
            command += ['--config', str(args.config)]
        print('QA_CASE ' + name, flush=True)
        with (output/(name+'.log')).open('w', encoding='utf-8') as log:
            proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    encoding='utf-8', errors='replace')
            for line in proc.stdout:
                log.write(line); log.flush()
                if line.startswith(('STUDIO_PROGRESS','STUDIO_ERROR','STUDIO_RESULT','IW3_')):
                    print(line.rstrip(), flush=True)
            code = proc.wait()
        if code:
            results.append({'case':name,'exit_code':code})
            continue
        result = json.loads(target.with_suffix('.summary.json').read_text(encoding='utf-8'))
        if name not in ('person-4k','tokyo-inpaint'):
            assert result['audio_present'], name + ' lost audio'
        if name != 'interpolate':
            assert result['frames'] == frames, name + ' lost frames'
        # Full stream decode, not just the first frame.
        subprocess.run([str(args.root/'tools/ffmpeg.exe'),'-v','error','-xerror','-i',str(target),
                        '-f','null','NUL'], check=True)
        # Bounded contact-sheet frame for visual QA.
        subprocess.run([str(args.root/'tools/ffmpeg.exe'),'-v','error','-i',str(target),
                        '-vf','select=eq(n\\,6),scale=1920:-2','-frames:v','1',
                        str(output/(name+'.png'))], check=True)
        results.append({'case':name,'exit_code':0,'result':result})
    # Pinned engine source and weights were not patched during integration.
    manifest=json.loads((args.root/'models/iw3/install.json').read_text(encoding='utf-8'))
    for record in manifest['files']:
        with (args.root/record['path']).open('rb') as f:
            assert hashlib.file_digest(f,'sha256').hexdigest()==record['sha256'], record['path']
    (output/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print('QA_DONE '+str(output),flush=True)
    if any(r['exit_code'] for r in results):
        raise SystemExit(1)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    main()
