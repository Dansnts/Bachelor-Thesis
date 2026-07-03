"""Tiling geometry: tile_positions and extract_tiles (jobCore.tiling).

Pure geometry, no model. These tests pin the two properties the pipeline
relies on: full coverage of the image, and overlap when stride < tile. They
also document the failure mode of a misconfigured stride > tile (uncovered
gaps), which is the geometric reason the API should reject it.
"""

from PIL import Image


def _covered(positions, axis):
    """True if the union of the tiles covers [0, size) on the given axis."""
    # axis: (index_of_start, index_of_len) -> (0, 2) for x/w, (1, 3) for y/h
    i0, il = axis
    intervals = sorted((p[i0], p[i0] + p[il]) for p in positions)
    reach = 0
    for start, end in intervals:
        if start > reach:      # a hole opened up
            return False
        reach = max(reach, end)
    return reach


class TestTilePositions:
    def test_image_smaller_than_tile_is_one_tile(self, tiling_module):
        pos = tiling_module.tile_positions(500, 400, 1008, 768)
        assert pos == [(0, 0, 500, 400)]

    def test_exact_multiple_no_overlap_full_coverage(self, tiling_module):
        # 2016 = 2 x 1008, stride == tile -> two tiles, no overlap, no gap
        pos = tiling_module.tile_positions(2016, 1008, 1008, 1008)
        xs = sorted({p[0] for p in pos})
        assert xs == [0, 1008]
        assert _covered(pos, (0, 2)) == 2016

    def test_overlap_when_stride_below_tile(self, tiling_module):
        pos = tiling_module.tile_positions(2000, 1008, 1008, 768)
        xs = sorted({p[0] for p in pos})
        # starts at 0, steps by 768, last snapped to the right edge (2000-1008)
        assert xs == [0, 768, 992]
        assert _covered(pos, (0, 2)) == 2000        # whole width covered
        # consecutive tiles overlap (start of next < end of previous)
        assert xs[1] < 0 + 1008

    def test_full_coverage_on_a_real_panorama(self, tiling_module):
        pos = tiling_module.tile_positions(8000, 4000, 1008, 768)
        assert _covered(pos, (0, 2)) == 8000        # width
        assert _covered(pos, (1, 3)) == 4000        # height

    def test_last_tile_snapped_to_edge_never_overflows(self, tiling_module):
        pos = tiling_module.tile_positions(8000, 4000, 1008, 768)
        assert max(p[0] + p[2] for p in pos) == 8000   # no tile spills past the edge
        assert max(p[1] + p[3] for p in pos) == 4000

    def test_stride_larger_than_tile_leaves_gaps(self, tiling_module):
        # DOCUMENTED FAILURE MODE: stride > tile -> pixels between tiles are
        # never covered. This is why the API ought to reject stride > tile
        # (see test_api_validation.TestHardeningGaps.test_stride_larger_than_tile).
        pos = tiling_module.tile_positions(3000, 1008, 1008, 1200)
        assert _covered(pos, (0, 2)) is False


class TestExtractTiles:
    def test_edge_tile_is_padded_to_full_size(self, tiling_module):
        img = Image.new("RGB", (500, 400), (10, 20, 30))
        tiles = tiling_module.extract_tiles(img, 1008, 768)
        assert len(tiles) == 1
        tile, coords = tiles[0]
        # tile padded to the model's expected square size...
        assert tile.size == (1008, 1008)
        # ...but coords keep the real (unpadded) extent for stitching back
        assert coords == (0, 0, 500, 400)

    def test_interior_tile_keeps_full_size(self, tiling_module):
        img = Image.new("RGB", (2016, 1008), (0, 0, 0))
        tiles = tiling_module.extract_tiles(img, 1008, 1008)
        assert all(t.size == (1008, 1008) for t, _ in tiles)
        assert len(tiles) == 2

    def test_padding_pixels_are_black(self, tiling_module):
        img = Image.new("RGB", (500, 400), (255, 255, 255))  # all white content
        tile, _ = tiling_module.extract_tiles(img, 1008, 768)[0]
        assert tile.getpixel((499, 399)) == (255, 255, 255)  # real content
        assert tile.getpixel((900, 900)) == (0, 0, 0)        # padded region
