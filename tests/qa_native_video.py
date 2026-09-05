"""Check actual decode/count/PTS/audio alignment, not subjective VR quality."""
import argparse
import json
from pathlib import Path
import subprocess
import numpy as np


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--tools',type=Path,required=True)
    p.add_argument('--source',type=Path,required=True)
    p.add_argument('--video',type=Path,required=True)
    p.add_argument('--start',type=float,default=0)
    p.add_argument('--frames',type=int,required=True)
    p.add_argument('--report',type=Path,required=True)
    a=p.parse_args()
    def run(program,args):
        return subprocess.run([str(a.tools/program),*args],check=True,stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)).stdout
    probe=json.loads(run('ffprobe.exe',['-v','error','-show_streams','-show_packets','-of','json',str(a.video)]))
    streams={s['codec_type']:s for s in probe['streams']}
    assert 'audio' in streams and 'video' in streams,streams.keys()
    video=streams['video']; fps=eval_fraction(video['avg_frame_rate'])
    frames=int(video['nb_frames']); assert frames==a.frames,(frames,a.frames)
    packets={kind:[p for p in probe['packets'] if p['stream_index']==s['index']] for kind,s in streams.items()}
    pts=sorted(float(p['pts_time']) for p in packets['video'])
    np.testing.assert_allclose(np.diff(pts),1/fps,atol=2e-6)
    for kind,values in packets.items():
        dts=[float(p['dts_time']) for p in values if 'dts_time' in p]
        assert np.all(np.diff(dts)>0),kind+' nonmonotonic DTS'
    def audio(path,start=0):
        seek=['-ss',str(start)] if start else []
        return np.frombuffer(run('ffmpeg.exe',['-v','error',*seek,'-i',str(path),
            '-t',str(frames/fps),'-vn','-ac','1','-ar','8000','-f','f32le','-']),np.float32)
    expected=audio(a.source,a.start); actual=audio(a.video)
    n=min(len(expected),len(actual)); expected=expected[:n]; actual=actual[:n]
    assert np.sqrt(np.mean(actual**2))>1e-5,'silent audio'
    # +/- 80 ms exhaustive correlation at 8 kHz (only short QA clips).
    lags=range(-640,641)
    def similarity(lag):
        x=expected[max(0,-lag):n-max(0,lag)]
        y=actual[max(0,lag):n-max(0,-lag)]
        return float(np.dot(x,y)/max(1e-12,np.linalg.norm(x)*np.linalg.norm(y)))
    best=max(lags,key=similarity)
    print(json.dumps({'audio_best_lag_ms':best/8,'best_correlation':similarity(best),
                      'zero_lag_correlation':similarity(0),'rms':float(np.sqrt(np.mean(actual**2)))}),flush=True)
    assert abs(best)<=160,('audio offset >20ms',best/8000)
    # Decode every stereo frame at reduced QA resolution; this is not a quality comparison.
    raw=run('ffmpeg.exe',['-v','error','-i',str(a.video),'-an','-vf','scale=160:90','-pix_fmt','rgb24','-f','rawvideo','-'])
    small=np.frombuffer(raw,np.uint8).reshape(-1,90,160,3)
    assert len(small)==frames and np.all(small.mean((1,2,3))>2),'black/truncated output'
    left_mean=small[:,:,:80].mean((1,2,3)); right_mean=small[:,:,80:].mean((1,2,3))
    assert np.all(left_mean>2) and np.all(right_mean>2),'black stereo eye'
    report=dict(frames=frames,geometry=[video['width'],video['height']],fps=fps,
                pts_continuous=True,audio_offset_ms=best/8,audio_correlation=similarity(best),
                decoded_all_frames=True,minimum_eye_mean=float(min(left_mean.min(),right_mean.min())),
                minimum_frame_mean=float(small.mean((1,2,3)).min()))
    a.report.write_text(json.dumps(report,indent=2),encoding='utf8')
    print(json.dumps(report,indent=2))


def eval_fraction(value):
    num,den=value.split('/'); return int(num)/int(den)


if __name__=='__main__': main()
