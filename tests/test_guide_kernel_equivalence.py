from __future__ import annotations

import sys
from pathlib import Path

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
import guidegen  # noqa: E402


def reference_occlusion(
    confidence: np.ndarray, valid: np.ndarray, flow: np.ndarray
) -> np.ndarray:
    grad = np.maximum(
        np.abs(cv2.Sobel(flow[..., 0], cv2.CV_32F, 1, 0, ksize=3)),
        np.abs(cv2.Sobel(flow[..., 0], cv2.CV_32F, 0, 1, ksize=3)),
    )
    grad = np.maximum(
        grad,
        np.maximum(
            np.abs(cv2.Sobel(flow[..., 1], cv2.CV_32F, 1, 0, ksize=3)),
            np.abs(cv2.Sobel(flow[..., 1], cv2.CV_32F, 0, 1, ksize=3)),
        ),
    )
    cv2.multiply(grad, -0.18, grad)
    cv2.exp(grad, grad)
    cv2.multiply(confidence, grad, confidence)
    confidence[~valid] = 0.0
    return confidence


def reference_guided_depth(gray: np.ndarray, depth: np.ndarray) -> np.ndarray:
    guide = gray.astype(np.float32) / 255.0
    ksize = (5, 5)
    mean_i = cv2.boxFilter(guide, cv2.CV_32F, ksize, normalize=True)
    mean_p = cv2.boxFilter(depth, cv2.CV_32F, ksize, normalize=True)
    corr_i = cv2.boxFilter(guide * guide, cv2.CV_32F, ksize, normalize=True)
    corr_ip = cv2.boxFilter(guide * depth, cv2.CV_32F, ksize, normalize=True)
    variance = corr_i - mean_i * mean_i
    covariance = corr_ip - mean_i * mean_p
    a = covariance / (variance + 0.0025)
    b = mean_p - a * mean_i
    mean_a = cv2.boxFilter(a, cv2.CV_32F, ksize, normalize=True)
    mean_b = cv2.boxFilter(b, cv2.CV_32F, ksize, normalize=True)
    refined = mean_a * guide + mean_b
    return np.clip(0.35 * depth + 0.65 * refined, 0.02, 0.98).astype(np.float32)


def main() -> None:
    rng = np.random.default_rng(20260902)
    gray = rng.integers(0, 256, (217, 389), dtype=np.uint8)
    depth = rng.random((217, 389), dtype=np.float32) * 0.96 + 0.02
    flow = rng.normal(0, 4, (217, 389, 2)).astype(np.float32)
    confidence = rng.random((217, 389), dtype=np.float32)
    valid = rng.random((217, 389)) > 0.07

    expected_depth = reference_guided_depth(gray, depth)
    actual_depth = guidegen.guided_depth(gray, depth)
    expected_confidence = reference_occlusion(confidence.copy(), valid, flow)
    actual_confidence = guidegen.occlusion_aware_confidence(confidence.copy(), valid, flow)

    depth_error = float(np.max(np.abs(expected_depth - actual_depth)))
    confidence_error = float(np.max(np.abs(expected_confidence - actual_confidence)))
    if depth_error > 2e-6 or confidence_error > 2e-6:
        raise AssertionError(
            f"kernel mismatch: depth={depth_error:.9g}, confidence={confidence_error:.9g}"
        )
    print(
        f"GUIDE_KERNEL_EQUIVALENCE_OK depth_max={depth_error:.9g} "
        f"confidence_max={confidence_error:.9g}"
    )


if __name__ == "__main__":
    main()
