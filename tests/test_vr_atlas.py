import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
import cv2
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'python'))
from vr_atlas import prepare_features, feature_link, validate_flow, RegistrationCache, SourceCache
from vr_reconstruction import background_link, source_flow_link


def packets():
    rng = np.random.default_rng(51)
    rgb = rng.integers(0, 256, (144, 256, 3), dtype=np.uint8)
    result = []
    for i in range(6):
        image = np.roll(rgb, i*2, axis=1)
        image[30:65, 70+i*4:100+i*4] = (23, 110, 180)
        depth = np.full((72, 128), .25, np.float32)
        depth[15:33, 35+i*2:50+i*2] = .8
        result.append(SimpleNamespace(index=i, guides=image, depth=torch.from_numpy(depth),
                      source=torch.from_numpy(image).permute(2, 0, 1)))
    return result


class AtlasTests(unittest.TestCase):
    def test_cached_features_same_homography(self):
        items = packets()
        for a, b in zip(items, items[1:]):
            expected = background_link(a.guides, b.guides, a.depth.numpy(), b.depth.numpy())
            actual = feature_link(prepare_features(a.guides, a.depth.numpy()),
                                  prepare_features(b.guides, b.depth.numpy()))
            self.assertEqual(expected.reason, actual.reason)
            self.assertEqual(expected.confidence, actual.confidence)
            if expected.matrix is not None: np.testing.assert_array_equal(expected.matrix, actual.matrix)

    def test_cached_bidirectional_flow_same_each_direction(self):
        a, b = packets()[:2]
        pa, pb = prepare_features(a.guides, a.depth.numpy()), prepare_features(b.guides, b.depth.numpy())
        dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_FAST)
        dis.setVariationalRefinementIterations(2)
        flow, reverse = dis.calc(pb.gray, pa.gray, None), dis.calc(pa.gray, pb.gray, None)
        for prev, cur, f, r in ((pa, pb, flow, reverse), (pb, pa, reverse, flow)):
            expected = source_flow_link(prev.rgb, cur.rgb, prev.depth, cur.depth)
            actual = validate_flow(prev, cur, f, r)
            np.testing.assert_array_equal(expected.flow, actual.flow)
            np.testing.assert_array_equal(expected.valid, actual.valid)

    def test_registration_and_source_cache_bounded(self):
        stats = dict(registered_pairs=0, rejected_pairs=0, registration_rejections={}, source_flow_pairs=0)
        cache = RegistrationCache(stats)
        source = SourceCache(limit_mb=.3, device='cpu')
        items = packets()
        for a, b in zip(items, items[1:]):
            cache.get(a, b); cache.get(b, a)
            torch.testing.assert_close(source.get(a)[0], a.source)
        self.assertEqual(stats['orb_frames'], 6)
        self.assertLessEqual(source.bytes, source.limit)
        cache.prune(3); source.prune(3)
        self.assertTrue(all(i >= 3 for i in cache.features))
        self.assertTrue(all(min(pair) >= 3 for pair in cache.links))
        cache.clear(); source.clear()
        self.assertFalse(cache.links); self.assertFalse(cache.flows)
        self.assertEqual(source.bytes, 0)


if __name__ == '__main__': unittest.main()
