from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

import numpy as np


GUIDEGEN = Path(__file__).resolve().parents[1] / "python" / "guidegen.py"
spec = importlib.util.spec_from_file_location("guidegen_under_test", GUIDEGEN)
assert spec is not None and spec.loader is not None
guidegen = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = guidegen
spec.loader.exec_module(guidegen)


class FakeDepthRuntime:
    def infer_frame(self, frame: np.ndarray, width: int, height: int) -> np.ndarray:
        return np.full((height, width), float(frame[0, 0, 0]), dtype=np.float32)


def main() -> None:
    frame = np.zeros((2, 2, 3), dtype=np.uint8)
    prefetcher = guidegen.DepthPrefetcher(FakeDepthRuntime(), 2, 2, threaded=False)

    assert prefetcher.schedule(0, frame)
    assert prefetcher.schedule(8, frame)
    _, _, _, hit, discarded = prefetcher.take(0, frame)
    assert hit and discarded == 0 and 8 in prefetcher.futures

    _, _, _, hit, discarded = prefetcher.take(4, frame)
    assert not hit and discarded == 1 and 8 not in prefetcher.futures
    prefetcher.close()
    print("DEPTH_PREFETCH_SCHEDULE_OK")


if __name__ == "__main__":
    main()
