"""Bounded GPU atlas executor. Same donors, geometry and acceptance thresholds.

Only original unknown pixels are evaluated at native resolution. Photometric
validation stays at the original guide resolution and is shared between eyes.
No frame dropping, reduced depth resolution, relaxed masks, or neural changes.
"""
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import time

import cv2
import numpy as np
import torch
import torch.nn.functional as F

from vr_reconstruction import BackgroundLink, grid01, sample, sample_u8, map_homography


@dataclass
class Features:
    rgb: np.ndarray
    gray: np.ndarray
    depth: np.ndarray
    points: object
    descriptors: object


def prepare_features(rgb, depth):
    h, w = rgb.shape[:2]
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    depth = cv2.resize(depth.astype(np.float32), (w, h), interpolation=cv2.INTER_LINEAR)
    non_sky = depth[depth > .015]
    cutoff = np.quantile(non_sky, .80) if non_sky.size else 1.
    mask = ((depth > .015) & (depth <= cutoff)).astype(np.uint8) * 255
    points, descriptors = cv2.ORB_create(nfeatures=1400, fastThreshold=12).detectAndCompute(gray, mask)
    return Features(rgb, gray, depth, points, descriptors)


def feature_link(previous, current):
    h, w = current.gray.shape
    if previous.descriptors is None or current.descriptors is None:
        return BackgroundLink(None, 0, 'no-features')
    matches = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(current.descriptors, previous.descriptors, k=2)
    good = [m[0] for m in matches if len(m) == 2 and m[0].distance < .72*m[1].distance]
    if len(good) < 18:
        return BackgroundLink(None, 0, 'few-matches')
    src = np.float32([current.points[m.queryIdx].pt for m in good])
    dst = np.float32([previous.points[m.trainIdx].pt for m in good])
    matrix, inliers = cv2.findHomography(src, dst, cv2.RANSAC, 1.0)
    if matrix is None or inliers is None or inliers.sum() < 16:
        return BackgroundLink(None, 0, 'few-inliers')
    pts = src[inliers[:, 0] > 0]
    if np.ptp(pts[:, 0]) < w*.35 or np.ptp(pts[:, 1]) < h*.20:
        return BackgroundLink(None, 0, 'narrow-coverage')
    confidence = float(inliers.mean())
    scale = np.diag([w-1, h-1, 1.0])
    matrix = np.linalg.inv(scale) @ matrix @ scale
    if confidence < .70 or not np.isfinite(matrix).all() or abs(np.linalg.det(matrix)) < .1:
        return BackgroundLink(None, 0, 'low-confidence')
    return BackgroundLink(matrix, confidence)


def validate_flow(previous, current, flow, reverse):
    h, w = current.gray.shape
    y, x = np.mgrid[:h, :w].astype(np.float32)
    mx, my = x+flow[..., 0], y+flow[..., 1]
    backwards = cv2.remap(reverse, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    roundtrip = np.linalg.norm(flow+backwards, axis=2) < .75
    other = cv2.remap(previous.rgb, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    photo = np.abs(current.rgb.astype(np.float32)-other.astype(np.float32)).mean(2) < 12
    prior = cv2.remap(previous.depth, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    valid = roundtrip & photo & (np.abs(current.depth-prior) < .06)
    valid &= (mx >= 0) & (mx < w-1) & (my >= 0) & (my < h-1)
    normalized = flow / np.array([w-1, h-1], np.float32)
    return BackgroundLink(None, 1., 'source-flow', normalized, valid.astype(np.float32))


class RegistrationCache:
    def __init__(self, stats):
        self.features, self.links, self.flows = {}, {}, {}
        self.stats = stats
        stats.update(orb_frames=0, dis_fields=0, reverse_flow_hits=0)

    def get(self, target, donor):
        key = target.index, donor.index
        if key in self.links:
            return self.links[key]
        for packet in (donor, target):
            if packet.index not in self.features:
                self.features[packet.index] = prepare_features(packet.guides, packet.depth.numpy())
                self.stats['orb_frames'] += 1
        previous, current = self.features[donor.index], self.features[target.index]
        link = feature_link(previous, current)
        self.stats['registered_pairs' if link.matrix is not None else 'rejected_pairs'] += 1
        if link.matrix is None:
            reasons = self.stats['registration_rejections']
            reasons[link.reason] = reasons.get(link.reason, 0)+1
            if key not in self.flows:
                dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_FAST)
                dis.setVariationalRefinementIterations(2)
                flow = dis.calc(current.gray, previous.gray, None)
                reverse = dis.calc(previous.gray, current.gray, None)
                self.flows[key] = validate_flow(previous, current, flow, reverse)
                self.flows[key[::-1]] = validate_flow(current, previous, reverse, flow)
                self.stats['dis_fields'] += 2
            else:
                self.stats['reverse_flow_hits'] += 1
            link = self.flows[key]
            self.stats['source_flow_pairs'] += 1
        self.links[key] = link
        return link

    def prune(self, first):
        self.features = {k: v for k, v in self.features.items() if k >= first}
        self.links = {k: v for k, v in self.links.items() if min(k) >= first}
        self.flows = {k: v for k, v in self.flows.items() if min(k) >= first}

    def clear(self):
        self.features.clear(); self.links.clear(); self.flows.clear()


class SourceCache:
    """Original uint8 source frames only, never generated/repaired pixels."""
    def __init__(self, limit_mb=384, device='cuda'):
        self.limit = int(limit_mb*1024**2)
        self.device = torch.device(device)
        self.values = OrderedDict()
        self.bytes = self.peak = self.uploads = 0

    def get(self, packet):
        if packet.index in self.values:
            value = self.values.pop(packet.index)
            self.values[packet.index] = value
            return value
        value = packet.source[None].to(self.device)
        self.uploads += 1
        size = value.numel()*value.element_size()
        if size <= self.limit:
            while self.values and self.bytes+size > self.limit:
                _, old = self.values.popitem(last=False)
                self.bytes -= old.numel()*old.element_size()
            self.values[packet.index] = value
            self.bytes += size
            self.peak = max(self.peak, self.bytes)
        return value

    def prune(self, first):
        for key in list(self.values):
            if key < first:
                value = self.values.pop(key)
                self.bytes -= value.numel()*value.element_size()

    def clear(self):
        self.values.clear(); self.bytes = 0


class PhotoContext:
    def __init__(self, target_source, target_depth):
        self.identity = grid01(*target_depth.shape[-2:], target_depth.device)
        self.target_small = sample_u8(target_source, self.identity)/255
        self.far = target_depth <= torch.quantile(target_depth, .60)+.01
        self.weight = F.avg_pool2d(self.far.float(), 15, 1, 7)

    def validate(self, donor_source, matrix, flow):
        observed = (self.identity+sample(flow, self.identity) if flow is not None
                    else map_homography(self.identity, matrix))
        donor_small = sample_u8(donor_source, observed)/255
        error = (self.target_small-donor_small).abs().mean(1, keepdim=True)
        error = F.avg_pool2d(error*self.far, 15, 1, 7)/self.weight.clamp_min(.01)
        return ((error < .055) & (self.weight > .35)).float()


class SparseEye:
    def __init__(self, image, mask, background, device):
        self.image = image[None].to(device)
        self.mask = mask[None].to(device)
        self.rows, self.cols = self.mask[0, 0].nonzero(as_tuple=True)
        self.remaining = torch.ones_like(self.rows, dtype=torch.bool)
        self.points = []
        # Keep exactly the old interpolation arithmetic. Expand only once per
        # eye, gather its unknown locations, then release full-resolution maps.
        for field in background:
            full = F.interpolate(field[None].to(device), size=image.shape[-2:],
                                 mode='bilinear', align_corners=True)
            self.points.append(full[:, :, self.rows, self.cols].unsqueeze(2))

    def repair(self, donor, donor_depth, target_depth, link, flow, flow_valid, photo, tolerance=.08):
        background, far, anchor = self.points
        if not self.rows.numel():
            return torch.zeros((), device=donor.device, dtype=torch.long)
        if flow is not None:
            coords = background+sample(flow, anchor)
            anchor_ok = sample(flow_valid, anchor) > .999
            anchor_ok &= (sample(target_depth, anchor)-far).abs() < tolerance
        else:
            coords = map_homography(background, link.matrix)
            anchor_ok = True
        valid = ((coords >= 0) & (coords <= 1)).all(1, keepdim=True)
        depth_ok = (sample(donor_depth, coords)-far).abs() <= tolerance
        local_ok = sample(photo, background) > .995
        accepted = (valid & depth_ok & local_ok & anchor_ok & (link.confidence >= .70)).flatten()
        accepted &= self.remaining
        indices = accepted.nonzero(as_tuple=True)[0]
        # Empty gather/scatter is valid; no per-eye .item() synchronization.
        points = coords[:, :, :, indices]
        colour = sample_u8(donor, points)[0, :, 0]
        self.image[0, :, self.rows[indices], self.cols[indices]] = colour.round().clamp(0, 255).byte()
        self.mask[0, 0, self.rows[indices], self.cols[indices]] = False
        self.remaining &= ~accepted
        return accepted.sum()


class GpuAtlas:
    def __init__(self, stats, cache_mb=384, device='cuda'):
        self.device = torch.device(device)
        self.registration = RegistrationCache(stats)
        # A single ordered CPU producer avoids cache races and oversubscription;
        # OpenCV kernels release the GIL while the main thread renders on CUDA.
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='vr-atlas-registration')
        self.requests, self.needs = {}, {}
        self.sources = SourceCache(cache_mb, device)
        self.stats = stats
        stats.update(atlas_executor='gpu-sparse-v2', atlas_registration_s=0., atlas_repair_s=0.,
                     atlas_native_query_pixels=0, atlas_source_uploads=0, atlas_source_cache_peak_mb=0.,
                     atlas_registration_compute_s=0., atlas_prefetched_pairs=0)

    def _register(self, target, donor):
        t = time.perf_counter()
        result = self.registration.get(target, donor)
        self.stats['atlas_registration_compute_s'] += time.perf_counter()-t
        return result

    def _request(self, target, donor):
        key = target.index, donor.index
        if key not in self.requests:
            self.requests[key] = self.executor.submit(self._register, target, donor)
            self.stats['atlas_prefetched_pairs'] += 1
        return self.requests[key]

    def prefetch(self, packet, packets):
        self.needs[packet.index] = any(bool(mask.any()) for mask in packet.masks)
        for offset in (-1, -2, -3):
            other = packets.get(packet.index+offset)
            if other is not None:
                if self.needs[packet.index]: self._request(packet, other)
                if self.needs.get(other.index): self._request(other, packet)

    @torch.inference_mode()
    def repair(self, packet, packets):
        t = time.perf_counter()
        donors = []
        for offset in (-1, 1, -2, 2, -3, 3):
            donor = packets.get(packet.index+offset)
            if donor is not None:
                donors.append((donor, self._request(packet, donor).result()))
        self.stats['atlas_registration_s'] += time.perf_counter()-t
        t = time.perf_counter()
        target = self.sources.get(packet)
        target_depth = packet.depth[None, None].to(self.device)
        photo_context = PhotoContext(target, target_depth)
        eyes = [SparseEye(packet.eyes[i], packet.masks[i], packet.background[i], self.device) for i in range(2)]
        accepted = torch.zeros((), device=self.device, dtype=torch.long)
        for donor, link in donors:
            if link.matrix is None and link.flow is None:
                continue
            source = self.sources.get(donor)
            depth = donor.depth[None, None].to(self.device)
            flow = None if link.flow is None else torch.from_numpy(link.flow).permute(2, 0, 1)[None].to(self.device)
            flow_valid = None if link.valid is None else torch.from_numpy(link.valid)[None, None].to(self.device)
            photo = photo_context.validate(source, link.matrix, flow)
            for eye in eyes:
                accepted += eye.repair(source, depth, target_depth, link, flow, flow_valid, photo)
                self.stats['atlas_native_query_pixels'] += eye.rows.numel()
        packet.eyes = [eye.image[0].cpu() for eye in eyes]
        packet.masks = [eye.mask[0].cpu() for eye in eyes]
        self.stats['source_repaired_pixels'] += int(accepted.item())
        self.stats['atlas_repair_s'] += time.perf_counter()-t
        self.stats['atlas_source_uploads'] = self.sources.uploads
        self.stats['atlas_source_cache_peak_mb'] = self.sources.peak/1024**2

    def prune(self, first):
        self.executor.submit(self.registration.prune, first)
        self.requests = {k: v for k, v in self.requests.items() if min(k) >= first}
        self.needs = {k: v for k, v in self.needs.items() if k >= first}
        self.sources.prune(first)

    def clear(self):
        self.executor.submit(self.registration.clear).result()
        self.requests.clear(); self.needs.clear(); self.sources.clear()

    def close(self):
        self.executor.shutdown(wait=True, cancel_futures=True)
