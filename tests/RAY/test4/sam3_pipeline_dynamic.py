# AI assistance
"""
SAM3 pipeline with dynamic work queue via ray.wait().

Difference vs sam3_minio_pipeline.py:
- Round-robin assigns work upfront → slow image blocks a worker slot.
- Here: workers pull next image as soon as they finish, no idle waiting.

Usage:
    python sam3_pipeline_dynamic.py \
        --s3_uri s3://nearai/data/acquisitions/Samples/01_images/ \
        --s3_output_uri s3://nearai/dani/test4/parquet/ \
        --labels sign,road_marking \
        --num_workers 2

    python sam3_pipeline_dynamic.py --local \
        --s3_uri s3://nearai/data/acquisitions/Samples/01_images/ \
        --s3_output_uri s3://nearai/dani/test4/parquet/ \
        --labels sign \
        --num_workers 1
"""

import os
import sys
import io
import json
import time
import logging
import argparse
from pathlib import Path
from typing import List, Tuple

import ray
import torch
import numpy as np
from PIL import Image

SAM3_CODEBASE = os.getenv("SAM3_CODEBASE", "/app/sam3")
if SAM3_CODEBASE not in sys.path:
    sys.path.append(SAM3_CODEBASE)

RAY_HEAD       = "ray://ray-cluster-head-svc:10001"
PATCH_SIZE     = 1008
PATCH_STRIDE   = 768
CONF_THRESHOLD = 0.5
SUPPORTED_EXT  = {'.jpg', '.jpeg', '.png', '.tiff', '.tif'}

log = logging.getLogger(__name__)


# ── S3 ────────────────────────────────────────────────────────────────────────

def make_s3_client():
    import boto3
    from botocore.config import Config
    return boto3.session.Session().client(
        's3',
        endpoint_url=os.getenv('S3_ENDPOINT_URL'),
        aws_access_key_id=os.getenv('AWS_ACCESS_KEY_ID'),
        aws_secret_access_key=os.getenv('AWS_SECRET_ACCESS_KEY'),
        region_name='us-east-1',
        verify=False,
        config=Config(retries={'max_attempts': 3, 'mode': 'standard'}),
    )


def list_images(client, bucket: str, prefix: str) -> List[str]:
    keys = []
    paginator = client.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            key = obj['Key']
            if Path(key).suffix.lower() in SUPPORTED_EXT:
                keys.append(key)
    return sorted(keys)


def already_processed(client, bucket: str, prefix: str) -> set:
    done = set()
    paginator = client.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            key = obj['Key']
            if key.endswith('.parquet'):
                done.add(Path(key).stem)
    return done


def _dms_to_decimal(dms, ref: str) -> float:
    d, m, s = dms
    decimal = d + m / 60 + s / 3600
    return -decimal if ref in ('S', 'W') else decimal


def download_image(client, bucket: str, key: str) -> Tuple[Image.Image, float, float]:
    resp = client.get_object(Bucket=bucket, Key=key)
    raw = resp['Body'].read()
    img = Image.open(io.BytesIO(raw)).convert('RGB')
    lat, lon = None, None
    try:
        from exif import Image as ExifImage
        exif = ExifImage(raw)
        if exif.has_exif:
            lat = _dms_to_decimal(exif.gps_latitude, exif.gps_latitude_ref)
            lon = _dms_to_decimal(exif.gps_longitude, exif.gps_longitude_ref)
    except Exception:
        pass
    return img, lat, lon


def upload_parquet(client, bucket: str, key: str, rows: list):
    import pyarrow as pa
    import pyarrow.parquet as pq
    schema = pa.schema([
        ('image_key',       pa.string()),
        ('acquisition_id',  pa.string()),
        ('label',           pa.string()),
        ('score',           pa.float32()),
        ('points',          pa.string()),
        ('original_width',  pa.int32()),
        ('original_height', pa.int32()),
        ('latitude',        pa.float64()),
        ('longitude',       pa.float64()),
    ])
    table = pa.table(
        {col: [r[col] for r in rows] for col in schema.names},
        schema=schema,
    )
    buf = io.BytesIO()
    pq.write_table(table, buf, compression='snappy')
    buf.seek(0)
    client.put_object(Bucket=bucket, Key=key, Body=buf.getvalue(),
                      ContentType='application/octet-stream')


def get_acquisition_id(key: str) -> str:
    parts = Path(key).parts
    try:
        idx = list(parts).index('acquisitions')
        return parts[idx + 1]
    except (ValueError, IndexError):
        return Path(key).parent.parent.name


# ── SLIDING WINDOW ────────────────────────────────────────────────────────────

def get_patch_positions(img_w: int, img_h: int) -> List[Tuple[int, int, int, int]]:
    def positions_1d(size: int) -> List[int]:
        pos = []
        x = 0
        while x + PATCH_SIZE < size:
            pos.append(x)
            x += PATCH_STRIDE
        pos.append(size - PATCH_SIZE if size > PATCH_SIZE else 0)
        return pos
    positions = []
    for y in positions_1d(img_h):
        for x in positions_1d(img_w):
            w = min(PATCH_SIZE, img_w - x)
            h = min(PATCH_SIZE, img_h - y)
            positions.append((x, y, w, h))
    return positions


def extract_patches(image: Image.Image) -> List[Tuple[Image.Image, Tuple[int, int, int, int]]]:
    img_w, img_h = image.size
    patches = []
    for (x, y, w, h) in get_patch_positions(img_w, img_h):
        patch = image.crop((x, y, x + w, y + h))
        if w < PATCH_SIZE or h < PATCH_SIZE:
            padded = Image.new('RGB', (PATCH_SIZE, PATCH_SIZE), (0, 0, 0))
            padded.paste(patch, (0, 0))
            patch = padded
        patches.append((patch, (x, y, w, h)))
    return patches


# ── MASK POST-PROCESSING ──────────────────────────────────────────────────────

def merge_masks(masks, coords_list, img_w, img_h, scores):
    from scipy import ndimage
    full = np.zeros((img_h, img_w), dtype=np.uint8)
    placed = []
    for mask, (x, y, w, h) in zip(masks, coords_list):
        mask = mask.squeeze()
        if mask.shape != (h, w):
            mask = np.array(Image.fromarray((mask * 255).astype(np.uint8)).resize((w, h), Image.NEAREST)) > 127
            mask = mask.astype(np.uint8)
        full[y:y+h, x:x+w] = np.maximum(full[y:y+h, x:x+w], mask)
        placed.append((mask, (x, y, w, h)))
    labeled, n = ndimage.label(full)
    results = []
    for i in range(1, n + 1):
        comp = (labeled == i).astype(np.uint8)
        if comp.sum() < 100:
            continue
        total_w, weighted_s = 0.0, 0.0
        for (pm, (x, y, w, h)), s in zip(placed, scores):
            overlap = np.sum(pm * comp[y:y+h, x:x+w])
            if overlap > 0:
                weighted_s += s * overlap
                total_w += overlap
        score = weighted_s / total_w if total_w > 0 else 0.0
        results.append((comp, score))
    return results


def mask_to_polygon(mask: np.ndarray, w: int, h: int) -> List[List[float]]:
    import cv2
    contours, _ = cv2.findContours((mask > 0).astype(np.uint8) * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return []
    contour = max(contours, key=cv2.contourArea)
    epsilon = 0.002 * cv2.arcLength(contour, True)
    simplified = cv2.approxPolyDP(contour, epsilon, True)
    if len(simplified) < 3:
        return []
    return [[p[0][0] * 100.0 / w, p[0][1] * 100.0 / h] for p in simplified]


# ── RAY ACTOR ─────────────────────────────────────────────────────────────────

@ray.remote(num_gpus=1)
class SAM3Worker:
    def __init__(self, batch_size: int = 4):
        from huggingface_hub import login
        from sam3 import build_sam3_image_model
        from sam3.train.transforms.basic_for_api import ComposeAPI, ToTensorAPI, NormalizeAPI
        from sam3.eval.postprocessors import PostProcessImage

        hf_token = os.environ.get("HF_TOKEN")
        if hf_token:
            login(token=hf_token)

        self.device = 'cuda' if torch.cuda.is_available() else 'cpu'
        self.batch_size = batch_size
        self._counter = 1

        self.model = build_sam3_image_model(
            device=self.device,
            eval_mode=True,
            load_from_HF=True,
            enable_segmentation=True,
            enable_inst_interactivity=True,
        )
        self.transform = ComposeAPI(transforms=[
            ToTensorAPI(),
            NormalizeAPI(mean=[0.5, 0.5, 0.5], std=[0.5, 0.5, 0.5]),
        ])
        self.postprocessor = PostProcessImage(
            max_dets_per_img=-1,
            iou_type="segm",
            use_original_sizes_box=True,
            use_original_sizes_mask=True,
            convert_mask_to_rle=False,
            detection_threshold=CONF_THRESHOLD,
            to_cpu=True,
        )
        self.s3 = make_s3_client()
        logging.basicConfig(level=logging.INFO)
        self.log = logging.getLogger(__name__)
        self.log.info(f"SAM3Worker ready on {self.device}")

    def _make_datapoint(self, patch_img: Image.Image, labels: List[str]):
        from sam3.train.data.sam3_image_dataset import (
            InferenceMetadata, FindQueryLoaded, Image as SAMImage, Datapoint
        )
        pw, ph = patch_img.size
        dp = Datapoint(find_queries=[], images=[
            SAMImage(data=patch_img, objects=[], size=[ph, pw])
        ])
        query_id_to_label = {}
        for label in labels:
            dp.find_queries.append(FindQueryLoaded(
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
                )
            ))
            query_id_to_label[self._counter] = label
            self._counter += 1
        return self.transform(dp), query_id_to_label

    def process(self, bucket: str, key: str, out_bucket: str, out_prefix: str, labels: List[str]) -> dict:
        from sam3.train.data.collator import collate_fn_api as collate
        from sam3.model.utils.misc import copy_data_to_device

        t0 = time.time()
        t_download = time.time()
        image, lat, lon = download_image(self.s3, bucket, key)
        t_download = time.time() - t_download

        w, h = image.size
        acq_id = get_acquisition_id(key)
        patches = extract_patches(image)

        patch_data = []
        for patch_img, coords in patches:
            dp, qmap = self._make_datapoint(patch_img, labels)
            patch_data.append((dp, coords, qmap))

        t_inference = time.time()
        all_detections = []
        for i in range(0, len(patch_data), self.batch_size):
            batch  = patch_data[i:i + self.batch_size]
            dps    = [x[0] for x in batch]
            coords = [x[1] for x in batch]
            qmaps  = [x[2] for x in batch]

            b = collate(dps, dict_key="dummy")["dummy"]
            b = copy_data_to_device(b, torch.device(self.device), non_blocking=True)

            with torch.inference_mode():
                with torch.autocast(device_type='cuda' if 'cuda' in self.device else 'cpu', dtype=torch.bfloat16):
                    output = self.model(b)

            results = self.postprocessor.process_results(output, b.find_metadatas)

            for c, qmap in zip(coords, qmaps):
                for qid, label in qmap.items():
                    if qid not in results:
                        continue
                    for mask, score in zip(results[qid].get('masks', []), results[qid].get('scores', [])):
                        s = float(score.float().cpu().numpy())
                        if s >= CONF_THRESHOLD:
                            m = (mask.float().cpu().numpy().squeeze() > 0.5).astype(np.uint8)
                            all_detections.append((m, c, s, label))
        t_inference = time.time() - t_inference

        label_groups = {}
        for mask, coords, score, label in all_detections:
            g = label_groups.setdefault(label, {'masks': [], 'coords': [], 'scores': []})
            g['masks'].append(mask)
            g['coords'].append(coords)
            g['scores'].append(score)

        rows = []
        for label, g in label_groups.items():
            for mask, score in merge_masks(g['masks'], g['coords'], w, h, g['scores']):
                points = mask_to_polygon(mask, w, h)
                if points:
                    rows.append({
                        'image_key':       key,
                        'acquisition_id':  acq_id,
                        'label':           label,
                        'score':           float(score),
                        'points':          json.dumps(points),
                        'original_width':  w,
                        'original_height': h,
                        'latitude':        lat,
                        'longitude':       lon,
                    })

        t_upload = time.time()
        stem = Path(key).stem
        rel = str(Path(key).parent).lstrip('/')
        out_key = f"{out_prefix.rstrip('/')}/{rel}/{stem}.parquet" if rel else f"{out_prefix.rstrip('/')}/{stem}.parquet"
        upload_parquet(self.s3, out_bucket, out_key, rows)
        t_upload = time.time() - t_upload

        elapsed = time.time() - t0
        self.log.info(
            f"{Path(key).name} | patches={len(patches)} detections={len(rows)} "
            f"total={elapsed:.1f}s [download={t_download:.1f}s inference={t_inference:.1f}s upload={t_upload:.1f}s]"
        )
        return {
            'key':        key,
            'detections': len(rows),
            'time':       elapsed,
            't_download': t_download,
            't_inference': t_inference,
            't_upload':   t_upload,
        }


# ── DYNAMIC WORK QUEUE ────────────────────────────────────────────────────────

def run_dynamic(workers, keys, in_bucket, out_bucket, out_prefix, labels):
    """
    Each worker gets 1 task at a time. As soon as it finishes it picks the next
    key from the queue. No idle waiting caused by uneven image processing times.
    """
    queue = list(keys)
    # future → worker_index
    future_to_worker = {}

    # seed: one task per worker
    for i, worker in enumerate(workers):
        if not queue:
            break
        key = queue.pop(0)
        fut = worker.process.remote(in_bucket, key, out_bucket, out_prefix, labels)
        future_to_worker[fut] = i

    results = []
    while future_to_worker:
        done, _ = ray.wait(list(future_to_worker.keys()), num_returns=1)
        fut = done[0]
        worker_idx = future_to_worker.pop(fut)
        result = ray.get(fut)
        results.append(result)
        log.info(
            f"[worker {worker_idx}] {Path(result['key']).name} done "
            f"({result['detections']} det, {result['time']:.1f}s) "
            f"— {len(results)}/{len(keys)}"
        )
        # assign next image to the now-free worker
        if queue:
            key = queue.pop(0)
            fut = workers[worker_idx].process.remote(in_bucket, key, out_bucket, out_prefix, labels)
            future_to_worker[fut] = worker_idx

    return results


# ── MAIN ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--s3_uri',        required=True)
    parser.add_argument('--s3_output_uri', required=True)
    parser.add_argument('--labels',        required=True)
    parser.add_argument('--batch_size',    type=int, default=4)
    parser.add_argument('--num_workers',   type=int, default=2)
    parser.add_argument('--resume',        action='store_true')
    parser.add_argument('--local',         action='store_true')
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

    labels     = [l.strip() for l in args.labels.split(',') if l.strip()]
    in_bucket,  in_prefix  = args.s3_uri[5:].split('/', 1)
    out_bucket, out_prefix = args.s3_output_uri[5:].split('/', 1)

    ray.init() if args.local else ray.init(RAY_HEAD)
    log.info(f"Ray: {len(ray.nodes())} node(s)")

    client = make_s3_client()
    keys = list_images(client, in_bucket, in_prefix)

    if args.resume:
        done = already_processed(client, out_bucket, out_prefix)
        keys = [k for k in keys if Path(k).stem not in done]
        log.info(f"Resume: {len(keys)} images pending")
    else:
        log.info(f"Processing {len(keys)} images")

    if not keys:
        ray.shutdown()
        return

    workers = [SAM3Worker.remote(batch_size=args.batch_size) for _ in range(args.num_workers)]

    t_wall = time.time()
    results = run_dynamic(workers, keys, in_bucket, out_bucket, out_prefix, labels)
    t_wall = time.time() - t_wall

    total_det  = sum(r['detections']  for r in results)
    avg_total  = sum(r['time']        for r in results) / len(results)
    avg_dl     = sum(r['t_download']  for r in results) / len(results)
    avg_inf    = sum(r['t_inference'] for r in results) / len(results)
    avg_up     = sum(r['t_upload']    for r in results) / len(results)

    log.info(
        f"\n── Results ──────────────────────────────\n"
        f"  Images     : {len(keys)}\n"
        f"  Detections : {total_det}\n"
        f"  Wall time  : {t_wall:.0f}s\n"
        f"  Avg/image  : {avg_total:.1f}s  "
        f"[download={avg_dl:.1f}s  inference={avg_inf:.1f}s  upload={avg_up:.1f}s]\n"
        f"─────────────────────────────────────────"
    )
    ray.shutdown()


if __name__ == '__main__':
    main()
