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


if __name__ == "__main__":
    unittest.main()
