"""Tests for the lightweight parts of the optional M2SVid adapter."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import m2svid_worker as m2s  # noqa: E402


class M2SVidWorkerTests(unittest.TestCase):
    def test_portable_cache_root_is_derived_from_repository(self):
        source = Path(m2s.__file__).read_text(encoding="utf-8")
        self.assertIn('portable_root = repository.parent.parent', source)
        self.assertIn('os.environ.setdefault("HF_HOME"', source)

    def test_model_canvas_is_divisible_by_64_and_preserves_content_aspect(self) -> None:
        inner_w, inner_h, canvas_w, canvas_h, pad_x, pad_y = m2s.model_geometry(
            1920, 1080, 512
        )
        self.assertEqual(canvas_w % 64, 0)
        self.assertEqual(canvas_h % 64, 0)
        self.assertEqual(inner_w, 512)
        self.assertAlmostEqual(inner_w / inner_h, 1920 / 1080, delta=0.02)
        self.assertEqual(canvas_w - inner_w, pad_x * 2)
        self.assertEqual(canvas_h - inner_h, pad_y * 2)

    def test_automatic_limits_scale_with_available_vram(self) -> None:
        self.assertEqual(m2s.auto_limits(8187, 0, 0), (384, 6))
        self.assertEqual(m2s.auto_limits(16384, 0, 0), (640, 16))
        self.assertEqual(m2s.auto_limits(24576, 0, 0), (768, 25))

    def test_user_limits_are_bounded_by_official_25_frame_window(self) -> None:
        self.assertEqual(m2s.auto_limits(16384, 2048, 99), (1024, 25))
        self.assertEqual(m2s.auto_limits(16384, 128, 1), (256, 3))


if __name__ == "__main__":
    unittest.main()
