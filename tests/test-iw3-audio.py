"""Check mux timestamps/audio alignment in outputs of smoke-iw3.py (CPU only)."""
import argparse
import json
from pathlib import Path
import subprocess
import numpy as np
from scipy.signal import correlate, correlation_lags

p=argparse.ArgumentParser()
p.add_argument('--root',type=Path,required=True)
p.add_argument('--qa',type=Path,required=True)
args=p.parse_args()
repo=Path(__file__).resolve().parents[1]
source=repo/'qa-output/v22-record-real-1440p.mp4'

def pcm(path,start=0,duration=.68):
    data=subprocess.check_output([str(args.root/'tools/ffmpeg.exe'),'-v','error','-ss',str(start),
         '-i',str(path),'-t',str(duration),'-map','0:a:0','-ac','1','-ar','16000','-f','f32le','pipe:1'])
    return np.frombuffer(data,dtype='<f4')

reports=[]
for entry in json.loads((args.qa/'results.json').read_text(encoding='utf-8')):
    r=entry['result']
    if not r['audio_present']:
        continue
    output=Path(r['output_video'])
    duration=r['source_frames']/r['source_fps']
    a=pcm(source,r['start_seconds'],duration)
    b=pcm(output,0,duration)
    n=min(len(a),len(b));a=a[:n];b=b[:n]
    scores=correlate(b,a,method='fft')
    lags=correlation_lags(len(b),len(a))
    allowed=np.abs(lags)<=1600
    lag=int(lags[allowed][np.argmax(scores[allowed])])
    assert abs(lag)<=256, (output,lag)
    info=json.loads(subprocess.check_output([str(args.root/'tools/ffprobe.exe'),'-v','error',
        '-show_streams','-of','json',str(output)]))
    v=next(s for s in info['streams'] if s['codec_type']=='video')
    audio=next(s for s in info['streams'] if s['codec_type']=='audio')
    assert v['profile'] in ('Main','Main 10','High'),v['profile']
    assert abs(float(v['duration'])-float(audio['duration']))<.064,(v['duration'],audio['duration'])
    assert abs(float(audio['start_time'])-float(v['start_time']))<.03
    assert b'st3d' in output.read_bytes(), 'Missing stereo metadata'
    reports.append({'case':entry['case'],'lag_ms':lag/16,'video_seconds':v['duration'],
                    'audio_seconds':audio['duration'],'profile':v['profile']})
(args.qa/'audio-audit.json').write_text(json.dumps(reports,indent=2),encoding='utf-8')
print(json.dumps(reports,indent=2))
print('IW3_AUDIO_AUDIT_PASSED')
