"""Recolle les masques des tuiles et les convertit en polygones.

Étape inverse du tiling : SAM3 a produit un masque par tuile, on les remet sur
une image à la taille d'origine (merge_masks), puis on transforme chaque objet
en polygone au format Label Studio (mask_to_polygon).
"""

import numpy as np
from PIL import Image


def merge_masks(masks, coords_list, img_w, img_h, scores):
    # Recolle les masques des tuiles sur une grande image, puis sépare les
    # objets en composantes connexes. Chaque composante reçoit un score moyen
    # pondéré par le recouvrement avec les masques de tuiles d'origine.
    from scipy import ndimage

    full = np.zeros((img_h, img_w), dtype=np.uint8)
    placed = []
    for mask, (x, y, w, h) in zip(masks, coords_list):
        mask = mask.squeeze()
        # le masque ne fait pas la taille de la tuile (padding du bord) : on le
        # redimensionne. Il est binaire (0/1), mais PIL travaille sur du 8 bits,
        # d'où l'aller-retour 0/255. NEAREST évite de créer des valeurs grises,
        # et le > 127 rebinarise après coup (255 -> True, 0 -> False).
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
        # on garde le max : un pixel couvert par plusieurs tuiles reste à 1
        full[y : y + h, x : x + w] = np.maximum(full[y : y + h, x : x + w], mask)
        placed.append((mask, (x, y, w, h)))

    # composantes connexes = objets distincts du même label
    labeled, n = ndimage.label(full)
    results = []
    for i in range(1, n + 1):
        comp = (labeled == i).astype(np.uint8)
        # ignore les miettes (bruit de segmentation)
        if comp.sum() < 100:
            continue
        # score de l'objet = moyenne des scores des tuiles, pondérée par la
        # surface de recouvrement de chaque tuile avec cette composante
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
    # Transforme un masque binaire en contour polygonal simplifié.
    import cv2

    contours, _ = cv2.findContours(
        (mask > 0).astype(np.uint8) * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )
    if not contours:
        return []
    # on ne garde que le plus gros contour (l'objet principal de la composante)
    contour = max(contours, key=cv2.contourArea)
    # approxPolyDP réduit le nombre de points : epsilon proportionnel au
    # périmètre -> polygone léger qui suit quand même bien la forme
    epsilon = 0.002 * cv2.arcLength(contour, True)
    simplified = cv2.approxPolyDP(contour, epsilon, True)
    # moins de 3 points = pas un polygone valide
    if len(simplified) < 3:
        return []
    # coordonnées en pourcentage des dimensions de l'image (format Label Studio)
    return [[p[0][0] * 100.0 / w, p[0][1] * 100.0 / h] for p in simplified]
