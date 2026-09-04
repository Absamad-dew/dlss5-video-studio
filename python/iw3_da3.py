"""DA3 depth-provider extension; original iw3 stereo and inpaint remain untouched.

Main-series images are independent monocular predictions, NOT video-window DA3
or Gaussian rendering. iw3's lookahead EMA provides range stabilization.
"""
import math
import sys

from iw3_da3_install import catalog, get_model, ready


def is_da3(root, model_id):
    return model_id in {m['id'] for m in catalog(root)['models']}


def require_ready(root, model_id):
    if not ready(root, model_id):
        raise RuntimeError('DA3 model is not installed/verified: ' + model_id +
                           '. In the iw3 tab click "Установить выбранную DA3" or run '
                           'scripts/Install-Iw3Da3.ps1 -Model ' + model_id)


def expand_shared_state(net, state):
    """HF safetensors deduplicates shared LayerNorms in DualDPT's ModuleList.

    Restore only names proven to reference the same parameter object in the
    instantiated architecture. Real missing parameters must still fail strict load.
    """
    aliases={}
    for name,value in net.state_dict(keep_vars=True).items():
        aliases.setdefault(id(value),[]).append(name)
    expanded=dict(state)
    for names in aliases.values():
        present=[name for name in names if name in state]
        if present:
            for name in names:
                if name not in expanded: expanded[name]=state[present[0]]
    return expanded


def create_provider(root, settings):
    import torch
    from torchvision.transforms import functional as TF
    from iw3.base_depth_model import BaseDepthModel
    from iw3.depth_scaler import EMAMinMaxScaler
    from iw3.depth_anything_model import batch_preprocess
    from iw3.dilation import dilate_edge, edge_dilation_is_enabled
    from iw3.models import DepthAA

    m = get_model(root, settings['depth_model'])
    require_ready(root, m['id'])
    source = catalog(root)['sources'][m['source']]
    sys.path.insert(0, str(root/source['path']/'src'))

    class DA3Provider(BaseDepthModel):
        def create_depth_scaler(self):
            # Same disparity scaling as original Any_V3_Mono. Far plane remains 0.
            return EMAMinMaxScaler(decay=0, buffer_size=1, mode='max')

        @classmethod
        def get_name(cls): return 'StudioDA3'
        @classmethod
        def supported(cls, name): return name == m['id']
        @classmethod
        def has_checkpoint_file(cls, name): return ready(root, name)
        @classmethod
        def get_model_path(cls, name): return str(root/get_model(root,name)['path'])
        @classmethod
        def multi_gpu_supported(cls, name): return False
        @classmethod
        def force_update(cls): raise RuntimeError('Use the pinned DA3 installer')
        def is_metric(self): return False

        def load_model(self, model_type, resolution=None, device=None, **kwargs):
            from depth_anything_3.cfg import create_object, load_config
            from depth_anything_3.registry import MODEL_REGISTRY
            from safetensors import safe_open
            config = load_config(MODEL_REGISTRY[m['config']])
            # These downstream branches do not feed depth. Do not allocate the
            # Giant GS head or load e3nn/gsplat just to produce disparity for iw3.
            unused = ('cam_enc.', 'cam_dec.', 'gs_head.', 'gs_adapter.')
            for key in ('cam_enc','cam_dec','gs_head','gs_adapter'):
                config[key] = None
            from torch.overrides import TorchFunctionMode
            class InitScalarsOnCPU(TorchFunctionMode):
                def __torch_function__(self, func, types, args=(), kwargs=None):
                    kwargs = dict(kwargs or {})
                    # DINO constructs a tiny stochastic-depth schedule with
                    # linspace(...).item(). Parameters can still live on meta.
                    if func is torch.linspace: kwargs['device']='cpu'
                    return func(*args,**kwargs)
            with torch.device('meta'), InitScalarsOnCPU():
                net = create_object(config)
            # mmap + assign avoids a random-initialized CPU copy of huge weights.
            state = {}
            with safe_open(str(root/m['path']), framework='pt', device='cpu') as checkpoint:
                for key in checkpoint.keys():
                    if not key.startswith('model.'):
                        raise RuntimeError('Unexpected DA3 checkpoint key: '+key)
                    name = key[6:]
                    if not name.startswith(unused):
                        state[name] = checkpoint.get_tensor(key)
            net.load_state_dict(expand_shared_state(net,state), strict=True, assign=True)
            del state
            self.resolution = math.ceil((resolution or 518)/14)*14
            self.depth_aa = DepthAA().load().eval().to(device) if m['source']=='iw3' else None
            print('IW3_DA3_PROVIDER '+m['id']+' revision='+m['revision']+
                  ' depth_resolution='+str(self.resolution)+' rgb_resolution=preserved '
                  'temporal=iw3-ema attention=pytorch-sdpa unused-camera-gs=not-loaded',flush=True)
            return net

        def predict(self, x, enable_amp):
            dtype = torch.bfloat16 if x.device.type=='cuda' and torch.cuda.is_bf16_supported() else torch.float16
            with torch.autocast(device_type=x.device.type, dtype=dtype, enabled=enable_amp):
                prediction = self.model(x.unsqueeze(1))
            depth = prediction['depth'].float()
            if depth.ndim != 4 or depth.shape[1] != 1:
                raise RuntimeError('Unexpected DA3 depth dimensions: '+str(depth.shape))
            if not torch.isfinite(depth).all():
                raise RuntimeError('DA3 returned NaN/Inf. Try FP32 or a smaller depth input; model not substituted.')
            shift = settings['da3_depth_shift']
            disparity = (depth.clamp_min(0)+max(shift,1e-6)).reciprocal()
            if 'sky' in prediction:
                sky = prediction['sky'].float()
                weight = (sky.clamp(.3,1)-.3)/.7 * settings['da3_sky_strength']
                disparity = disparity*(1-weight)
                # Original iw3 treats a virtually all-sky image as the far plane.
                non_sky = (sky<=.3).flatten(1).sum(1)
                if settings['da3_sky_strength']==1:
                    disparity[non_sky<10] = 0
            return disparity

        @torch.inference_mode()
        def infer(self, x, tta=False, low_vram=False, enable_amp=True, edge_dilation=0,
                  depth_aa=False, **kwargs):
            if not torch.is_tensor(x):
                x = TF.to_tensor(x)
            single = x.ndim == 3
            if single: x=x.unsqueeze(0)
            output_device=x.device
            # Preprocess each microbatch separately: never copy a full 4K RGB
            # batch to GPU just to resize it. No tiling or output downscale.
            chunk_size = 1 if low_vram else int(settings['da3_microbatch'])
            results=[]
            for chunk in x.split(chunk_size):
                prep=batch_preprocess(chunk.to(self.device), self.resolution,
                                      limit_resolution=self.limit_resolution)
                def post(value):
                    if depth_aa:
                        if self.depth_aa is None:
                            raise ValueError('iw3 DepthAA is not trained for DA3 Main; disable DepthAA.')
                        value=self.depth_aa.infer(value)
                    if edge_dilation_is_enabled(edge_dilation):
                        value=dilate_edge(value,edge_dilation)
                    return value
                out=post(self.predict(prep,enable_amp))
                if tta:
                    # Sequential flip has the same arithmetic, lower peak VRAM.
                    flipped=post(self.predict(prep.flip(-1),enable_amp)).flip(-1)
                    out=(out+flipped)*.5
                results.append(out.to(output_device))
            result=torch.cat(results)
            return result[0] if single else result

    return DA3Provider(m['id'])
