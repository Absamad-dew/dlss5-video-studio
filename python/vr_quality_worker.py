"""Studio native VR: raw shared depth -> stereo -> source donors -> sparse video net.

The separate IW3 entry point does not import this module. RGB is rendered at the
input raster; half-SBS/OU is a final packing operation, never a depth shortcut.
The bounded temporal queue lives in CPU uint8, not full-resolution GPU float32.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
import subprocess
import tempfile
import time

import cv2
import numpy as np
import torch
import torch.nn.functional as F

import vr_depth_worker as legacy
from vr_shared_depth import raw_depth_frames, RawDepthWriter, DepthSample
from vr_reconstruction import (RowFlowRenderer, SparseVideoInpaint, grid01, sample,
                               background_link, source_flow_link, restore_background)


@dataclass
class Packet:
    index: int
    source: torch.Tensor
    depth: torch.Tensor
    eyes: list
    masks: list
    background: list
    repaired: bool = False
    guides: np.ndarray | None = None


class TemporalReconstructor:
    """12 original network frames; six owned outputs, three context on each side.

    An extra three source donors finalize context frames before caching features.
    Frames are repaired only once, so frame/eye/scene/crop cache keys are stable.
    All queues and model features are bounded independently of movie duration.
    """
    def __init__(self, emit, model=None, atlas=True, cache_mb=256, halo=192, strength=1,
                 atlas_executor='gpu-sparse'):
        self.emit = emit
        self.net = SparseVideoInpaint(model, cache_mb, halo) if model is not None else None
        self.atlas, self.strength = atlas, strength
        self.packets = {}
        self.first = self.next = self.last = None
        self.epoch = 0
        self.stats = {'source_repaired_pixels': 0, 'residual_pixels': 0,
                      'registered_pairs': 0, 'rejected_pairs': 0, 'max_queue_frames': 0,
                      'published_frames': 0, 'scenes': 0}
        self.stats['registration_rejections'] = {}
        self.stats['source_flow_pairs'] = 0
        self.links = {}
        self.gpu_atlas = None
        if atlas and atlas_executor == 'gpu-sparse':
            from vr_atlas import GpuAtlas
            self.gpu_atlas = GpuAtlas(self.stats)

    def append(self, packet, cut=False):
        if cut and self.packets:
            self.flush()
        if not self.packets:
            self.first = self.next = packet.index
            self.stats['scenes'] += 1
        self.last = packet.index
        self.packets[packet.index] = packet
        if self.gpu_atlas:
            self.gpu_atlas.prefetch(packet, self.packets)
        self.stats['max_queue_frames'] = max(self.stats['max_queue_frames'],len(self.packets))
        # Outputs 0..5, network context -3..8, source donors through +11.
        while self.last >= self.next + 11:
            self._publish(6)

    def _repair(self, p):
        if p.repaired:
            return
        if self.gpu_atlas is not None:
            if any(bool(m.any()) for m in p.masks):
                self.gpu_atlas.repair(p, self.packets)
            self.stats['residual_pixels'] += sum(int(m.sum()) for m in p.masks)
            p.repaired = True
            return
        if self.atlas and any(bool(m.any()) for m in p.masks):
            device = torch.device('cuda')
            target = p.source[None].to(device)
            target_depth = p.depth[None,None].to(device)
            for offset in (-1,1,-2,2,-3,3):
                donor = self.packets.get(p.index+offset)
                if donor is None:
                    continue
                key = p.index, donor.index
                if key not in self.links:
                    link = background_link(donor.guides,p.guides,donor.depth.numpy(),p.depth.numpy())
                    self.links[key] = link
                    self.stats['registered_pairs' if link.matrix is not None else 'rejected_pairs'] += 1
                    if link.matrix is None:
                        reasons=self.stats['registration_rejections']
                        reasons[link.reason]=reasons.get(link.reason,0)+1
                        link=source_flow_link(donor.guides,p.guides,donor.depth.numpy(),p.depth.numpy())
                        self.links[key]=link
                        self.stats['source_flow_pairs']+=1
                link = self.links[key]
                if link.matrix is None and link.flow is None:
                    continue
                source = donor.source[None].to(device)
                donor_depth = donor.depth[None,None].to(device)
                for eye in range(2):
                    if not bool(p.masks[eye].any()):
                        continue
                    coords, far_depth, anchor = p.background[eye]
                    # Coordinate maps stay compressed spatially in the CPU queue;
                    # native RGB is sampled only after the map is reconstructed.
                    coords = F.interpolate(coords[None].to(device),size=p.source.shape[-2:],
                                           mode='bilinear',align_corners=True)
                    far_depth = F.interpolate(far_depth[None].to(device),size=p.source.shape[-2:],
                                             mode='bilinear',align_corners=True)
                    anchor = F.interpolate(anchor[None].to(device),size=p.source.shape[-2:],mode='bilinear',align_corners=True)
                    flow=None if link.flow is None else torch.from_numpy(link.flow).permute(2,0,1)[None].to(device)
                    flow_valid=None if link.valid is None else torch.from_numpy(link.valid)[None,None].to(device)
                    out, mask, accepted = restore_background(p.eyes[eye][None].to(device),
                        p.masks[eye][None].to(device),target,target_depth,coords,far_depth,
                        source,donor_depth,link.matrix,link.confidence,
                        flow=flow,flow_valid=flow_valid,anchor_coords=anchor)
                    self.stats['source_repaired_pixels'] += int(accepted.sum().item())
                    p.eyes[eye],p.masks[eye] = out[0].cpu(),mask[0].cpu()
        self.stats['residual_pixels'] += sum(int(m.sum()) for m in p.masks)
        p.repaired = True

    def _publish(self, count):
        ids = [max(self.first,min(self.last,self.next+i)) for i in range(-3,9)]
        window = [self.packets[i] for i in ids]
        for p in window:
            self._repair(p)
        outputs = list(range(3,3+count))
        eyes = []
        for eye in range(2):
            images = [p.eyes[eye] for p in window]
            masks = [p.masks[eye] for p in window]
            if self.net is not None and any(bool(m.any()) for m in masks):
                result = self.net.reconstruct(images,masks,ids,outputs,eye=eye,
                                               epoch=self.epoch,strength=self.strength)
            else:
                result = [images[i] for i in outputs]
            eyes.append(result)
        for j in range(count):
            self.emit(eyes[0][j],eyes[1][j])
            self.stats['published_frames'] += 1
        self.next += count
        # Three temporal context frames and three earlier source donors.
        keep = self.next-6
        self.packets = {i:p for i,p in self.packets.items() if i >= keep}
        self.links = {k:v for k,v in self.links.items() if min(k) >= keep}
        if self.gpu_atlas:
            self.gpu_atlas.prune(keep)

    def flush(self):
        if self.next is not None:
            while self.next <= self.last:
                self._publish(min(6,self.last-self.next+1))
        self.packets.clear(); self.links.clear()
        if self.gpu_atlas:
            self.gpu_atlas.clear()
        if self.net:
            self.net.reset()
        self.first = self.next = self.last = None
        self.epoch += 1


def geometry_mask(depth, disparity, coords, shift, z_strength, layers, convergence, divergence):
    """A missing geometric sample alone is insufficient to overwrite RowFlow.

    Verify its ACTUAL backward coordinate by projecting it into the target. Only
    uncovered pixels with an inconsistent source owner may be reconstructed.
    """
    h,w = coords.shape[-2:]
    x = torch.arange(w,device=depth.device,dtype=torch.float32)[None].expand(h,-1)
    rows = (torch.arange(h,device=depth.device,dtype=torch.int64)[:,None]*w).expand(-1,w)
    full_depth = F.interpolate(depth,size=(h,w),mode='bilinear',align_corners=True)
    far,valid = legacy.forward_splat(full_depth,full_depth,disparity,x,rows,shift,z_strength,layers)
    missing = ~valid
    actual_disp = sample(disparity[None,None],coords)
    projected_x = coords[:,:1]*(w-1)+actual_disp*shift
    inconsistent = (projected_x-x[None,None]).abs() > 1.5
    holes = missing & inconsistent
    # Fill background DISPARITY from the appropriate visible side, then solve
    # target->background source coordinate, not target->nearest edge coordinate.
    indices = legacy.directional_nearest_indices(valid,prefer_right=shift<0)
    far = torch.where(missing,torch.gather(far,-1,indices),far)
    bg_disp = (far-convergence)*(max(w,h)*divergence/100)
    identity = grid01(h,w,depth.device)
    background_coords = identity.clone()
    background_coords[:,:1] -= bg_disp*shift/max(1,w-1)
    anchor=background_coords.clone()
    anchor[:,:1]=indices.float()/max(1,w-1)-bg_disp*shift/max(1,w-1)
    return holes,background_coords,far,anchor


def native_temporal_depth(depth, previous, motion, amount, cache):
    """Keep canonical depth resolution; lift guide flow using its source raster.

    Legacy smoothing assumed equal depth/guide sizes. Raw DA3 can be 910x518
    while motion is 480x270, and DLSS output may differ from motion's raster.
    """
    if previous is None or amount<=0:
        return depth
    if motion is None:
        return depth.float().lerp(previous.float(),amount)
    records, source_w, source_h = motion
    confidence_np=records['confidence'].astype(np.float32)/255*records['valid'].astype(np.float32)
    divisor=np.maximum(confidence_np,1/255)
    fields=np.stack((records['dx'].astype(np.float32)/divisor,
                     records['dy'].astype(np.float32)/divisor,confidence_np))
    lifted=torch.from_numpy(fields)[None].to(depth.device)
    shape=depth.shape[-2:]
    if lifted.shape[-2:]!=shape:
        lifted=F.interpolate(lifted,size=shape,mode='bilinear',align_corners=True)
    key=('canonical-motion',*shape)
    grid=cache.get(key)
    if grid is None:
        gy,gx=torch.meshgrid(torch.linspace(-1,1,shape[0],device=depth.device),
                            torch.linspace(-1,1,shape[1],device=depth.device),indexing='ij')
        grid=torch.stack((gx,gy),dim=-1)[None]; cache[key]=grid
    delta=torch.stack((lifted[:,0]*2/max(1,source_w-1),lifted[:,1]*2/max(1,source_h-1)),dim=-1)
    warped=F.grid_sample(previous.float(),grid+delta,mode='bilinear',padding_mode='border',align_corners=True)
    blend=(lifted[:,2:3]*amount).clamp(0,amount)
    return depth.float().mul(1-blend).add_(warped.mul(blend))


def run(args):
    if args.right_seed_output or args.right_mask_output or args.right_compose_mask_output or args.left_compose_mask_output:
        raise ValueError('Native VR writes no intermediate masks. Select Legacy for legacy generative backends.')
    if min(args.width,args.height,args.frames,args.fps) <= 0:
        raise ValueError('VR requires positive dimensions, frame count and FPS')
    if args.layout=='half-sbs' and args.width%4 or args.layout=='half-ou' and args.height%4:
        raise ValueError('Half stereo dimensions must be divisible by four for 4:2:0 output')
    paths = sorted(args.depth_directory.glob('chunk-*.vrd'))
    if not paths and not args.native_rgb_pipe:
        raise FileNotFoundError('Raw VR depth cache missing. Restart processing with native VR depth enabled.')
    torch.set_num_threads(min(8,torch.get_num_threads()))
    # Reproducible quality path; no implicit precision downgrade from TF32.
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.backends.cudnn.benchmark = False
    device = torch.device('cuda')
    model,_,dilate = legacy.load_rowflow_v3(args.root)
    renderer = RowFlowRenderer(model)
    inpaint = None
    if args.native_fill == 'temporal-video':
        from nunif.models import load_model
        weight = args.root/'models/iw3/pretrained_models/hub/checkpoints/iw3_light_video_inpaint_v1_20250919.pth'
        if not weight.is_file():
            raise FileNotFoundError('Install IW3 video-inpaint weights first: '+str(weight))
        inpaint,_ = load_model(str(weight),device_ids=[0],weights_only=True)
        inpaint.eval()
    w,h = args.width,args.height
    ow = 2*w if args.layout=='full-sbs' else w
    oh = 2*h if args.layout=='full-ou' else h
    decoder_cmd = [str(args.ffmpeg),'-nostdin','-v','error','-threads','2','-i',str(args.input_video),
        '-vf',f'scale={w}:{h}:flags=lanczos,format=rgb24','-frames:v',str(args.frames),
        '-an','-f','rawvideo','-pix_fmt','rgb24','pipe:1']
    partial = args.output_video.with_name(args.output_video.stem+'.partial'+args.output_video.suffix)
    encoder_cmd = [str(args.ffmpeg),'-y','-nostdin','-v','error','-threads','2','-f','rawvideo',
        '-pix_fmt','rgb24','-s:v',f'{ow}x{oh}','-r',f'{args.fps:.12g}','-i','pipe:0','-an',
        '-c:v','hevc_nvenc' if args.codec=='h265' else 'h264_nvenc']
    encoder_cmd += legacy.encode_options(args.codec,args.pixel_format,args.quality)
    encoder_cmd += ['-frames:v',str(args.frames),'-movflags','+faststart',str(partial)]
    flags = getattr(subprocess,'CREATE_NO_WINDOW',0)
    staging = torch.empty((h,w,3),dtype=torch.uint8,pin_memory=True)
    out_staging = torch.empty((oh,ow,3),dtype=torch.uint8,pin_memory=True)
    started = time.perf_counter()
    totals = {'decode_s':0.,'geometry_s':0.,'reconstruct_s':0.,'encode_submit_s':0.}
    processed = published = 0
    eye_writers=[]
    if args.native_eye_depth:
        for name in ('left','right'):
            folder=args.native_eye_depth/name
            folder.mkdir(parents=True,exist_ok=True)
            eye_writers.append(RawDepthWriter(folder/'chunk-0000.vrd',args.frames,0))
    old_range = old_depth = convergence = None
    grid_cache = {}
    motions = iter(legacy.motion_frames(sorted(args.depth_directory.glob('chunk-*.motion'))))
    args.output_video.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryFile() as de, tempfile.TemporaryFile() as ee:
        decoder = encoder = rgb_pipe = guard = None
        success = False
        try:
            if args.native_rgb_pipe:
                from vr_stream import Guard, PipeReader, depth_stream
                guard = Guard(args.native_controller_pid)
                rgb_pipe = PipeReader(args.native_rgb_pipe, guard)
                rgb_input = rgb_pipe
                samples = depth_stream(args.depth_directory, args.frames, guard, args.native_keep_depth)
                if args.native_ready_file:
                    args.native_ready_file.write_text('ready', encoding='ascii')
                print('VR_STREAM_READY', flush=True)
            else:
                decoder = subprocess.Popen(decoder_cmd,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,
                    stderr=de,creationflags=flags)
                rgb_input = decoder.stdout
                samples = ((*sample, next(motions,None)) for sample in raw_depth_frames(paths))
            encoder = subprocess.Popen(encoder_cmd,stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,
                stderr=ee,creationflags=flags)

            def progress():
                elapsed=time.perf_counter()-started
                info={'frames':published,'prepared_frames':max(processed,published),
                      'total':args.frames,'elapsed_s':elapsed,'fps':published/max(elapsed,1e-6),
                      'eta_s':(args.frames-published)*elapsed/published if published else None,
                      'method':'native-rowflow-v3','queue_frames':len(temporal.packets)}
                print('VR_DEPTH_PROGRESS '+json.dumps(info),flush=True)
                if args.native_ready_file:
                    status=args.native_ready_file.with_suffix('.json')
                    temporary=status.with_suffix('.partial')
                    try:
                        temporary.write_text(json.dumps(info),encoding='utf8')
                        temporary.replace(status)
                    except OSError:
                        pass # Windows reader can briefly hold a telemetry file; retry next update.

            def emit(left,right):
                nonlocal published
                t = time.perf_counter()
                if args.eye_swap:
                    left,right = right,left
                eyes = torch.stack((left,right)).to(device).float()
                if args.layout == 'half-sbs':
                    eyes = F.interpolate(eyes,size=(h,w//2),mode='bicubic',align_corners=False,antialias=True)
                elif args.layout == 'half-ou':
                    eyes = F.interpolate(eyes,size=(h//2,w),mode='bicubic',align_corners=False,antialias=True)
                stereo = torch.cat(tuple(eyes),dim=2 if 'sbs' in args.layout else 1)
                out_staging.copy_(stereo.permute(1,2,0).round().clamp(0,255).byte(),non_blocking=True)
                torch.cuda.current_stream().synchronize()
                encoder.stdin.write(memoryview(out_staging.numpy()).cast('B'))
                published += 1
                totals['encode_submit_s'] += time.perf_counter()-t
                if published%6==0 or published==args.frames:
                    progress()

            temporal = TemporalReconstructor(emit,inpaint,atlas=args.native_fill!='off',
                cache_mb=args.native_cache_mb,halo=args.native_halo,strength=args.native_strength,
                atlas_executor=args.native_atlas_executor)
            with torch.inference_mode():
                for index,raw,cut,mode,motion in samples:
                    if index >= args.frames:
                        raise ValueError('VR raw depth has more frames than the source timeline')
                    t = time.perf_counter()
                    if legacy.read_exact_into(rgb_input,memoryview(staging.numpy())) != h*w*3:
                        raise RuntimeError(f'VR decoder ended before frame {index}')
                    source_cpu = staging.permute(2,0,1).clone()
                    source = staging.to(device,non_blocking=True).permute(2,0,1)[None]
                    rgb = source.float()/255
                    totals['decode_s'] += time.perf_counter()-t
                    t = time.perf_counter()
                    raw_t = torch.from_numpy(raw).to(device)[None,None]
                    if cut:
                        old_range=old_depth=convergence=None
                    low = raw_t.amin() if mode=='minmax' else torch.zeros((),device=device)
                    high = raw_t.amax()
                    if old_range is not None:
                        decay = args.depth_range_smoothing
                        low = old_range[0]*decay+low*(1-decay)
                        high = old_range[1]*decay+high*(1-decay)
                    old_range=(low,high)
                    depth = ((raw_t-low)/(high-low).clamp_min(1e-8)).clamp(0,1)
                    if args.native_geometry == 'studio':
                        depth=native_temporal_depth(depth,old_depth,
                            motion if args.temporal_mode=='motion' else None,
                            0 if args.temporal_mode=='off' else args.temporal_smoothing,grid_cache)
                        old_depth=depth.clone()
                        depth=legacy.edge_aware_feather(depth.pow(args.depth_gamma),args.edge_feather)
                        depth=legacy.gradient_aware_depth(depth,args.edge_protection)
                    convergence=legacy.resolve_convergence(depth,args.convergence,args.convergence_mode,
                                                          convergence,args.convergence_smoothing)
                    # Correct DA2/DA3 high=near polarity, once at canonical model scale.
                    if args.rowflow_edge_x or args.rowflow_edge_y:
                        depth=dilate(depth.float(),(args.rowflow_edge_x,args.rowflow_edge_y)).clamp(0,1)
                    delta=depth-convergence
                    if args.native_geometry == 'studio':
                        delta=legacy.shape_disparity_delta(delta,args.disparity_curve,args.comfort_strength)
                        delta=torch.where(delta>=0,delta*args.foreground_strength,delta*args.background_strength)
                        depth=(delta+convergence).clamp(0,1)
                    guide_depth = depth
                    model_w = min(w,args.rowflow_width or w)
                    model_h = max(2,round(h*model_w/w))
                    depth=F.interpolate(depth,size=(model_h,model_w),mode='bilinear',align_corners=True,antialias=True)
                    divergence=args.max_disparity_percent*args.eye_separation
                    steps=args.rowflow_steps or legacy.rowflow_auto_steps(divergence,args.eye_anchor)
                    views=renderer(rgb,depth,divergence,convergence,steps,args.eye_anchor,args.rowflow_preserve_border)
                    eyes=[v[0][0].mul(255).round().clamp(0,255).byte().cpu() for v in views]
                    masks=[]; backgrounds=[]
                    if args.native_fill!='off':
                        disparity=F.interpolate(depth-convergence,size=(h,w),mode='bilinear',align_corners=True)[0,0]
                        disparity=disparity*(max(w,h)*divergence/100)
                        for eye,shift in enumerate(legacy.eye_shift_factors(args.eye_anchor)):
                            holes,coords,far,anchor=geometry_mask(depth,disparity,views[eye][1],shift,args.z_buffer_strength,args.ldi_layers,convergence,divergence)
                            if shift == 0:
                                holes.zero_()
                            masks.append(holes[0].cpu())
                            small=guide_depth.shape[-2:]
                            backgrounds.append((F.interpolate(coords,size=small,mode='bilinear',align_corners=True)[0].cpu(),
                                F.interpolate(far,size=small,mode='bilinear',align_corners=True)[0].cpu(),
                                F.interpolate(anchor,size=small,mode='bilinear',align_corners=True)[0].cpu()))
                    if eye_writers:
                        for eye,(_,coords) in enumerate(views):
                            coords_small=F.interpolate(coords,size=guide_depth.shape[-2:],mode='bilinear',align_corners=True)
                            projected=sample(guide_depth,coords_small)
                            if masks:
                                repair=F.interpolate(masks[eye][None].to(device).float(),size=guide_depth.shape[-2:],mode='area')>.25
                                far_small=backgrounds[eye][1][None].to(device)
                                projected=torch.where(repair,far_small,projected)
                            # Eye-swap changes packing order, not source geometry.
                            writer=eye_writers[1-eye if args.eye_swap else eye]
                            writer.write(DepthSample(None,projected[0,0].cpu().numpy(),'max'),cut)
                    # Free native float32 views before temporal crops allocate activations.
                    del views,source,rgb,depth
                    torch.cuda.current_stream().synchronize()
                    totals['geometry_s'] += time.perf_counter()-t
                    t = time.perf_counter()
                    if args.native_fill=='off':
                        emit(*eyes)
                    else:
                        scale=min(1.,640/max(w,h))
                        guide_size=(max(2,round(w*scale)),max(2,round(h*scale)))
                        guide=cv2.resize(source_cpu.permute(1,2,0).numpy(),guide_size,interpolation=cv2.INTER_AREA)
                        packet=Packet(index,source_cpu,guide_depth[0,0].cpu(),eyes,masks,backgrounds,guides=guide)
                        temporal.append(packet,cut)
                    totals['reconstruct_s'] += time.perf_counter()-t
                    processed += 1
                    if processed==1 or processed%6==0 or processed==args.frames:
                        progress()
                t=time.perf_counter()
                temporal.flush()
                totals['reconstruct_s'] += time.perf_counter()-t
            encoder.stdin.close(); rgb_input.close()
            if (decoder is not None and decoder.wait(timeout=30)) or encoder.wait(timeout=120):
                raise RuntimeError('VR FFmpeg process failed')
            if processed!=args.frames or published!=args.frames:
                raise ValueError(f'VR timeline mismatch: input={processed}, output={published}, expected={args.frames}')
            partial.replace(args.output_video)
            for writer in eye_writers:
                writer.close(True)
            success=True
        except Exception as error:
            for stream in (de,ee):
                stream.seek(0)
                detail=stream.read().decode('utf-8',errors='replace')[-4000:]
                if detail:
                    print('VR_FFMPEG_ERROR '+detail,flush=True)
            raise
        finally:
            if rgb_pipe: rgb_pipe.close()
            if guard: guard.close()
            if 'temporal' in locals() and temporal.gpu_atlas:
                temporal.gpu_atlas.close()
            for process in (decoder,encoder):
                if process is not None:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=10)
                    for stream in (process.stdin,process.stdout):
                        if stream and not stream.closed:
                            stream.close()
            if not success:
                for writer in eye_writers:
                    writer.close(False)
                partial.unlink(missing_ok=True)
    elapsed=time.perf_counter()-started
    # Reconstruction includes encode callbacks; report exclusive phase durations.
    totals['reconstruct_s']=max(0,totals['reconstruct_s']-totals['encode_submit_s'])
    report={'frames':published,'elapsed_s':elapsed,'fps':published/elapsed,'stages':totals,
        'depth_source':'shared-raw-float32','depth_model_reinvocations':0,
        'input_transport':'lossless-rgb-pipe' if args.native_rgb_pipe else 'video-file',
        'elapsed_includes_producer_wait':bool(args.native_rgb_pipe),
        'native_eye_geometry':[w,h],'output_geometry':[ow,oh],
        'geometry':args.native_geometry,'fill':args.native_fill,'temporal':temporal.stats,
        'inpaint':temporal.net.stats if temporal.net else None,
        'peak_cuda_allocated_mb':torch.cuda.max_memory_allocated()/1024**2,
        'output':str(args.output_video)}
    args.output_video.with_suffix('.vr.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('VR_DEPTH_DONE '+json.dumps(report),flush=True)
    return 0
