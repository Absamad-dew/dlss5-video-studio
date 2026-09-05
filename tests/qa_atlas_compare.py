"""Compare decoded RGB without resizing, and GPU sparse-vs-dense acceptance."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'python'))
from vr_atlas import SparseEye, PhotoContext
from vr_reconstruction import grid01, restore_background, BackgroundLink


def gpu_cases():
    torch.manual_seed(29)
    torch.backends.cuda.matmul.allow_tf32 = False
    report = []
    with torch.inference_mode():
        for h, w in ((144, 258), (1440, 2560), (2160, 3840)):
            source = torch.randint(50, 180, (1, 3, h, w), dtype=torch.uint8, device='cuda')
            donor = source.clone()
            dh, dw = 72, 128
            depth = torch.full((1, 1, dh, dw), .2, device='cuda')
            depth[:, :, 20:45, 40:70] = .8
            holes = torch.zeros(1, 1, h, w, dtype=torch.bool, device='cuda')
            holes[:, :, h//5:h//3, w//7:w//7+13] = True
            holes[:, :, h//2:h//2+17, w//2:w//2+19] = True
            donor[:, :, h//5:h//3, w//7:w//7+13] += 1
            small = grid01(dh, dw, 'cuda')
            far = torch.full_like(depth, .2)
            bg = [small[0].cpu(), far[0].cpu(), small[0].cpu()]
            full = [F.interpolate(v[None].cuda(), size=(h, w), mode='bilinear', align_corners=True) for v in bg]
            for use_flow in (False, True):
                flow = torch.zeros(1, 2, dh, dw, device='cuda') if use_flow else None
                validity = torch.ones_like(depth) if use_flow else None
                matrix = None if use_flow else np.array([[1., .000013, -.000009], [0, 1, 0], [0, 0, 1]])
                expected, mask, accepted = restore_background(source, holes, source, depth,
                    full[0], full[1], donor, depth, matrix, 1., flow=flow, flow_valid=validity,
                    anchor_coords=full[2])
                eye = SparseEye(source[0].cpu(), holes[0].cpu(), bg, 'cuda')
                photo = PhotoContext(source, depth).validate(donor, matrix, flow)
                eye.repair(donor, depth, depth, BackgroundLink(matrix, 1.), flow, validity, photo)
                different = int((eye.image != expected).sum())
                mask_diff = int((eye.mask != mask).sum())
                report.append(dict(size=[w, h], flow=use_flow, different_values=different, mask_diff=mask_diff))
                assert different == mask_diff == 0, report[-1]
    return report


def main():
    p = argparse.ArgumentParser(); p.add_argument('--ffmpeg', type=Path)
    p.add_argument('--left', type=Path); p.add_argument('--right', type=Path)
    p.add_argument('--gpu', action='store_true'); p.add_argument('--report', type=Path)
    a = p.parse_args()
    result = {}
    if a.gpu: result['gpu'] = gpu_cases()
    if a.left:
        def hashes(path):
            cmd = [str(a.ffmpeg), '-v', 'error', '-threads', '2', '-i', str(path),
                   '-map', '0:v:0', '-an', '-pix_fmt', 'rgb24', '-f', 'framemd5', '-']
            text = subprocess.run(cmd, check=True, stdout=subprocess.PIPE).stdout.decode()
            return [line for line in text.splitlines() if not line.startswith('#')]
        baseline, candidate = hashes(a.left), hashes(a.right)
        assert baseline and len(baseline) == len(candidate), 'Frame count mismatch'
        result['video'] = dict(frames=len(baseline), identical=baseline == candidate)
        assert baseline == candidate, 'Decoded RGB differs'
    if a.report:
        a.report.parent.mkdir(parents=True, exist_ok=True)
        a.report.write_text(json.dumps(result, indent=2), encoding='utf8')
    print(json.dumps(result, indent=2))


if __name__ == '__main__': main()
