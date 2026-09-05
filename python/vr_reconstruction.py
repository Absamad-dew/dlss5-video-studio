"""Studio-owned stereo maps, bounded temporal reconstruction and sparse IW3 net.

No monkeypatching of upstream IW3. All geometry coordinates are float32, in
normalized source-image coordinates (0..1), never an eye-image optical flow.
"""
from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
import math
import cv2
import numpy as np
import torch
import torch.nn.functional as F


def grid01(height, width, device):
    y, x = torch.meshgrid(torch.linspace(0, 1, height, device=device),
                          torch.linspace(0, 1, width, device=device), indexing='ij')
    return torch.stack((x, y))[None]


def sample(image, coords, padding='border'):
    return F.grid_sample(image.float(), coords.permute(0, 2, 3, 1) * 2 - 1,
                         mode='bilinear', padding_mode=padding, align_corners=True)


def sample_u8(image, coords):
    """Bilinear gather in native uint8 RGB; convert only sampled pixels to float."""
    b,c,h,w=image.shape
    sx=coords[:,0].clamp(0,1)*(w-1);sy=coords[:,1].clamp(0,1)*(h-1)
    x0=sx.floor().long();y0=sy.floor().long()
    x1=(x0+1).clamp_max(w-1);y1=(y0+1).clamp_max(h-1)
    fx=(sx-x0).unsqueeze(1);fy=(sy-y0).unsqueeze(1)
    def get(x,y):
        indices=(y*w+x).reshape(b,1,-1).expand(-1,c,-1)
        return image.reshape(b,c,-1).gather(2,indices).reshape(b,c,*sx.shape[1:]).float()
    return get(x0,y0)*(1-fx)*(1-fy)+get(x1,y0)*fx*(1-fy)+get(x0,y1)*(1-fx)*fy+get(x1,y1)*fx*fy


class RowFlowRenderer:
    """Batch both eyes with exact upstream flips and sequential RGB resampling."""
    def __init__(self, model):
        self.model = model
        self.grids = {}

    def __call__(self, rgb, depth, divergence, convergence, steps, anchor, preserve_border):
        from iw3.backward_warp import make_input_tensor, make_grid, backward_warp
        h, w = depth.shape[-2:]
        key = h, w
        if key not in self.grids:
            if len(self.grids) >= 4:
                self.grids.clear()
            self.grids[key] = make_grid(1, w, h, depth.device)
        grid = self.grids[key]
        sides = [-1, 1] if anchor == 'symmetric' else ([1] if anchor == 'left' else [-1])
        d = torch.cat([depth.flip(-1) if side > 0 else depth for side in sides])
        colour = torch.cat([rgb.flip(-1) if side > 0 else rgb for side in sides]).float()
        identity = grid01(*rgb.shape[-2:], rgb.device)
        coords = torch.cat([identity.flip(-1) if side > 0 else identity for side in sides])
        scale = torch.tensor(1.0 / (w // 2 - 1), device=rgb.device, dtype=torch.float32)
        delta_steps = []
        amount = divergence * (1 if anchor == 'symmetric' else 2) / steps
        for step in range(steps):
            inputs = torch.stack([make_input_tensor(None, item, divergence=amount,
                convergence=convergence, image_width=max(h, w),
                preserve_screen_border=preserve_border) for item in d])
            with torch.autocast('cuda', dtype=torch.float16, enabled=rgb.is_cuda):
                delta = self.model(inputs)
            delta_steps.append(delta)
            if step + 1 < steps:
                d = backward_warp(d, grid, delta, scale)
        for delta in delta_steps:
            colour = backward_warp(colour, grid, delta, scale)
            coords = backward_warp(coords, grid, delta, scale)
        outputs = {side: (colour[i:i+1].flip(-1), coords[i:i+1].flip(-1)) if side > 0
                   else (colour[i:i+1], coords[i:i+1]) for i, side in enumerate(sides)}
        return outputs.get(-1, (rgb, identity)), outputs.get(1, (rgb, identity))


def plan_tiles(mask, core=256, halo=192):
    """Union temporal support; fixed global tile origins preserve GMLP phase."""
    if mask.ndim != 4:
        raise ValueError('mask must be Tx1xHxW')
    h, w = mask.shape[-2:]
    if mask.device.type == 'cpu':
        # Do NOT expand twelve 4K boolean masks to float and run a 15x15
        # PyTorch CPU max-pool. Its O(225*pixels) work outweighed the CUDA net.
        support = mask.numpy().any(axis=(0,1)).astype(np.uint8)
        support = cv2.dilate(support,np.ones((15,15),np.uint8))
        padded = np.pad(support,((0,(-h)%core),(0,(-w)%core)))
        active = padded.reshape(math.ceil(h/core),core,math.ceil(w/core),core).any(axis=(1,3))
    else:
        support = mask.amax(0,keepdim=True).float()
        support = F.max_pool2d(support,(15,1),1,(7,0))
        support = F.max_pool2d(support,(1,15),1,(0,7))
        active = F.max_pool2d(support,core,stride=core,ceil_mode=True)[0,0].cpu().numpy()>0
    tiles = []
    # Merge horizontal neighbours; never union distant islands to reduce launches.
    rectangles = []
    for row in range(active.shape[0]):
        start = None
        for col in range(active.shape[1] + 1):
            enabled = col < active.shape[1] and active[row, col]
            if enabled and start is None:
                start = col
            elif not enabled and start is not None:
                rectangles.append((start, row, col, row + 1))
                start = None
    # Bound core area so a full-frame hole also fits a laptop. Rows up to two
    # adjacent cells are merged; wide runs are split without reducing resolution.
    cores=[]
    for left, top, right, bottom in rectangles:
        for x in range(left, right, 2):
            x0, y0, x1, y1 = x*core, top*core, min(w, min(x+2,right)*core), min(h,bottom*core)
            # Merge identical neighbouring columns before adding their halos.
            # Keeps disjoint core ownership and a <= 512x768 core footprint.
            merged=False
            for i,old in enumerate(cores):
                if old[0]==x0 and old[2]==x1 and old[3]==y0 and y1-old[1]<=core*3:
                    cores[i]=(x0,old[1],x1,y1);merged=True;break
            if not merged:
                cores.append((x0,y0,x1,y1))
    for x0,y0,x1,y1 in cores:
        outer = (max(0, (x0-halo)//64*64), max(0,(y0-halo)//64*64),
                 min(w, math.ceil((x1+halo)/64)*64), min(h,math.ceil((y1+halo)/64)*64))
        tiles.append(((x0,y0,x1,y1), outer))
    return tiles


class SparseVideoInpaint:
    """Original 12-frame model, native RGB crops, pre-temporal feature cache.

    Cache keys are stable frame ids plus eye/scene/crop, not a moving local index.
    Only unmodified seed inputs are cached; Atlas updates require a new key.
    """
    def __init__(self, model, cache_mb=256, halo=192, core=256):
        self.model = model
        self.cache = OrderedDict()
        self.cache_bytes = 0
        self.cache_limit = int(cache_mb * 1024**2)
        self.halo, self.core = halo, core
        self.stats = {'calls': 0, 'tiles': 0, 'cache_hits': 0, 'encoded_frames': 0,
                      'decoded_frames': 0, 'processed_crop_pixels': 0}

    def reset(self):
        self.cache.clear()
        self.cache_bytes = 0

    def _remember(self, key, value):
        size = sum(t.numel()*t.element_size() for t in value)
        if size > self.cache_limit:
            return
        while self.cache and self.cache_bytes + size > self.cache_limit:
            _, old = self.cache.popitem(last=False)
            self.cache_bytes -= sum(t.numel()*t.element_size() for t in old)
        self.cache[key] = value
        self.cache_bytes += size

    def crop(self, image, mask, keys, outputs):
        from nunif.modules.permute import pixel_unshuffle, pixel_shuffle
        from nunif.modules.replication_pad2d import replication_pad2d_naive
        from iw3.models.light_video_inpaint_v1 import GMLP3DBlock
        if image.shape[0] != 12 or len(keys) != 12:
            raise ValueError('The original video model requires exactly 12 context frames')
        model = self.model
        src, blurred = model.preprocess(image, mask)
        h, w = image.shape[-2:]
        pad = (0, 64-w%64, 0, 64-h%64)
        x = replication_pad2d_naive((src-.5)/.5, pad, detach=True)
        m = replication_pad2d_naive(blurred, pad, detach=True)
        m = pixel_unshuffle(m, 4).amax(1, keepdim=True) > .99
        first, second = [], []
        # Pair microbatch matches upstream's default kernel shapes when uncached.
        for start in range(0, 12, 2):
            pair_keys = keys[start:start+2]
            missing = any(key not in self.cache for key in pair_keys)
            values = None
            if missing:
                z = F.leaky_relu(model.patch(x[start:start+2]), .1, inplace=True)
                z = torch.where(m[start:start+2], model.mask_bias.to(z.dtype), z)
                x1 = model.enc1(z)
                x2 = model.down(x1)
                # First enc2 block is frame-local. No post-temporal values are cached.
                x2 = model.enc2[0](x2)
                values = [(x1[i:i+1].clone(), x2[i:i+1].clone()) for i in range(2)]
                self.stats['encoded_frames'] += 2
            for i, key in enumerate(pair_keys):
                if key in self.cache:
                    value = self.cache.pop(key)
                    self.cache[key] = value
                    self.stats['cache_hits'] += 1
                else:
                    value = values[i]
                    self._remember(key, value)
                first.append(value[0]); second.append(value[1])
        x2 = torch.cat(second)
        for block in model.enc2[1:]:
            x2 = block(x2) if isinstance(block, GMLP3DBlock) else torch.cat(
                [block(x2[i:i+2]) for i in range(0,12,2)])
        selected = torch.as_tensor(outputs, device=image.device)
        skip = torch.cat(first).index_select(0, selected)
        x2 = x2.index_select(0, selected)
        decoded = []
        for i in range(0, len(outputs), 2):
            z = F.pixel_shuffle(model.up(x2[i:i+2]), 2)
            z = model.to_image(model.dec1(skip[i:i+2]+z))
            decoded.append(z)
        predicted = pixel_shuffle(torch.cat(decoded), 4)[...,:h,:w]
        self.stats['decoded_frames'] += len(outputs)
        alpha = blurred.index_select(0, selected)
        return (src.index_select(0, selected)*(1-alpha)+predicted*alpha).clamp(0,1)

    @torch.inference_mode()
    def reconstruct(self, images, masks, frame_ids, outputs, *, eye=0, epoch=0, strength=1):
        """Inputs can be CPU uint8: only the active native-resolution crops upload."""
        device = next(self.model.parameters()).device
        h,w = images[0].shape[-2:]
        masks = torch.stack(masks)
        result = [images[i].clone() for i in outputs]
        # Tile origins must be aligned in the NETWORK's orientation, including
        # widths not divisible by 64. Flipping each already-planned crop is wrong.
        if eye == 0:
            masks = masks.flip(-1)
        for core, outer in plan_tiles(masks, self.core, self.halo):
            x0,y0,x1,y1 = outer
            if eye == 0:
                clip = torch.stack([v[...,y0:y1,w-x1:w-x0] for v in images]).to(device).flip(-1).float()/255
            else:
                clip = torch.stack([v[...,y0:y1,x0:x1] for v in images]).to(device).float()/255
            mask = masks[...,y0:y1,x0:x1].to(device).float()
            keys = [(epoch, eye, outer, frame_ids[i]) for i in range(12)]
            with torch.autocast('cuda', dtype=torch.float16, enabled=device.type=='cuda'):
                out = self.crop(clip, mask, keys, outputs)
            # Publish only core ownership and the original (non-blurred) unknown
            # mask. Trusted source pixels remain byte-identical.
            a,b,c,d = core
            out = out[...,b-y0:d-y0,a-x0:c-x0]
            for j,i in enumerate(outputs):
                alpha = masks[i,...,b:d,a:c].to(device)*strength
                if eye == 0:
                    current = result[j][...,b:d,w-c:w-a]
                    prediction,alpha = out[j].flip(-1),alpha.flip(-1)
                else:
                    current = result[j][...,b:d,a:c]
                    prediction = out[j]
                fused = current.to(device).float().lerp(prediction*255, alpha)
                current.copy_(fused.round().clamp(0,255).byte().to(current.device))
            self.stats['tiles'] += 1
            self.stats['processed_crop_pixels'] += (x1-x0)*(y1-y0)*12
        self.stats['calls'] += 1
        return result


@dataclass
class BackgroundLink:
    matrix: np.ndarray | None
    confidence: float
    reason: str = 'accepted'
    flow: np.ndarray | None = None
    valid: np.ndarray | None = None


def source_flow_link(previous,current,previous_depth,current_depth):
    """Dense source-space fallback for parallax that a single homography cannot fit.

    Flow is never sampled on the occluder: the renderer supplies an observed
    background anchor. Forward/backward, colour and depth validate that anchor.
    """
    h,w=current.shape[:2]
    a=cv2.cvtColor(current,cv2.COLOR_RGB2GRAY);b=cv2.cvtColor(previous,cv2.COLOR_RGB2GRAY)
    dis=cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_FAST)
    dis.setVariationalRefinementIterations(2)
    flow=dis.calc(a,b,None);reverse=dis.calc(b,a,None)
    y,x=np.mgrid[:h,:w].astype(np.float32)
    mx=x+flow[...,0];my=y+flow[...,1]
    backwards=cv2.remap(reverse,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
    roundtrip=np.linalg.norm(flow+backwards,axis=2)<.75
    other=cv2.remap(previous,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
    photo=np.abs(current.astype(np.float32)-other.astype(np.float32)).mean(2)<12
    depth=cv2.resize(current_depth.astype(np.float32),(w,h))
    prior=cv2.resize(previous_depth.astype(np.float32),(w,h))
    prior=cv2.remap(prior,mx,my,cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
    valid=roundtrip&photo&(np.abs(depth-prior)<.06)&(mx>=0)&(mx<w-1)&(my>=0)&(my<h-1)
    normalized=flow/np.array([w-1,h-1],np.float32)
    return BackgroundLink(None,1.,'source-flow',normalized,valid.astype(np.float32))


def background_link(previous, current, previous_depth, current_depth):
    """Conservative background registration; no foreground flow across an occluder.

    Small guide images only. RANSAC rejects moving people; depth masks select far
    observations. Unsupported/non-planar backgrounds remain neural residuals.
    Matrix maps current source coordinates to previous source coordinates.
    """
    h,w = current.shape[:2]
    masks=[]
    for depth in (previous_depth,current_depth):
        depth=cv2.resize(depth.astype(np.float32),(w,h),interpolation=cv2.INTER_LINEAR)
        # DA3 sky is exactly the far plane: a large sky must not push every
        # textured building out of the feature mask through a global quantile.
        non_sky=depth[depth>.015]
        cutoff=np.quantile(non_sky,.80) if non_sky.size else 1.
        masks.append(((depth>.015)&(depth<=cutoff)).astype(np.uint8)*255)
    orb=cv2.ORB_create(nfeatures=1400,fastThreshold=12)
    kp0,des0=orb.detectAndCompute(cv2.cvtColor(previous,cv2.COLOR_RGB2GRAY),masks[0])
    kp1,des1=orb.detectAndCompute(cv2.cvtColor(current,cv2.COLOR_RGB2GRAY),masks[1])
    if des0 is None or des1 is None:
        return BackgroundLink(None,0,'no-features')
    matches=cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(des1,des0,k=2)
    good=[m[0] for m in matches if len(m)==2 and m[0].distance < .72*m[1].distance]
    if len(good)<18:
        return BackgroundLink(None,0,'few-matches')
    src=np.float32([kp1[m.queryIdx].pt for m in good]); dst=np.float32([kp0[m.trainIdx].pt for m in good])
    matrix,inliers=cv2.findHomography(src,dst,cv2.RANSAC,1.0)
    if matrix is None or inliers is None or inliers.sum()<16:
        return BackgroundLink(None,0,'few-inliers')
    pts=src[inliers[:,0]>0]
    if np.ptp(pts[:,0])<w*.35 or np.ptp(pts[:,1])<h*.20:
        return BackgroundLink(None,0,'narrow-coverage')
    confidence=float(inliers.mean())
    scale=np.diag([w-1,h-1,1.0]); matrix=np.linalg.inv(scale)@matrix@scale
    if confidence<.70 or not np.isfinite(matrix).all() or abs(np.linalg.det(matrix))<.1:
        return BackgroundLink(None,0,'low-confidence')
    return BackgroundLink(matrix,confidence)


def map_homography(coords, matrix):
    homogeneous=torch.cat((coords,torch.ones_like(coords[:,:1])),1)
    m=torch.as_tensor(matrix,dtype=torch.float32,device=coords.device)
    q=torch.einsum('ij,bjhw->bihw',m,homogeneous)
    return q[:,:2]/q[:,2:].clamp_min(1e-6)


def restore_background(seed, holes, target_source, target_depth, background_coords,
                       background_depth, donor_source, donor_depth, matrix, confidence,
                       tolerance=.08, flow=None, flow_valid=None, anchor_coords=None):
    """Paste only verified source samples; RGB always sampled at native size."""
    if flow is not None:
        coords=background_coords+sample(flow,anchor_coords)
        anchor_ok=sample(flow_valid,anchor_coords)>.999
        # The anchor must belong to the requested BACKGROUND plane. A valid
        # foreground flow is still the wrong donor for a newly exposed hole.
        anchor_ok &= (sample(target_depth,anchor_coords)-background_depth).abs()<tolerance
    else:
        coords=map_homography(background_coords,matrix)
        anchor_ok=True
    valid=((coords>=0)&(coords<=1)).all(1,keepdim=True)
    sampled_depth=sample(donor_depth,coords)
    depth_ok=(sampled_depth-background_depth).abs() <= tolerance
    # Validate around the target source position on observed background, not
    # against the occluding foreground occupying the missing point itself.
    identity=grid01(*target_depth.shape[-2:],target_depth.device)
    observed=identity+sample(flow,identity) if flow is not None else map_homography(identity,matrix)
    target_small=sample_u8(target_source,identity)/255
    donor_small=sample_u8(donor_source,observed)/255
    # A flat foreground object is not a background observation, even if its
    # depth matches its local mean. Reject it from photometric validation.
    far=(target_depth <= torch.quantile(target_depth,.60)+.01)
    error=(target_small-donor_small).abs().mean(1,keepdim=True)
    weight=F.avg_pool2d(far.float(),15,1,7)
    error=F.avg_pool2d(error*far,15,1,7)/weight.clamp_min(.01)
    local_ok=sample(((error<.055)&(weight>.35)).float(),background_coords)>.995
    eligible=holes&valid&depth_ok&local_ok&anchor_ok&(confidence>=.70)
    rows,cols=eligible[0,0].nonzero(as_tuple=True)
    output=seed.clone()
    if rows.numel():
        points=coords[:,:,rows,cols].unsqueeze(2)
        colour=sample_u8(donor_source,points)[0,:,0]
        output[0,:,rows,cols]=colour.round().clamp(0,255).byte()
    return output,holes&~eligible,eligible
