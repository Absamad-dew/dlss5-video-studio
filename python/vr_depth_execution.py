"""Studio-only exact DA3 execution pruning; installed IW3 sources stay untouched.

Main-head execution follows ByteDance Depth Anything 3 DualDPT (Apache-2.0,
Copyright 2025 ByteDance Ltd. and/or its affiliates). Original weights and
operators are reused. The independent ray head is not a consumer of depth.
"""
import torch
from torch import nn


class DepthOnlyHead(nn.Module):
    def __init__(self, original):
        super().__init__()
        self.original = original
        self.checked = False
        self.enabled = True

    def forward(self, feats, H, W, patch_start_idx, chunk_size=8):
        if not self.enabled:
            return self.original(feats,H,W,patch_start_idx,chunk_size)
        result = self._depth(feats,H,W,patch_start_idx,chunk_size)
        if not self.checked:
            reference = self.original(feats,H,W,patch_start_idx,chunk_size)
            self.enabled = all(key in reference and torch.equal(value,reference[key])
                               for key,value in result.items())
            self.checked = True
            print('VR_DEPTH_HEAD_VALIDATED exact='+str(self.enabled).lower(),flush=True)
            if not self.enabled: return reference
        return result

    def _depth(self, feats, H, W, patch_start_idx, chunk_size=8):
        from addict import Dict
        b, s, n, c = feats[0][0].shape
        flat = [feature[0].reshape(b*s, n, c) for feature in feats]
        if chunk_size is None or chunk_size >= s:
            result = self._forward_impl(flat, H, W, patch_start_idx)
        else:
            chunks = [self._forward_impl([feature[i:i+chunk_size] for feature in flat], H, W,
                                        patch_start_idx) for i in range(0, b*s, chunk_size)]
            result = {key: torch.cat([chunk[key] for chunk in chunks]) for key in chunks[0]}
        return Dict({key: value.reshape(b, s, *value.shape[1:]) for key, value in result.items()})

    def _forward_impl(self, feats, H, W, patch_start_idx):
        from depth_anything_3.model.utils.head_utils import custom_interpolate
        head = self.original
        batch, _, channels = feats[0].shape
        ph, pw = H//head.patch_size, W//head.patch_size
        resized = []
        for stage, take in enumerate(head.intermediate_layer_idx):
            x = head.norm(feats[take][:, patch_start_idx:])
            x = x.permute(0, 2, 1).reshape(batch, channels, ph, pw)
            x = head.projects[stage](x)
            if head.pos_embed: x = head._add_pos_embed(x, W, H)
            resized.append(head.resize_layers[stage](x))
        scratch = head.scratch
        l1, l2, l3, l4 = [getattr(scratch, f'layer{i+1}_rn')(x) for i, x in enumerate(resized)]
        out = scratch.refinenet4(l4, size=l3.shape[2:])
        out = scratch.refinenet3(out, l3, size=l2.shape[2:])
        out = scratch.refinenet2(out, l2, size=l1.shape[2:])
        out = scratch.refinenet1(out, l1)
        out = scratch.output_conv1(out)
        out = custom_interpolate(out, (int(ph*head.patch_size/head.down_ratio),
                                       int(pw*head.patch_size/head.down_ratio)),
                                 mode='bilinear', align_corners=True)
        if head.pos_embed: out = head._add_pos_embed(out, W, H)
        logits = scratch.output_conv2(out).permute(0, 2, 3, 1)
        return {head.head_main: head._apply_activation_single(logits[..., :-1], head.activation).squeeze(-1),
                f'{head.head_main}_conf': head._apply_activation_single(logits[..., -1], head.conf_activation)}


def install_depth_only_head(model):
    """Prune only a known independent ray head, never depth or sky branches."""
    head = getattr(model, 'head', None)
    if isinstance(head, DepthOnlyHead): return True
    if (head is None or type(head).__name__ != 'DualDPT' or
            getattr(head, 'head_main', None) != 'depth' or getattr(head, 'head_aux', None) != 'ray' or
            any(getattr(model, name, None) is not None for name in ('cam_enc','cam_dec','gs_head','gs_adapter'))):
        return False
    model.head = DepthOnlyHead(head)
    return True
