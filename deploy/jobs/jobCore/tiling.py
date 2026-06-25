"""Splits a large image into overlapping square tiles.

Panoramic images are too large to go through SAM3 in one pass: we split them
into fixed-size tiles (tile_size). The tiles overlap (tile_stride < tile_size)
so that an object sitting exactly on a border ends up whole in at least one
tile. We keep the coordinates of each tile to be able to stitch the masks back
onto the full image afterwards (see postprocess).
"""

from PIL import Image


def tile_positions(img_w, img_h, tile_size, tile_stride):
    """Returns the list of tiles (x, y, w, h) that cover the whole image."""

    def positions_1d(size):
        # start positions on one axis, spaced by tile_stride
        pos = []
        x = 0
        while x + tile_size < size:
            pos.append(x)
            x += tile_stride
        # last tile snapped to the edge to cover the end of the axis without
        # overflowing (otherwise we would miss the right / bottom strip)
        pos.append(size - tile_size if size > tile_size else 0)
        return pos

    positions = []
    for y in positions_1d(img_h):
        for x in positions_1d(img_w):
            # w/h = actual tile size (may be < tile_size on an edge)
            w = min(tile_size, img_w - x)
            h = min(tile_size, img_h - y)
            positions.append((x, y, w, h))
    return positions


def extract_tiles(image, tile_size, tile_stride):
    """Splits the image into tiles. Returns a list of (PIL tile, (x, y, w, h))."""
    img_w, img_h = image.size
    tiles = []
    for x, y, w, h in tile_positions(img_w, img_h, tile_size, tile_stride):
        tile = image.crop((x, y, x + w, y + h))
        # right/bottom edge: pad the tile with black to keep a fixed size
        # (the model expects square tiles tile_size x tile_size).
        if w < tile_size or h < tile_size:
            padded = Image.new("RGB", (tile_size, tile_size), (0, 0, 0))
            padded.paste(tile, (0, 0))
            tile = padded
        tiles.append((tile, (x, y, w, h)))
    return tiles
