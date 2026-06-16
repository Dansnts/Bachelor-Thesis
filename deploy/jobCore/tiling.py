"""Découpe une grande image en tuiles carrées avec recouvrement.

Les images panoramiques sont trop grandes pour passer d'un coup dans SAM3 : on
les découpe en tuiles de taille fixe (tile_size). Les tuiles se chevauchent
(tile_stride < tile_size) pour qu'un objet pile sur une bordure se retrouve
entier dans au moins une tuile. On garde les coordonnées de chaque tuile pour
pouvoir recoller les masques sur l'image entière ensuite (cf. postprocess).
"""

from PIL import Image


def tile_positions(img_w, img_h, tile_size, tile_stride):
    """Renvoie la liste des tuiles (x, y, w, h) qui couvrent toute l'image."""

    def positions_1d(size):
        # positions de départ sur un axe, espacées de tile_stride
        pos = []
        x = 0
        while x + tile_size < size:
            pos.append(x)
            x += tile_stride
        # dernière tuile recalée sur le bord pour couvrir la fin de l'axe
        # sans déborder (sinon on raterait la bande de droite / du bas)
        pos.append(size - tile_size if size > tile_size else 0)
        return pos

    positions = []
    for y in positions_1d(img_h):
        for x in positions_1d(img_w):
            # w/h = taille réelle de la tuile (peut être < tile_size sur un bord)
            w = min(tile_size, img_w - x)
            h = min(tile_size, img_h - y)
            positions.append((x, y, w, h))
    return positions


def extract_tiles(image, tile_size, tile_stride):
    """Découpe l'image en tuiles. Renvoie une liste de (tuile PIL, (x, y, w, h))."""
    img_w, img_h = image.size
    tiles = []
    for x, y, w, h in tile_positions(img_w, img_h, tile_size, tile_stride):
        tile = image.crop((x, y, x + w, y + h))
        # bord droit/bas : on complète la tuile avec du noir pour garder une
        # taille fixe (le modèle attend des tuiles carrées tile_size × tile_size).
        if w < tile_size or h < tile_size:
            padded = Image.new("RGB", (tile_size, tile_size), (0, 0, 0))
            padded.paste(tile, (0, 0))
            tile = padded
        tiles.append((tile, (x, y, w, h)))
    return tiles
