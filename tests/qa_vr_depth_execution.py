"""Fixed-checkpoint laptop QA: skip only unused ray branch, compare raw disparity."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'python'))
from vr_shared_depth import StudioDA3Runtime
from vr_depth_execution import install_depth_only_head


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--model', default='Studio_DA3_Base')
    p.add_argument('--resolution', type=int, default=518)
    p.add_argument('--frames', type=int, default=8)
    p.add_argument('--out', type=Path, required=True)
    a = p.parse_args()
    torch.set_num_threads(4)
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cudnn.benchmark = False
    cmd = [str(a.root/'tools/ffmpeg.exe'), '-v', 'error', '-threads', '2', '-i', str(a.source),
           '-vf', 'scale=1280:720', '-frames:v', str(a.frames), '-an', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-']
    frames = np.frombuffer(subprocess.run(cmd, check=True, stdout=subprocess.PIPE).stdout, np.uint8)
    frames = frames.reshape(a.frames, 720, 1280, 3)
    runtime = StudioDA3Runtime(a.root, a.model, a.resolution)
    # A later runtime default may already wrap the head. Restore only this QA instance.
    head = runtime.depth.model.head
    if hasattr(head, 'original'): runtime.depth.model.head = head.original
    expected = []
    timings = {}
    for kind in ('baseline', 'depth-only'):
        if kind == 'depth-only': assert install_depth_only_head(runtime.depth.model)
        runtime.infer_frame(frames[0], 384, 216)
        times = []
        for i, frame in enumerate(frames):
            torch.manual_seed(71+i)
            t = time.perf_counter()
            result = runtime.infer_frame(frame, 384, 216)
            times.append(time.perf_counter()-t)
            if kind == 'baseline': expected.append(result.disparity.copy())
            else: np.testing.assert_array_equal(result.disparity, expected[i])
            print(json.dumps(dict(kind=kind, frame=i, seconds=times[-1])), flush=True)
        timings[kind] = times
    report = dict(model=a.model, resolution=a.resolution, frames=a.frames, raw_disparity_equal=True,
                  times=timings, median_s={k: float(np.median(v)) for k, v in timings.items()})
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__': main()
