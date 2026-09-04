"""Opt-in laptop CUDA test. Run via CoreBroker --lock gpu-0 after installation."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'python'))


def parity(root):
    import iw3_worker
    iw3_worker.configure_imports(root)
    from iw3_da3 import create_provider,expand_shared_state
    import torch
    from depth_anything_3.cfg import create_object, load_config
    from depth_anything_3.registry import MODEL_REGISTRY
    from safetensors.torch import load_file
    from iw3.depth_anything_model import batch_preprocess
    settings=iw3_worker.validate_settings(root,{'depth_model':'Studio_DA3_Small','resolution':392})
    candidate=create_provider(root,settings).load(gpu=0,resolution=392)
    torch.manual_seed(2026)
    x=torch.rand((1,3,392,700),device='cuda')
    prep=batch_preprocess(x,392)
    native=create_object(load_config(MODEL_REGISTRY['da3-small']))
    state=load_file(str(root/'models/depth/da3-small/model.safetensors'))
    native.load_state_dict(expand_shared_state(native,{k[6:]:v for k,v in state.items()}),strict=True)
    del state
    native=native.cuda().eval()
    with torch.inference_mode(),torch.autocast('cuda',dtype=torch.bfloat16):
        full=native(prep.unsqueeze(1))['depth']
        stripped=candidate.model(prep.unsqueeze(1))['depth']
    torch.testing.assert_close(full,stripped,rtol=0,atol=0)
    print('DA3_CAMERA_GS_PRUNING_BIT_EXACT',flush=True)
    del native
    baseline=candidate.infer(x,edge_dilation=(2,1))
    batch=x.repeat(2,1,1,1)
    settings['da3_microbatch']=2
    both=candidate.infer(batch,edge_dilation=(2,1))
    torch.testing.assert_close(both[0:1],baseline,rtol=.01,atol=.002)
    assert float(baseline.std())>.001
    print('DA3_MICROBATCH_PARITY_OK peak_vram_mb='+str(torch.cuda.max_memory_allocated()//1024**2),flush=True)


def main(args):
    from iw3_da3_install import catalog, ready
    out=Path(tempfile.mkdtemp(prefix='iw3-da3-',dir=REPO/'qa-output'))
    print('QA_OUTPUT '+str(out),flush=True)
    root=args.root
    source=REPO/'qa-output/v22-record-real-1440p.mp4'
    frames,output_mode,geometry=13,'1440p',[5120,1440]
    if args.native_4k:
        source=REPO/'qa-output/temporal-atlas-v39/person-source-uhd-portrait.mp4'
        frames,output_mode,geometry=8,'Source',[4320,3840]
    results=[]
    for m in catalog(root)['models']:
        if args.models and m['id'] not in args.models:continue
        deadline=time.monotonic()+1800
        while not ready(root,m['id']) and time.monotonic()<deadline:
            print('QA_WAIT_INSTALL '+m['id'],flush=True)
            time.sleep(30)
        if not ready(root,m['id']):raise RuntimeError('DA3 installation did not finish: '+m['id'])
        settings={'depth_model':m['id'],'resolution':392 if 'Giant' in m['id'] else 518,
                  'method':args.method,'batch_size':2,'da3_microbatch':1}
        config=out/(m['id']+'.json');config.write_text(json.dumps(settings),encoding='utf-8')
        output=out/(m['id']+'.mp4')
        command=[sys.executable,'-s','-B',str(REPO/'python/iw3_worker.py'),'--root',str(root),
                 '--input',str(source),'--output',str(output),'--settings',str(config),'--frames',str(frames),
                 '--output-mode',output_mode]
        with (out/(m['id']+'.log')).open('w',encoding='utf-8') as log:
            child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,encoding='utf-8',errors='replace')
            for line in child.stdout:
                log.write(line);log.flush()
                if line.startswith(('STUDIO_RESULT','STUDIO_ERROR','IW3_DA3','IW3_ENGINE')):print(line.rstrip(),flush=True)
            code=child.wait()
        if code:
            results.append({'model':m['id'],'exit_code':code});continue
        info=json.loads(output.with_suffix('.summary.json').read_text(encoding='utf-8'))
        assert info['frames']==frames
        if not args.native_4k:assert info['audio_present']
        assert info['container_geometry']==geometry
        subprocess.run([str(root/'tools/ffmpeg.exe'),'-v','error','-xerror','-i',str(output),'-f','null','NUL'],check=True)
        subprocess.run([str(root/'tools/ffmpeg.exe'),'-v','error','-i',str(output),'-vf','select=eq(n\\,6),scale=2560:-2',
                        '-frames:v','1',str(out/(m['id']+'.png'))],check=True)
        results.append({'model':m['id'],'exit_code':0,'result':info})
    (out/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
    print('QA_DONE '+str(out),flush=True)
    if any(r['exit_code'] for r in results):raise SystemExit(1)


if __name__=='__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--models',nargs='+')
    parser.add_argument('--parity',action='store_true')
    parser.add_argument('--native-4k',action='store_true')
    parser.add_argument('--method',choices=['row_flow_v3','mlbw_l2_inpaint'],default='row_flow_v3')
    args=parser.parse_args()
    if args.parity:
        # Provider registers its pinned DA3 source before importing model API.
        import iw3_worker
        iw3_worker.configure_imports(args.root)
        from iw3_da3_install import catalog
        sys.path.insert(0,str(args.root/catalog(args.root)['sources']['official']['path']/'src'))
        parity(args.root)
    else:main(args)
