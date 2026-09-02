"""Focused regression tests for the CUDA VR synthesis worker."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np
import torch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import vr_depth_worker as vr  # noqa: E402


class VrDepthWorkerTests(unittest.TestCase):
    def test_hevc_profiles_are_headset_compatible(self) -> None:
        main = vr.encode_options("h265", "yuv420p", 18)
        main10 = vr.encode_options("h265", "p010le", 18)
        self.assertIn("main", main)
        self.assertIn("yuv420p", main)
        self.assertIn("main10", main10)
        self.assertIn("p010le", main10)
        self.assertNotIn("Rext", main + main10)

    def test_disparity_curves_and_comfort_limit_are_finite(self) -> None:
        delta = torch.linspace(-1.0, 1.0, 65)[None, None]
        cinematic = vr.shape_disparity_delta(delta, "cinematic", 0.0)
        comfortable = vr.shape_disparity_delta(delta, "linear", 1.0)
        self.assertTrue(torch.isfinite(cinematic).all())
        self.assertTrue(torch.isfinite(comfortable).all())
        self.assertLess(float(comfortable.abs().max()), float(delta.abs().max()))

    def test_eye_anchor_uses_one_baseline_not_double_parallax(self) -> None:
        for anchor in ("left", "right", "symmetric"):
            left, right = vr.eye_shift_factors(anchor)
            self.assertAlmostEqual(abs(left - right), 1.0)
        self.assertEqual(vr.eye_shift_factors("left"), (0.0, -1.0))

    def test_robust_depth_range_rejects_outliers(self) -> None:
        depth = torch.linspace(0.2, 0.8, 400).reshape(1, 1, 20, 20)
        depth[..., 0, 0] = -10.0
        depth[..., -1, -1] = 10.0
        normalized, bounds = vr.robust_depth_range(depth, 1.0, None, 0.9)
        self.assertGreater(bounds[0], -1.0)
        self.assertLess(bounds[1], 1.0)
        self.assertGreaterEqual(float(normalized.min()), 0.0)
        self.assertLessEqual(float(normalized.max()), 1.0)

    def test_motion_quality_recovers_premultiplied_vectors(self) -> None:
        motion = np.zeros((8, 10), dtype=vr.MOTION_DTYPE)
        motion["valid"] = 1
        motion["confidence"] = 128
        confidence = 128.0 / 255.0
        motion["dx"] = np.float16(12.0 * confidence)
        motion["dy"] = np.float16(5.0 * confidence)
        mean_confidence, pixels = vr.motion_quality(motion)
        self.assertAlmostEqual(mean_confidence, confidence, places=3)
        self.assertAlmostEqual(pixels, 13.0, places=1)

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA is required")
    def test_layered_splat_fills_disocclusions(self) -> None:
        device = torch.device("cuda")
        height, width = 24, 32
        frame = torch.ones((1, 3, height, width), device=device, dtype=torch.float16)
        depth = torch.linspace(0.1, 0.9, width, device=device)[None, None, None].expand(
            1, 1, height, width
        )
        disparity = torch.full((height, width), 3.5, device=device)
        x = torch.arange(width, device=device, dtype=torch.float32)[None].expand(height, -1)
        rows = (
            torch.arange(height, device=device, dtype=torch.int64)[:, None] * width
        ).expand(-1, width)
        output, holes = vr.layered_splat(frame, depth, disparity, x, rows, 1.0, 5.0, 0.8, 8)
        self.assertEqual(tuple(output.shape), tuple(frame.shape))
        self.assertGreater(holes, 0.0)
        self.assertGreater(float(output.mean().item()), 0.95)

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA is required")
    def test_forward_splat_does_not_mix_foreground_with_background(self) -> None:
        device = torch.device("cuda")
        frame = torch.zeros((1, 3, 1, 4), device=device, dtype=torch.float16)
        frame[0, 0, 0, 0] = 1.0  # near red pixel
        frame[0, 2, 0, 1] = 1.0  # far blue pixel
        depth = torch.tensor([[[[0.95, 0.05, 0.05, 0.05]]]], device=device)
        disparity = torch.tensor([[1.0, 0.0, 0.0, 0.0]], device=device)
        x = torch.arange(4, device=device, dtype=torch.float32)[None]
        rows = torch.zeros((1, 4), device=device, dtype=torch.int64)
        output, valid, collisions = vr.forward_splat(
            frame, depth, disparity, x, rows, 1.0, 6.0, 8, return_uncertain=True
        )
        self.assertTrue(bool(valid[0, 0, 0, 1]))
        self.assertTrue(bool(collisions[0, 0, 0, 1]))
        self.assertGreater(float(output[0, 0, 0, 1]), 0.95)
        self.assertLess(float(output[0, 2, 0, 1]), 0.05)

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA is required")
    def test_forward_splat_antialiases_fractional_silhouette_coverage(self) -> None:
        device = torch.device("cuda")
        frame = torch.zeros((1, 3, 1, 3), device=device, dtype=torch.float16)
        frame[0, 0, 0, 0] = 1.0
        frame[0, 2, 0, 1] = 1.0
        depth = torch.tensor([[[[0.95, 0.05, 0.05]]]], device=device)
        disparity = torch.tensor([[0.5, 0.0, 0.0]], device=device)
        x = torch.arange(3, device=device, dtype=torch.float32)[None]
        rows = torch.zeros((1, 3), device=device, dtype=torch.int64)
        output, _, collisions = vr.forward_splat(
            frame, depth, disparity, x, rows, 1.0, 6.0, 8, return_uncertain=True
        )
        self.assertTrue(bool(collisions[0, 0, 0, 1]))
        self.assertGreater(float(output[0, 0, 0, 1]), 0.35)
        self.assertGreater(float(output[0, 2, 0, 1]), 0.35)

    def test_context_mask_expands_but_compose_mask_never_repaints_foreground(self) -> None:
        holes = torch.zeros((1, 1, 9, 31), dtype=torch.bool)
        collisions = torch.zeros_like(holes)
        holes[0, 0, 3:6, 14:17] = True
        collisions[0, 0, 4, 11] = True
        collisions[0, 0, 0, 30] = True
        disparity = torch.full((9, 31), 24.0)
        guard = vr.reprojection_guard_mask(holes, collisions, disparity)
        self.assertTrue(bool(guard[0, 0, 4, 11]))
        self.assertTrue(bool(guard[0, 0, 2, 15]))
        self.assertFalse(bool(guard[0, 0, 0, 30]))
        compose = vr.directional_compose_mask(holes, guard, -disparity)
        self.assertTrue(bool(compose[0, 0, 4, 15]))
        self.assertTrue(bool(compose[0, 0, 4, 18]))
        self.assertFalse(bool(compose[0, 0, 4, 11]))
        self.assertTrue(bool(torch.all(~compose | guard)))

    def test_directional_indices_prefer_background_side(self) -> None:
        valid = torch.tensor([[[[True, False, False, True, False]]]])
        from_right = vr.directional_nearest_indices(valid, True)
        from_left = vr.directional_nearest_indices(valid, False)
        self.assertEqual(from_right.flatten().tolist(), [0, 3, 3, 3, 3])
        self.assertEqual(from_left.flatten().tolist(), [0, 0, 0, 3, 3])

    def test_directional_background_fill_mirrors_real_pixels(self) -> None:
        image = torch.arange(7, dtype=torch.float32)[None, None, None]
        valid = torch.tensor([[[[True, False, False, True, True, True, True]]]])
        filled = vr.directional_background_fill(image, valid, True, safety_margin=0)
        self.assertEqual(filled.flatten().tolist(), [0.0, 4.0, 3.0, 3.0, 4.0, 5.0, 6.0])

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA is required")
    def test_gapw_returns_clean_dense_view_and_sparse_masks(self) -> None:
        device = torch.device("cuda")
        height, width = 24, 48
        frame = torch.linspace(0.0, 1.0, width, device=device)[None, None, None]
        frame = frame.expand(1, 3, height, width).half()
        depth = torch.full((1, 1, height, width), 0.1, device=device)
        depth[..., 12:28] = 0.9
        disparity = torch.zeros((height, width), device=device)
        disparity[:, 12:28] = 7.0
        gy, gx = torch.meshgrid(
            torch.linspace(-1.0, 1.0, height, device=device),
            torch.linspace(-1.0, 1.0, width, device=device),
            indexing="ij",
        )
        sx = torch.arange(width, device=device, dtype=torch.float32)[None].expand(height, -1)
        rows = (torch.arange(height, device=device)[:, None] * width).expand(-1, width)
        output, holes, context, compose, valid = vr.gradient_aware_parallax_warp(
            frame, depth, disparity, gx, gy, sx, rows, -1.0, 5.0, 8, 12, 0.2
        )
        self.assertTrue(torch.isfinite(output).all())
        self.assertGreater(holes, 0.0)
        self.assertTrue(bool(compose.any()))
        self.assertTrue(bool(torch.all(compose <= context)))
        self.assertTrue(bool(torch.all(valid == ~compose)))

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA is required")
    def test_motion_temporal_uses_confident_history(self) -> None:
        device = torch.device("cuda")
        previous = torch.ones((1, 1, 8, 10), device=device)
        current = torch.zeros_like(previous)
        motion = np.zeros((8, 10), dtype=vr.MOTION_DTYPE)
        motion["valid"] = 1
        motion["confidence"] = 255
        output = vr.motion_compensated_depth(
            current, previous, motion, 10, 8, 0.75, {}
        )
        self.assertAlmostEqual(float(output.mean().item()), 0.75, places=4)

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA is required")
    def test_temporal_ldi_reprojection_repairs_constant_frame(self) -> None:
        device = torch.device("cuda")
        height, width = 24, 36
        frame = torch.full((1, 3, height, width), 0.75, device=device, dtype=torch.float16)
        depth = torch.linspace(0.05, 0.95, width, device=device)[None, None, None].expand(
            1, 1, height, width
        )
        disparity = torch.full((height, width), 5.0, device=device)
        x = torch.arange(width, device=device, dtype=torch.float32)[None].expand(height, -1)
        rows = (
            torch.arange(height, device=device, dtype=torch.int64)[:, None] * width
        ).expand(-1, width)
        output, holes, hole_mask, compose_mask, valid = vr.temporal_ldi_splat(
            frame, depth, disparity, x, rows, 1.0, 6.0, 0.85, 12, 8, 12, 0.4
        )
        self.assertEqual(tuple(output.shape), tuple(frame.shape))
        self.assertEqual(tuple(hole_mask.shape), (1, 1, height, width))
        self.assertEqual(tuple(compose_mask.shape), (1, 1, height, width))
        self.assertEqual(tuple(valid.shape), (1, 1, height, width))
        self.assertGreater(holes, 0.0)
        self.assertGreater(float(output.mean()), 0.70)
        self.assertTrue(torch.isfinite(output).all())


if __name__ == "__main__":
    unittest.main()
