"""Mask post-processing: mask_to_polygon and merge_masks (jobCore.postprocess).

Uses numpy/opencv/scipy but no GPU and no model. Builds synthetic binary masks
to check the vectorisation and the tile-stitching logic.
"""

import numpy as np


class TestMaskToPolygon:
    def test_square_mask_gives_a_polygon_in_percent(self, postprocess_module):
        mask = np.zeros((100, 100), dtype=np.uint8)
        mask[20:60, 30:70] = 1                       # a 40x40 filled square
        pts = postprocess_module.mask_to_polygon(mask, 100, 100)
        assert len(pts) >= 3                          # a real polygon
        # coordinates expressed as percentage of the image dimensions (0..100)
        assert all(0 <= x <= 100 and 0 <= y <= 100 for x, y in pts)
        # the square sits roughly in [30,70] x [20,60] percent
        xs = [x for x, _ in pts]
        assert min(xs) < 40 and max(xs) > 60

    def test_percent_uses_given_dimensions(self, postprocess_module):
        mask = np.zeros((100, 200), dtype=np.uint8)
        mask[:, 100:200] = 1                          # right half of a 200-wide image
        pts = postprocess_module.mask_to_polygon(mask, 200, 100)
        # right half -> x percentages reach ~100, none far left of 50
        assert max(x for x, _ in pts) > 90
        assert min(x for x, _ in pts) >= 50 - 1

    def test_empty_mask_returns_no_points(self, postprocess_module):
        mask = np.zeros((50, 50), dtype=np.uint8)
        assert postprocess_module.mask_to_polygon(mask, 50, 50) == []

    def test_degenerate_single_pixel_is_not_a_polygon(self, postprocess_module):
        mask = np.zeros((50, 50), dtype=np.uint8)
        mask[10, 10] = 1                              # < 3 distinct points
        assert postprocess_module.mask_to_polygon(mask, 50, 50) == []


class TestMergeMasks:
    def test_single_tile_one_component(self, postprocess_module):
        # one 100x100 tile fully set at the top-left of a 200x200 image
        tile = np.ones((100, 100), dtype=np.uint8)
        results = postprocess_module.merge_masks([tile], [(0, 0, 100, 100)], 200, 200, [0.8])
        assert len(results) == 1
        comp, score = results[0]
        assert comp.shape == (200, 200)
        assert score == 0.8                            # single tile -> its own score

    def test_two_disjoint_objects_two_components(self, postprocess_module):
        a = np.ones((40, 40), dtype=np.uint8)
        b = np.ones((40, 40), dtype=np.uint8)
        results = postprocess_module.merge_masks(
            [a, b], [(0, 0, 40, 40), (150, 150, 40, 40)], 200, 200, [0.5, 0.9]
        )
        assert len(results) == 2                       # far apart -> distinct objects

    def test_tiny_specks_are_dropped(self, postprocess_module):
        speck = np.zeros((40, 40), dtype=np.uint8)
        speck[0, 0] = 1                                # 1 px, below the 100 px floor
        results = postprocess_module.merge_masks([speck], [(0, 0, 40, 40)], 200, 200, [0.9])
        assert results == []

    def test_overlapping_tiles_merge_into_one_object(self, postprocess_module):
        # two tiles that overlap in space describe the same object -> one component
        t1 = np.ones((100, 100), dtype=np.uint8)
        t2 = np.ones((100, 100), dtype=np.uint8)
        results = postprocess_module.merge_masks(
            [t1, t2], [(0, 0, 100, 100), (50, 0, 100, 100)], 300, 200, [1.0, 0.6]
        )
        assert len(results) == 1
        _, score = results[0]
        assert 0.6 <= score <= 1.0                     # overlap-weighted mean

    def test_mask_resized_when_shape_differs_from_coords(self, postprocess_module):
        # simulates a padded/edge tile whose mask is larger than its real extent:
        # merge_masks must resize it to (h, w) instead of crashing
        mask = np.ones((50, 50), dtype=np.uint8)
        results = postprocess_module.merge_masks([mask], [(0, 0, 30, 30)], 100, 100, [0.7])
        assert len(results) == 1
        assert results[0][0].shape == (100, 100)
