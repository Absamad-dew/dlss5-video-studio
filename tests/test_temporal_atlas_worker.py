"""Regression tests for sparse multi-frame Temporal Atlas repair."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

import temporal_atlas_worker as atlas  # noqa: E402


class TemporalAtlasTests(unittest.TestCase):
    def test_layout_geometry_preserves_requested_container(self) -> None:
        self.assertEqual(atlas.layout_geometry(3840, 2160, "half-sbs"), (1920, 2160, 3840, 2160))
        self.assertEqual(atlas.layout_geometry(3840, 2160, "full-sbs"), (3840, 2160, 7680, 2160))
        self.assertEqual(atlas.layout_geometry(3840, 2160, "half-ou"), (3840, 1080, 3840, 2160))

    def test_candidate_offsets_are_sparse_and_include_full_window(self) -> None:
        self.assertEqual(atlas.candidate_offsets(8), [-1, 1, -2, 2, -4, 4, -8, 8])
        self.assertEqual(atlas.candidate_offsets(6), [-1, 1, -2, 2, -4, 4, -6, 6])

    def test_directional_background_never_crosses_reveal_side(self) -> None:
        values = np.array([[1, 2, 9, 8, 7]], dtype=np.float32)
        holes = np.array([[False, True, True, False, False]])
        from_right = atlas.directional_background(values, holes, True)
        from_left = atlas.directional_background(values, holes, False)
        np.testing.assert_array_equal(from_right, np.array([[1, 8, 8, 8, 7]], np.float32))
        np.testing.assert_array_equal(from_left, np.array([[1, 1, 1, 8, 7]], np.float32))

    def test_compose_flow_accumulates_warped_adjacent_motion(self) -> None:
        shape = (4, 6)
        source = np.zeros((*shape, 3), np.uint8)
        stereo = np.zeros((4, 12, 3), np.uint8)
        mask = np.zeros(shape, bool)
        depth = np.zeros(shape, np.float32)
        frames = {
            index: atlas.AtlasFrame(index, 0, source, stereo, mask, mask, depth)
            for index in range(3)
        }
        for index in (0, 1):
            frames[index].flow_next = np.dstack(
                (np.ones(shape, np.float32), np.zeros(shape, np.float32))
            )
            frames[index].confidence_next = np.full(shape, 0.8 - 0.1 * index, np.float32)
        flow, confidence = atlas.compose_flow(frames, 0, 2)
        self.assertAlmostEqual(float(flow[1, 1, 0]), 2.0, places=5)
        self.assertAlmostEqual(float(confidence[1, 1]), 0.7, places=5)

    def test_cycle_reliability_rejects_inconsistent_flow(self) -> None:
        image = np.full((8, 8, 3), 100, np.uint8)
        forward = np.zeros((8, 8, 2), np.float32)
        reverse = np.zeros_like(forward)
        consistent = atlas.flow_reliability(image, image, forward, reverse)
        reverse[..., 0] = 5.0
        inconsistent = atlas.flow_reliability(image, image, forward, reverse)
        self.assertGreater(float(np.mean(consistent)), 0.99)
        self.assertLess(float(np.mean(inconsistent)), 0.01)

    def test_neural_roi_grouping_obeys_launch_budget(self) -> None:
        holes = np.zeros((720, 1280), bool)
        holes[100:180, 80:110] = True
        holes[250:330, 420:450] = True
        holes[420:520, 900:940] = True
        boxes = atlas.clustered_hole_boxes(holes, max_regions=2, merge_gap=24)
        self.assertLessEqual(len(boxes), 2)
        covered = np.zeros_like(holes)
        for x0, y0, x1, y1 in boxes:
            covered[y0:y1, x0:x1] = True
        self.assertTrue(np.all(covered[holes]))


if __name__ == "__main__":
    unittest.main()
