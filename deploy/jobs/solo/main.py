import argparse
import io
import json
import logging
import os

import numpy as np
import ray
import torch
from dotenv import load_dotenv
from PIL import Image

load_dotenv()

log = logging.getLogger(__name__)

CONF_THRESHOLD = 0.5
DEFAULT_TILE_SIZE = 1008
DEFAULT_TILE_STRIDE = 768
DEFAULT_BATCH_SIZE = 4


# S3
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


def getImage(bucket, imageURL):
    picture = s3Client().get_object(Bucket=bucket, Key=imageURL)
    return picture["Body"].read()


# Tiles
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


# Post processing
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
        results.append(
            {
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
            }
        )
    return [
        {
            "data": {"image": image_uri},
            "predictions": [{"model_version": "SAM3", "result": results}],
        }
    ]


# RAY Actor
@ray.remote(num_gpus=1)  # 1 seul GPU car nous sommes en solo
class SAM3Worker:
    def __init__(
        self,
        tile_size=DEFAULT_TILE_SIZE,
        tile_stride=DEFAULT_TILE_STRIDE,
        batch_size=DEFAULT_BATCH_SIZE,
    ):
        from huggingface_hub import login
        from sam3 import build_sam3_image_model
        from sam3.eval.postprocessors import PostProcessImage
        from sam3.train.transforms.basic_for_api import (
            ComposeAPI,
            NormalizeAPI,
            ToTensorAPI,
        )

        logging.basicConfig(level=logging.INFO)

        # charger le modèle SAM3 une fois
        hf_token = os.getenv("HF_TOKEN")
        if hf_token:
            login(token=hf_token)

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.tile_size = tile_size
        self.tile_stride = tile_stride
        self.batch_size = batch_size
        self._counter = 1

        self.model = build_sam3_image_model(
            device=self.device,
            eval_mode=True,  # mode inférence
            load_from_HF=True,
            enable_segmentation=True,
            enable_inst_interactivity=True,
        )

        self.transform = ComposeAPI(
            transforms=[
                ToTensorAPI(),
                NormalizeAPI(mean=[0.5, 0.5, 0.5], std=[0.5, 0.5, 0.5]),
            ]
        )

        self.postprocessor = PostProcessImage(
            max_dets_per_img=-1,
            iou_type="segm",
            use_original_sizes_box=True,
            use_original_sizes_mask=True,
            convert_mask_to_rle=False,
            detection_threshold=CONF_THRESHOLD,
            to_cpu=True,
        )
        log.info("SAM3Worker prêt sur %s", self.device)

    def _make_datapoint(self, patch_image, labels):
        from sam3.train.data.sam3_image_dataset import (
            Datapoint,
            FindQueryLoaded,
            InferenceMetadata,
        )
        from sam3.train.data.sam3_image_dataset import Image as SAMImage

        pw, ph = patch_image.size
        dp = Datapoint(
            find_queries=[],
            images=[SAMImage(data=patch_image, objects=[], size=[ph, pw])],
        )
        query_id_to_label = {}
        for label in labels:
            dp.find_queries.append(
                FindQueryLoaded(
                    query_text=label,
                    image_id=0,
                    object_ids_output=[],
                    is_exhaustive=True,
                    query_processing_order=0,
                    inference_metadata=InferenceMetadata(
                        coco_image_id=self._counter,
                        original_image_id=self._counter,
                        original_category_id=1,
                        original_size=[pw, ph],
                        object_id=0,
                        frame_index=0,
                    ),
                )
            )
            query_id_to_label[self._counter] = label
            self._counter += 1
        return self.transform(dp), query_id_to_label

    def process(self, image_bytes, labels):
        from sam3.model.utils.misc import copy_data_to_device
        from sam3.train.data.collator import collate_fn_api as collate

        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        image_width, image_height = image.size

        # 1. extraire les patches
        patches = getPatches(image, self.tile_size, self.tile_stride)

        # 2. emballer chaque patch en Datapoint (image + labels)
        patch_data = []
        for patch_image, coordinates in patches:
            dp, query_id = self._make_datapoint(patch_image, labels)
            patch_data.append((dp, coordinates, query_id))

        # 3. inférence batchée → liste de (mask, coords, score, label)
        detections = []
        for i in range(0, len(patch_data), self.batch_size):
            batch = patch_data[i : i + self.batch_size]
            dps = [x[0] for x in batch]
            coords_list = [x[1] for x in batch]
            qmaps = [x[2] for x in batch]

            b = collate(dps, dict_key="dummy")["dummy"]
            b = copy_data_to_device(b, torch.device(self.device), non_blocking=True)

            with torch.inference_mode():
                with torch.autocast(device_type="cuda", dtype=torch.bfloat16):
                    output = self.model(b)

            results = self.postprocessor.process_results(output, b.find_metadatas)

            for coordinates, qmap in zip(coords_list, qmaps):
                for query_id, label in qmap.items():
                    if query_id not in results:
                        continue
                    for mask, score in zip(
                        results[query_id].get("masks", []),
                        results[query_id].get("scores", []),
                    ):
                        s = float(score.float().cpu().numpy())
                        if s >= CONF_THRESHOLD:
                            m = (mask.float().cpu().numpy().squeeze() > 0.5).astype(
                                np.uint8
                            )
                            detections.append((m, coordinates, s, label))

        # 4. regrouper par label puis recoller les patches avec mergeMasks()
        label_groups = {}
        for mask, coordinates, score, label in detections:
            g = label_groups.setdefault(
                label, {"masks": [], "coords": [], "scores": []}
            )
            g["masks"].append(mask)
            g["coords"].append(coordinates)
            g["scores"].append(score)

        # 5. convertir chaque masque fusionné en polygone → (label, points, score)
        polygons = []
        for label, g in label_groups.items():
            for mask, score in mergeMasks(
                g["masks"], g["coords"], image_width, image_height, g["scores"]
            ):
                points = maskToPolygon(mask, image_width, image_height)
                if points:
                    polygons.append((label, points, float(score)))

        log.info("%d objets détectés sur %d patches", len(polygons), len(patches))
        return polygons, image_width, image_height


# Main
def main():
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )

    parser = argparse.ArgumentParser()
    parser.add_argument("--imageUri", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--labels", nargs="+", required=True)
    parser.add_argument("--tileSize", type=int, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--tileStride", type=int, default=DEFAULT_TILE_STRIDE)
    parser.add_argument("--resultKey", default=None)
    args = parser.parse_args()

    log.info("Téléchargement de %s depuis le bucket %s", args.imageUri, args.bucket)
    picture = getImage(args.bucket, args.imageUri)

    ray.init()
    try:
        worker = SAM3Worker.remote(
            tile_size=args.tileSize, tile_stride=args.tileStride
        )
        polygons, width, height = ray.get(
            worker.process.remote(picture, args.labels)
        )
    finally:
        ray.shutdown()

    body = json.dumps(toLabelStudio(args.imageUri, polygons, width, height))
    print(body)

    if args.resultKey:
        s3Client().put_object(
            Bucket=args.bucket,
            Key=args.resultKey,
            Body=body.encode("utf-8"),
            ContentType="application/json",
        )
        log.info("Résultat écrit sur s3://%s/%s", args.bucket, args.resultKey)


if __name__ == "__main__":
    main()
