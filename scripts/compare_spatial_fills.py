"""Compare fast, local disocclusion fillers on one stereo seed frame.

This is a QA helper, not a production entry point.  It deliberately composites
only the strict geometry-hole mask so that a candidate cannot repaint the
foreground or the rest of the frame.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def read_first_frame(path: Path, grayscale: bool = False) -> np.ndarray:
    capture = cv2.VideoCapture(str(path))
    ok, frame = capture.read()
    capture.release()
    if not ok:
        raise RuntimeError(f"Cannot decode first frame: {path}")
    if grayscale:
        return cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    return frame


def clean_mask(mask: np.ndarray) -> np.ndarray:
    binary = (mask >= 96).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
    cleaned = np.zeros_like(binary)
    for label in range(1, count):
        if int(stats[label, cv2.CC_STAT_AREA]) >= 3:
            cleaned[labels == label] = 255
    return cleaned


def expand_toward_foreground(mask: np.ndarray, pixels: int) -> np.ndarray:
    """Hide the foreground-side boundary from an inpainting solver.

    Right-eye disocclusions sit to the right of the occluder, therefore the
    foreground is on the left and the revealed background is on the right.
    """
    if pixels <= 0:
        return mask.copy()
    kernel = np.ones((3, pixels + 1), np.uint8)
    # OpenCV's anchor describes which input position is aligned with the
    # output pixel. Anchor x=0 grows a source mask towards smaller x (left),
    # which is the foreground side for the generated right eye.
    anchor = (0, 1)
    return cv2.dilate(mask, kernel, anchor=anchor)


def directional_mirror(frame: np.ndarray, mask: np.ndarray) -> np.ndarray:
    result = frame.copy()
    binary = mask > 0
    height, width = binary.shape
    for y in range(height):
        xs = np.flatnonzero(binary[y])
        if xs.size == 0:
            continue
        split = np.flatnonzero(np.diff(xs) > 1) + 1
        for run in np.split(xs, split):
            left, right = int(run[0]), int(run[-1])
            available = width - right - 1
            if available <= 0:
                continue
            for x in run:
                source_x = min(width - 1, right + 1 + (right - int(x)))
                result[y, x] = frame[y, source_x]
    # Remove row-to-row zippering without touching native pixels.
    smooth = cv2.bilateralFilter(result, 5, 18, 3)
    result[binary] = smooth[binary]
    return result


def push_pull(frame: np.ndarray, mask: np.ndarray) -> np.ndarray:
    """Normalized multiscale fill; cheap and stable for very narrow holes."""
    unknown = mask > 0
    value = frame.astype(np.float32)
    weight = (~unknown).astype(np.float32)
    levels: list[tuple[np.ndarray, np.ndarray]] = [(value, weight)]
    while min(value.shape[:2]) > 8 and np.any(weight < 0.999):
        numerator = cv2.pyrDown(value * weight[..., None])
        denominator = cv2.pyrDown(weight)
        value = numerator / np.maximum(denominator[..., None], 1e-5)
        weight = np.clip(denominator, 0.0, 1.0)
        levels.append((value, weight))
        if np.all(weight > 1e-3):
            break
    value, weight = levels[-1]
    for target_value, target_weight in reversed(levels[:-1]):
        up_value = cv2.resize(value, (target_value.shape[1], target_value.shape[0]), interpolation=cv2.INTER_LINEAR)
        up_weight = cv2.resize(weight, (target_value.shape[1], target_value.shape[0]), interpolation=cv2.INTER_LINEAR)
        missing = target_weight < 0.999
        target_value[missing] = up_value[missing]
        target_weight[missing] = np.maximum(target_weight[missing], up_weight[missing])
        value, weight = target_value, target_weight
    result = frame.copy()
    result[unknown] = np.clip(value[unknown], 0, 255).astype(np.uint8)
    return result


def strict_composite(base: np.ndarray, candidate: np.ndarray, mask: np.ndarray) -> np.ndarray:
    result = base.copy()
    active = mask > 0
    result[active] = candidate[active]
    return result


def background_seam_score(image: np.ndarray, mask: np.ndarray) -> float:
    """Measure discontinuity only on the revealed-background side of holes."""
    binary = mask > 0
    height, width = binary.shape
    errors: list[float] = []
    lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB).astype(np.float32)
    for y in range(1, height - 1):
        xs = np.flatnonzero(binary[y])
        if xs.size == 0:
            continue
        split = np.flatnonzero(np.diff(xs) > 1) + 1
        for run in np.split(xs, split):
            right = int(run[-1])
            if right + 2 >= width:
                continue
            boundary = np.abs(lab[y, right] - lab[y, right + 1]).mean()
            continuation = np.abs(
                (lab[y, right] - lab[y, right + 1])
                - (lab[y, right + 1] - lab[y, right + 2])
            ).mean()
            vertical = np.abs(lab[y - 1, right] - 2 * lab[y, right] + lab[y + 1, right]).mean()
            errors.append(float(boundary + 0.55 * continuation + 0.15 * vertical))
    return float(np.mean(errors)) if errors else float("inf")


def make_contact_sheet(images: dict[str, np.ndarray], mask: np.ndarray) -> np.ndarray:
    ys, xs = np.where(mask > 0)
    if xs.size:
        x1, x2 = max(0, int(xs.min()) - 120), min(mask.shape[1], int(xs.max()) + 121)
        y1, y2 = max(0, int(ys.min()) - 80), min(mask.shape[0], int(ys.max()) + 81)
    else:
        x1, y1, x2, y2 = 0, 0, mask.shape[1], mask.shape[0]
    tiles = []
    for name, image in images.items():
        crop = image[y1:y2, x1:x2].copy()
        cv2.rectangle(crop, (0, 0), (crop.shape[1] - 1, 34), (0, 0, 0), -1)
        cv2.putText(crop, name, (10, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2, cv2.LINE_AA)
        tiles.append(crop)
    while len(tiles) % 3:
        tiles.append(np.zeros_like(tiles[0]))
    rows = [np.hstack(tiles[i : i + 3]) for i in range(0, len(tiles), 3)]
    return np.vstack(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=Path, required=True)
    parser.add_argument("--mask", type=Path, required=True)
    parser.add_argument("--migan", type=Path)
    parser.add_argument("--migan-model", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    seed = read_first_frame(args.seed)
    mask = clean_mask(read_first_frame(args.mask, grayscale=True))
    expanded = expand_toward_foreground(mask, 12)

    candidates: dict[str, np.ndarray] = {
        "seed": seed,
        "directional": directional_mirror(seed, mask),
        "push-pull": push_pull(seed, mask),
        "telea-one-sided": cv2.inpaint(seed, expanded, 3, cv2.INPAINT_TELEA),
        "ns-one-sided": cv2.inpaint(seed, expanded, 3, cv2.INPAINT_NS),
    }
    if args.migan and args.migan.exists():
        candidates["MI-GAN"] = cv2.imread(str(args.migan), cv2.IMREAD_COLOR)
    if args.migan_model and args.migan_model.exists():
        import onnxruntime as ort

        session = ort.InferenceSession(
            str(args.migan_model),
            providers=["DmlExecutionProvider", "CPUExecutionProvider"],
        )
        rgb = cv2.cvtColor(seed, cv2.COLOR_BGR2RGB).transpose(2, 0, 1)[None]
        for expansion in (0, 4, 8, 12, 20):
            conditioning = expand_toward_foreground(mask, expansion)
            known = np.where(conditioning[None, None] > 0, 0, 255).astype(np.uint8)
            generated = session.run(None, {"image": rgb, "mask": known})[0][0]
            candidates[f"MI-GAN gapw +{expansion}"] = cv2.cvtColor(
                generated.transpose(1, 2, 0), cv2.COLOR_RGB2BGR
            )

    composites = {
        name: strict_composite(seed, image, mask) if name != "seed" else image
        for name, image in candidates.items()
    }
    scores = {
        name: background_seam_score(image, mask)
        for name, image in composites.items()
        if name != "seed"
    }
    for name, image in composites.items():
        cv2.imwrite(str(args.output / f"{name.lower().replace(' ', '-')} .png".replace(" .", ".")), image)
    sheet = make_contact_sheet(composites, mask)
    cv2.imwrite(str(args.output / "contact-sheet.png"), sheet)
    (args.output / "scores.json").write_text(json.dumps(scores, indent=2), encoding="utf-8")
    print(json.dumps({"mask_pixels": int((mask > 0).sum()), "scores": scores}, indent=2))


if __name__ == "__main__":
    main()
