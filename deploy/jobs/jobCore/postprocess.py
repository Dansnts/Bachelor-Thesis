"""Stitches the tile masks back together and converts them into polygons.

Inverse step of the tiling: SAM3 produced one mask per tile, we place them back
on a full-size image (merge_masks), then turn each object into a polygon in the
Label Studio format (mask_to_polygon).
"""

import numpy as np
from PIL import Image


def merge_masks(masks, coords_list, img_w, img_h, scores):
    # Stitches the tile masks onto a large image, then splits the objects into
    # connected components. Each component gets a mean score weighted by its
    # overlap with the original tile masks.
    from scipy import ndimage

    full = np.zeros((img_h, img_w), dtype=np.uint8)
    placed = []
    for mask, (x, y, w, h) in zip(masks, coords_list):
        mask = mask.squeeze()
        # the mask is not the size of the tile (edge padding): we resize it. It
        # is binary (0/1), but PIL works on 8 bits, hence the 0/255 round-trip.
        # NEAREST avoids creating grey values, and the > 127 rebinarises
        # afterwards (255 -> True, 0 -> False).
        if mask.shape != (h, w):
            mask = (
                np.array(
                    Image.fromarray((mask * 255).astype(np.uint8)).resize(
                        (w, h), Image.NEAREST
                    )
                )
                > 127
            )
            mask = mask.astype(np.uint8)
        # keep the max: a pixel covered by several tiles stays at 1
        full[y : y + h, x : x + w] = np.maximum(full[y : y + h, x : x + w], mask)
        placed.append((mask, (x, y, w, h)))

    # connected components = distinct objects of the same label
    labeled, n = ndimage.label(full)
    results = []
    for i in range(1, n + 1):
        comp = (labeled == i).astype(np.uint8)
        # ignore the crumbs (segmentation noise)
        if comp.sum() < 100:
            continue
        # object score = mean of the tile scores, weighted by the overlap area
        # of each tile with this component
        total_w, weighted_s = 0.0, 0.0
        for (pm, (x, y, w, h)), s in zip(placed, scores):
            overlap = np.sum(pm * comp[y : y + h, x : x + w])
            if overlap > 0:
                weighted_s += s * overlap
                total_w += overlap
        score = weighted_s / total_w if total_w > 0 else 0.0
        results.append((comp, score))
    return results


def mask_to_polygon(mask, w, h):
    # Turns a binary mask into a simplified polygonal contour.
    import cv2

    contours, _ = cv2.findContours(
        (mask > 0).astype(np.uint8) * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )
    if not contours:
        return []
    # keep only the largest contour (the main object of the component)
    contour = max(contours, key=cv2.contourArea)
    # approxPolyDP reduces the number of points: epsilon proportional to the
    # perimeter -> light polygon that still follows the shape well
    epsilon = 0.002 * cv2.arcLength(contour, True)
    simplified = cv2.approxPolyDP(contour, epsilon, True)
    # fewer than 3 points = not a valid polygon
    if len(simplified) < 3:
        return []
    # coordinates as a percentage of the image dimensions (Label Studio format)
    return [[p[0][0] * 100.0 / w, p[0][1] * 100.0 / h] for p in simplified]
