"""Regression tests for sparse native-resolution Moebius planning."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import moebius_worker as sparse  # noqa: E402


class MoebiusWorkerTests(unittest.TestCase):
    def test_auto_limits_do_not_scale_complete_4k_frame(self) -> None:
        roi, steps, batch, patches = sparse.auto_limits(8187, 3840, 2160, 0, 0, 0, 0)
        self.assertEqual(roi, 768)
        self.assertEqual(steps, 16)
        self.assertEqual(batch, 1)
        self.assertEqual(patches, 20)

    def test_quality_floor_rejects_broken_two_step_draft(self) -> None:
        _, steps, _, _ = sparse.auto_limits(8187, 1280, 720, 512, 2, 1, 20)
        self.assertEqual(steps, 8)

    def test_peripheral_slivers_do_not_consume_full_model_tiles(self) -> None:
        mask = np.zeros((720, 1280), np.uint8)
        mask[:, :12] = 255
        mask[:, -18:] = 255
        mask[180:520, 600:650] = 255
        cleaned = sparse.suppress_peripheral_slivers(mask)
        self.assertEqual(int(cleaned[:, :20].sum()), 0)
        self.assertEqual(int(cleaned[:, -20:].sum()), 0)
        self.assertGreater(int(cleaned[180:520, 600:650].sum()), 0)

    def test_model_mask_expands_only_toward_foreground(self) -> None:
        mask = np.zeros((9, 24), np.uint8)
        mask[4, 12:14] = 255
        expanded = sparse.expand_model_conditioning_mask(
            mask, mask, "right", foreground_span=5, vertical_span=0
        )
        self.assertTrue(np.all(expanded[4, 7:14] == 255))
        self.assertEqual(int(expanded[4, 14:].sum()), 0)

        inverse = sparse.expand_model_conditioning_mask(
            mask, mask, "left", foreground_span=5, vertical_span=0
        )
        self.assertTrue(np.all(inverse[4, 12:19] == 255))
        self.assertEqual(int(inverse[4, :12].sum()), 0)

    def test_small_hole_produces_local_roi(self) -> None:
        mask = np.zeros((1080, 1920), np.uint8)
        mask[420:500, 880:930] = 255
        rois = sparse.plan_rois(mask, 768, 128, 1.65, 20, 20)
        self.assertEqual(len(rois), 1)
        self.assertLess(rois[0].size, 768)
        self.assertLess(rois[0].size * rois[0].size, mask.size // 20)
        self.assertLessEqual(rois[0].x, 880)
        self.assertGreaterEqual(rois[0].x2, 930)

    def test_large_hole_is_tiled_without_full_frame_roi(self) -> None:
        mask = np.zeros((2160, 3840), np.uint8)
        mask[400:1800, 1500:2300] = 255
        rois = sparse.plan_rois(mask, 640, 96, 1.4, 20, 24)
        self.assertGreater(len(rois), 1)
        self.assertTrue(all(roi.size == 640 for roi in rois))
        self.assertTrue(all(roi.size < min(mask.shape) for roi in rois))

    def test_confident_motion_reuses_previous_generated_hole(self) -> None:
        height = width = 64
        previous = np.full((height, width, 3), 180, np.uint8)
        seed = previous.copy()
        seed[20:44, 22:42] = 0
        holes = np.zeros((height, width), np.uint8)
        holes[20:44, 22:42] = 255
        valid = holes.copy()
        motion = np.zeros((8, 8), dtype=sparse.MOTION_DTYPE)
        motion["valid"] = 1
        motion["confidence"] = 255
        output, residual, reused, confidence, photometric = sparse.temporal_reuse_patch(
            seed, holes, previous, valid, motion, sparse.Roi(0, 0, 64), width, height,
            0.4, 1.0, 0.1, False,
        )
        self.assertEqual(reused, 24 * 20)
        self.assertEqual(int(np.count_nonzero(residual)), 0)
        self.assertTrue(np.all(output[20:44, 22:42] == 180))
        self.assertGreater(confidence, 0.99)
        self.assertLess(photometric, 0.01)

    def test_periodic_refresh_keeps_temporal_seed_but_regenerates_mask(self) -> None:
        previous = np.full((32, 32, 3), 120, np.uint8)
        seed = previous.copy()
        seed[8:24, 8:24] = 0
        holes = np.zeros((32, 32), np.uint8)
        holes[8:24, 8:24] = 255
        motion = np.zeros((4, 4), dtype=sparse.MOTION_DTYPE)
        motion["valid"] = 1
        motion["confidence"] = 255
        output, residual, reused, _, _ = sparse.temporal_reuse_patch(
            seed, holes, previous, holes, motion, sparse.Roi(0, 0, 32), 32, 32,
            0.4, 1.0, 0.1, True,
        )
        self.assertEqual(reused, 0)
        self.assertEqual(int(np.count_nonzero(residual)), 16 * 16)
        self.assertTrue(np.all(output[8:24, 8:24] == 120))

    def test_inward_feather_never_touches_foreground(self) -> None:
        mask = np.zeros((21, 21), np.uint8)
        mask[4:17, 8:13] = 255
        alpha = sparse.inward_feather(mask, 3.0)
        self.assertTrue(np.all(alpha[mask == 0] == 0.0))
        self.assertGreater(float(alpha[10, 10]), 0.9)
        self.assertLess(float(alpha[4, 8]), 0.5)

    def test_directional_prior_never_samples_foreground_side(self) -> None:
        image = np.zeros((9, 15, 3), np.uint8)
        image[:, :6] = (250, 10, 10)
        image[:, 9:] = (10, 20, 240)
        mask = np.zeros((9, 15), np.uint8)
        mask[:, 6:9] = 255
        prior = sparse.directional_background_prior(image, mask, "right")
        centre = prior[4, 7].astype(np.int16)
        self.assertLess(int(centre[0]), 60)
        self.assertGreater(int(centre[2]), 180)

        noisy = image.copy()
        noisy[:, 6:9] = (240, 240, 10)
        good = image.copy()
        good[:, 6:9] = (10, 20, 240)
        self.assertLess(
            sparse.score_generated_candidate(good, image, mask, "right"),
            sparse.score_generated_candidate(noisy, image, mask, "right"),
        )

    def test_directional_prior_preserves_background_texture(self) -> None:
        image = np.zeros((5, 16, 3), np.uint8)
        image[:, :6] = (240, 20, 20)
        for x in range(9, 16):
            image[:, x] = (10 + x * 3, 30, 80 + x * 7)
        mask = np.zeros((5, 16), np.uint8)
        mask[:, 6:9] = 255
        prior = sparse.directional_background_prior(image, mask, "right")
        # The restored strip must keep changing background texture instead of
        # collapsing into the old per-row median colour.
        restored = prior[2, 6:9].astype(np.int16)
        self.assertGreater(int(np.ptp(restored[:, 2])), 4)
        self.assertLess(int(restored[:, 0].max()), 80)

    def test_directional_alpha_only_feathers_background_side(self) -> None:
        mask = np.zeros((1, 12), np.uint8)
        mask[:, 3:9] = 255
        alpha = sparse.directional_compose_alpha(mask, "right", 4.0)
        self.assertEqual(float(alpha[0, 2]), 0.0)
        self.assertGreater(float(alpha[0, 3]), 0.99)
        self.assertLess(float(alpha[0, 8]), 0.25)


if __name__ == "__main__":
    unittest.main()
