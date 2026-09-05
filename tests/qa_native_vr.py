"""Laptop-only numerical QA with installed, pinned weights. No model downloads."""
import argparse
import json
from pathlib import Path
import sys
import time
import subprocess
import numpy as np
import torch

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'python'))
from vr_depth_worker import load_rowflow_v3
from vr_reconstruction import RowFlowRenderer,SparseVideoInpaint
from vr_shared_depth import StudioDA3Runtime,RawDepthWriter


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--depth',action='store_true')
    p.add_argument('--frames',type=int,default=18)
    p.add_argument('--width',type=int,default=1280)
    p.add_argument('--height',type=int,default=720)
    p.add_argument('--graph',action='store_true')
    p.add_argument('--source',type=Path,default=REPO/'qa-output/v22-record-real-1440p.mp4')
    a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    torch.set_num_threads(4)
    torch.backends.cudnn.benchmark=False
    torch.backends.cuda.matmul.allow_tf32=False
    torch.backends.cudnn.allow_tf32=False
    torch.manual_seed(711)
    report={}
    if a.depth:
        source=a.source
        cmd=[str(a.root/'tools/ffmpeg.exe'),'-v','error','-threads','2','-i',str(source),
             '-vf',f'scale={a.width}:{a.height}', '-frames:v',str(a.frames),'-an','-f','rawvideo','-pix_fmt','rgb24','pipe:1']
        frames=np.frombuffer(subprocess.run(cmd,check=True,stdout=subprocess.PIPE).stdout,np.uint8).reshape(a.frames,a.height,a.width,3)
        runtime=StudioDA3Runtime(a.root,'Any_V3_Mono',518,'cuda-graph' if a.graph else 'eager')
        writer=RawDepthWriter(a.out/'chunk-0000.vrd',a.frames,0)
        elapsed=[]
        for i,frame in enumerate(frames):
            t=time.perf_counter();sample=runtime.infer_frame(frame,384,round(384*a.height/a.width))
            elapsed.append(time.perf_counter()-t)
            writer.write(sample,i==0)
            print(json.dumps({'depth_frame':i,'seconds':elapsed[-1],'shape':list(sample.disparity.shape)}),flush=True)
        writer.close(True)
        report={'frames':a.frames,'warm_mean_s':sum(elapsed[1:])/max(1,len(elapsed)-1),
                'times':elapsed,'provider':runtime.provider,'graph':bool(runtime.graph and runtime.graph.state)}
    else:
        model,reference,_=load_rowflow_v3(a.root)
        renderer=RowFlowRenderer(model)
        rgb=torch.rand(1,3,128,258,device='cuda')
        depth=torch.linspace(0,1,96,device='cuda')[None,None,None].expand(1,1,64,96)
        report['rowflow']=[]
        with torch.inference_mode():
            for anchor in ('symmetric','left','right'):
                for steps in (1,2):
                    expected=reference(model,rgb,depth,3.2,.48,steps,
                        synthetic_view={'symmetric':'both','left':'right','right':'left'}[anchor],
                        preserve_screen_border=True,enable_amp=True)
                    actual=renderer(rgb,depth,3.2,.48,steps,anchor,True)
                    error=max(float((expected[i]-actual[i][0]).abs().max()) for i in (0,1))
                    report['rowflow'].append({'anchor':anchor,'steps':steps,'max_error':error})
                    assert error<2e-5,report['rowflow'][-1]
            from nunif.models import load_model
            net,_=load_model(str(a.root/'models/iw3/pretrained_models/hub/checkpoints/iw3_light_video_inpaint_v1_20250919.pth'),device_ids=[0],weights_only=True)
            net.eval()
            images=torch.randint(0,256,(12,3,192,322),dtype=torch.uint8,device='cuda')
            masks=torch.zeros(12,1,192,322,device='cuda');masks[:,:,60:90,70:81]=1
            sparse=SparseVideoInpaint(net,cache_mb=128)
            report['inpaint']=[]
            for eye in (0,1):
                src=images.float()/255;m=masks
                if eye==0:src,m=src.flip(-1),m.flip(-1)
                with torch.autocast('cuda',dtype=torch.float16):
                    expected=net.infer(src,m)
                if eye==0:expected=expected.flip(-1)
                outs=[3,4,5,6,7,8]
                t=time.perf_counter()
                actual=torch.stack(sparse.reconstruct(list(images),list(masks),list(range(12)),outs,eye=eye))
                torch.cuda.synchronize();elapsed=time.perf_counter()-t
                expected=expected[outs].mul(255).round().byte()
                mask=masks[outs].bool().expand_as(actual)
                error=float((actual.float()-expected.float()).abs()[mask].max())
                assert error<=1,('inpaint mismatch',eye,error)
                assert torch.equal(actual[~mask],images[outs][~mask]),'trusted RGB changed'
                repeat=torch.stack(sparse.reconstruct(list(images),list(masks),list(range(12)),outs,eye=eye))
                assert torch.equal(actual,repeat),'feature cache changed output'
                report['inpaint'].append({'eye':eye,'max_uint8_error':error,'seconds':elapsed})
            report['cache']=sparse.stats
    (a.out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2),flush=True)


if __name__=='__main__':main()
