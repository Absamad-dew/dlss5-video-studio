"""Opt-in laptop GPU regression: the 3840x1632 + 2160p + FullSBS failure.

Run via CoreBroker --lock gpu-0. Prepared fixture is a crop/resize of existing
QA media, for dimensions/encoding tests, not a visual-quality comparison.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'python'))
import iw3_worker as worker


def main(args):
    root=args.root.resolve()
    out=Path(tempfile.mkdtemp(prefix='iw3-geometry-',dir=REPO/'qa-output'))
    print('QA_OUTPUT '+str(out),flush=True)
    ffmpeg=str(root/'tools/ffmpeg.exe')
    source=out/'ultrawide-3840x1632.mkv'
    subprocess.run([ffmpeg,'-v','error','-i',str(REPO/'qa-output/v22-record-real-1440p.mp4'),
        '-vf','crop=2560:1088,scale=3840:1632:flags=lanczos','-t','0.32',
        '-c:v','hevc_nvenc','-preset','p1','-tune','lossless','-rc','constqp','-qp','0',
        '-c:a','pcm_s16le',str(source)],check=True)
    reports=[]
    for name,layout,dlss,mode,geometry in [
        ('wide-fullsbs','FullSBS','Off','2160p',[7680,1632]),
        ('wide-fullou','FullOU','Off','2160p',[3840,3264]),
        ('wide-dlss-fullsbs','FullSBS','PreStereo','2160p',[7680,1632]),
    ]:
        settings=out/(name+'.json')
        settings.write_text(json.dumps(dict(depth_model='Any_V3_Mono',resolution=518,
            layout=layout,dlss_mode=dlss,scene_detect=True)),encoding='utf-8')
        output=out/(name+'.mp4')
        command=[sys.executable,'-s','-B',str(REPO/'python/iw3_worker.py'),'--root',str(root),
            '--input',str(source),'--output',str(output),'--settings',str(settings),
            '--config',str(REPO/'qa-output/iw3-dlss-config.ini'),'--output-mode',mode,'--frames','8']
        print('QA_CASE '+name,flush=True)
        with (out/(name+'.log')).open('w',encoding='utf-8') as log:
            child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                encoding='utf-8',errors='replace')
            for line in child.stdout:
                log.write(line);log.flush()
                if line.startswith(('STUDIO_ERROR','STUDIO_RESULT','STUDIO_IW3_GEOMETRY')):
                    print(line.rstrip(),flush=True)
            if child.wait():raise RuntimeError('Case failed: '+name)
        report=json.loads(output.with_suffix('.summary.json').read_text(encoding='utf-8'))
        assert report['frames']==8 and report['audio_present'],report
        assert report['container_geometry']==geometry,report
        assert report['geometry_plan']['output_geometry']==geometry
        subprocess.run([ffmpeg,'-v','error','-xerror','-threads','4','-i',str(output),'-f','null','NUL'],check=True)
        reports.append(dict(case=name,result=report))
    (out/'results.json').write_text(json.dumps(reports,indent=2),encoding='utf-8')
    print('IW3_GEOMETRY_VIDEO_OK '+str(out),flush=True)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser();parser.add_argument('--root',required=True,type=Path)
    main(parser.parse_args())
