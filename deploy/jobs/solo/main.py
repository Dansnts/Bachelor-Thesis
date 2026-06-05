import argparse
import io
import json
import os

import numpy as np
import ray
import torch
from dotenv import load_dotenv
from exif import Image as ExifImage
from PIL import Image

load_dotenv("/Users/dani/Cours/6.SEM/TB/.env")
parser = argparse.ArgumentParser()
parser.add_argument("--imageUri", required=True)
parser.add_argument("--bucket", type=str, required=True)
parser.add_argument("--labels", nargs="+", required=True)
parser.add_argument("--tileSize", type=int, default=1008)
parser.add_argument("--tileStride", type=int, default=768)
args = parser.parse_args()


# Fonctions
## EXIF
def getGPSFromEXIF(picurePath):
    pictureName = os.path.basename(picurePath)

    wantedTags = ["gps_altitude", "gps_img_direction", "datetime_original"]
    pairedTags = [
        ("gps_latitude_ref", "gps_latitude"),
        ("gps_longitude_ref", "gps_longitude"),
    ]

    with open(picurePath, "rb") as picture:
        myPicture = Image(picture)
        hasExif = "" if myPicture.has_exif else "'nt"

        print.info(
            "The pirture",
            pictureName,
            "does",
            hasExif,
            " have EXIF data on it.",
        )

        for pictureTag in myPicture.list_all():
            if pictureTag in wantedTags:
                print(pictureTag, ":", myPicture.get(pictureTag))

        print()

        for ref, tag in pairedTags:
            print(tag, ":", myPicture.get(ref), myPicture.get(tag))


## S3
def s3Client():
    import boto3
    from botocore.client import Config

    return boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 1}),
        verify=False,
    )


def getImage(bucket: str, imageURL: str):
    picture = s3Client().get_object(Bucket=bucket, Key=imageURL)
    return picture["Body"].read()


## Tiles
def patchPosition(img_w, img_h, tile_size, tile_stride):
    def positions_1d(size):
        pos = []
        x = 0
        while x + tile_size < size:
            pos.append(x)
            x += tile_stride
        pos.append(size - tile_size if size > tile_size else 0)
        return pos

    positions = []
    for y in positions_1d(img_h):
        for x in positions_1d(img_w):
            w = min(tile_size, img_w - x)
            h = min(tile_size, img_h - y)
            positions.append((x, y, w, h))
    return positions


def getPatches(image, tile_size, tile_stride):
    img_w, img_h = image.size
    patches = []
    for x, y, w, h in patchPosition(img_w, img_h, tile_size, tile_stride):
        patch = image.crop((x, y, x + w, y + h))
        if w < tile_size or h < tile_size:
            padded = Image.new("RGB", (tile_size, tile_size), (0, 0, 0))
            padded.paste(patch, (0, 0))
            patch = padded
        patches.append((patch, (x, y, w, h)))
    return patches


## Post processing
def mergeMasks(masks, coords_list, img_w, img_h, scores):
    from scipy import ndimage

    full = np.zeros((img_h, img_w), dtype=np.uint8)
    placed = []
    for mask, (x, y, w, h) in zip(masks, coords_list):
        mask = mask.squeeze()
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
        full[y : y + h, x : x + w] = np.maximum(full[y : y + h, x : x + w], mask)
        placed.append((mask, (x, y, w, h)))

    labeled, n = ndimage.label(full)
    results = []
    for i in range(1, n + 1):
        comp = (labeled == i).astype(np.uint8)
        if comp.sum() < 100:
            continue
        total_w, weighted_s = 0.0, 0.0
        for (pm, (x, y, w, h)), s in zip(placed, scores):
            overlap = np.sum(pm * comp[y : y + h, x : x + w])
            if overlap > 0:
                weighted_s += s * overlap
                total_w += overlap
        score = weighted_s / total_w if total_w > 0 else 0.0
        results.append((comp, score))
    return results


def maskToPolygon(mask, w, h):
    import cv2

    contours, _ = cv2.findContours(
        (mask > 0).astype(np.uint8) * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )
    if not contours:
        return []
    contour = max(contours, key=cv2.contourArea)
    epsilon = 0.002 * cv2.arcLength(contour, True)
    simplified = cv2.approxPolyDP(contour, epsilon, True)
    if len(simplified) < 3:
        return []
    return [[p[0][0] * 100.0 / w, p[0][1] * 100.0 / h] for p in simplified]


def toLabelStudio(image_uri, polygons, img_w, img_h):
    results = []
    for label, points, score in polygons:
        results.append({
            "type": "polygonlabels",
            "from_name": "label",
            "to_name": "image",
            "original_width": img_w,
            "original_height": img_h,
            "value": {
                "closed": True,
                "polygonlabels": [label],
                "points": points,
            },
        })
    return [{
        "data": {"image": image_uri},
        "predictions": [{"model_version": "SAM3", "result": results}],
    }]


## RAY Actor
@ray.remote(num_gpus=1) # 1 Seul GPU car nous sommes en solo
class SAM3Worker:
    def __init__(self, tile_size=1008, tile_stride=768):
        # charger le modèle SAM3 une fois
        # initialiser self.model, self.transform, self.postprocessor

    def process(self, image):
        # 1. extraire les patches avec getPatches()
        # 2. passer chaque patch à SAM3
        # 3. merger les masques avec mergeMasks()
        # 4. convertir en polygones avec maskToPolygon()
        # 5. retourner liste de (label, points, score)

# Main
def main():
    s3Bucket = args.bucket
    imageURI = args.imageUri
    labels = args.labels
    tileSize = args.tileSize
    tileStride = args.tileStide

    picture = getImage(s3Bucket, imageURI)


if __name__ == "__main__":
    main()
