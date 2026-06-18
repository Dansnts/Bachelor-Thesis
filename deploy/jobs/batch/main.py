"""Pipeline batch distribué : workers Ray + I/O MinIO + sortie Parquet.

Le driver se connecte au RayCluster, liste les images d'un préfixe S3 et les
distribue sur num_workers acteurs GPU. Chaque worker charge SAM3 une fois (via
Sam3Model), traite ses images, extrait le GPS de l'EXIF et écrit les polygones
en Parquet sur MinIO.

Schéma Parquet : image_key, acquisition_id, label, score, points,
                 original_width, original_height, latitude, longitude

Usage :
    # sur le cluster (se connecte au head du RayCluster)
    python3.12 main.py \
        --s3_uri s3://nearai/data/acquisitions/Samples/01_images/ \
        --s3_output_uri s3://nearai/data/acquisitions/Samples/09_parquet/ \
        --labels sign,road_marking \
        --num_workers 2

    # test local (un seul GPU, sans cluster)
    python3.12 main.py --local --s3_uri ... --s3_output_uri ... --labels sign
"""

import argparse
import io
import json
import logging
import time
from pathlib import Path

import ray
from PIL import Image

from jobCore.s3 import make_s3_client
from jobCore.worker import DEFAULT_BATCH_SIZE, DEFAULT_TILE_SIZE, DEFAULT_TILE_STRIDE, Sam3Model

RAY_HEAD = "ray://ray-cluster-head-svc:10001"
SUPPORTED_EXT = {".jpg", ".jpeg", ".png", ".tiff", ".tif"}

log = logging.getLogger(__name__)


# ── S3 / EXIF ───────────────────────────────────────────────────────────────


def listImages(client, bucket, prefix):
    keys = []
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if Path(key).suffix.lower() in SUPPORTED_EXT:
                keys.append(key)
    return sorted(keys)


def alreadyProcessed(client, bucket, prefix):
    done = set()
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".parquet"):
                done.add(Path(key).stem)
    return done


def dmsToDecimal(dms, ref):
    d, m, s = dms
    decimal = d + m / 60 + s / 3600
    return -decimal if ref in ("S", "W") else decimal


def downloadImage(client, bucket, key):
    resp = client.get_object(Bucket=bucket, Key=key)
    raw = resp["Body"].read()
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    lat, lon = None, None
    try:
        from exif import Image as ExifImage

        exif = ExifImage(raw)
        if exif.has_exif:
            lat = dmsToDecimal(exif.gps_latitude, exif.gps_latitude_ref)
            lon = dmsToDecimal(exif.gps_longitude, exif.gps_longitude_ref)
    except Exception:
        pass
    return img, lat, lon


def uploadParquet(client, bucket, key, rows):
    import pyarrow as pa
    import pyarrow.parquet as pq

    schema = pa.schema(
        [
            ("image_key", pa.string()),
            ("acquisition_id", pa.string()),
            ("label", pa.string()),
            ("score", pa.float32()),
            ("points", pa.string()),
            ("original_width", pa.int32()),
            ("original_height", pa.int32()),
            ("latitude", pa.float64()),
            ("longitude", pa.float64()),
        ]
    )
    table = pa.table(
        {col: [r[col] for r in rows] for col in schema.names},
        schema=schema,
    )
    buf = io.BytesIO()
    pq.write_table(table, buf, compression="snappy")
    buf.seek(0)
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=buf.getvalue(),
        ContentType="application/octet-stream",
    )


def getAcquisitionId(key):
    parts = Path(key).parts
    try:
        idx = list(parts).index("acquisitions")
        return parts[idx + 1]
    except (ValueError, IndexError):
        return Path(key).parent.parent.name


# ── RAY ACTOR ─────────────────────────────────────────────────────────────────


@ray.remote(num_gpus=1)
class SAM3Worker:
    def __init__(self, batch_size=DEFAULT_BATCH_SIZE, tile_size=DEFAULT_TILE_SIZE, tile_stride=DEFAULT_TILE_STRIDE):
        self.model = Sam3Model(
            tile_size=tile_size, tile_stride=tile_stride, batch_size=batch_size
        )
        self.s3 = make_s3_client()
        logging.basicConfig(level=logging.INFO)
        self.log = logging.getLogger(__name__)

    def process(self, bucket, key, out_bucket, out_prefix, labels):
        t0 = time.time()
        image, lat, lon = downloadImage(self.s3, bucket, key)
        polygons, w, h = self.model.infer(image, labels)
        acq_id = getAcquisitionId(key)

        rows = []
        for label, points, score in polygons:
            rows.append(
                {
                    "image_key": key,
                    "acquisition_id": acq_id,
                    "label": label,
                    "score": float(score),
                    "points": json.dumps(points),
                    "original_width": w,
                    "original_height": h,
                    "latitude": lat,
                    "longitude": lon,
                }
            )

        stem = Path(key).stem
        rel = str(Path(key).parent).lstrip("/")
        out_key = (
            f"{out_prefix.rstrip('/')}/{rel}/{stem}.parquet"
            if rel
            else f"{out_prefix.rstrip('/')}/{stem}.parquet"
        )
        uploadParquet(self.s3, out_bucket, out_key, rows)

        elapsed = time.time() - t0
        self.log.info("%s → %d détections en %.1fs", Path(key).name, len(rows), elapsed)
        return {"key": key, "detections": len(rows), "time": elapsed}


# ── MAIN ──────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--s3_uri", required=True, help="s3://bucket/prefix/")
    parser.add_argument("--s3_output_uri", required=True, help="s3://bucket/prefix/")
    parser.add_argument("--labels", required=True, help="labels séparés par des virgules")
    parser.add_argument("--batch_size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--num_workers", type=int, default=2)
    parser.add_argument("--tile_size", type=int, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--tile_stride", type=int, default=DEFAULT_TILE_STRIDE)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--local", action="store_true", help="ray.init() sans cluster")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    labels = [l.strip() for l in args.labels.split(",") if l.strip()]
    in_bucket, in_prefix = args.s3_uri[5:].split("/", 1)
    out_bucket, out_prefix = args.s3_output_uri[5:].split("/", 1)

    ray.init() if args.local else ray.init(RAY_HEAD)
    log.info("Ray : %d nœud(s)", len(ray.nodes()))

    client = make_s3_client()
    keys = listImages(client, in_bucket, in_prefix)

    if args.resume:
        done = alreadyProcessed(client, out_bucket, out_prefix)
        keys = [k for k in keys if Path(k).stem not in done]
        log.info("Resume : %d images restantes", len(keys))
    else:
        log.info("Traitement de %d images", len(keys))

    if not keys:
        ray.shutdown()
        return

    n = args.num_workers
    workers = [
        SAM3Worker.remote(
            batch_size=args.batch_size,
            tile_size=args.tile_size,
            tile_stride=args.tile_stride,
        )
        for _ in range(n)
    ]

    # dispatch round-robin : image i → worker (i mod n)
    futures = [
        workers[i % n].process.remote(in_bucket, key, out_bucket, out_prefix, labels)
        for i, key in enumerate(keys)
    ]

    t_wall = time.time()
    total_detections = 0
    sum_worker_time = 0.0
    nb_images = len(keys)
    for result in ray.get(futures):
        total_detections += result["detections"]
        sum_worker_time += result["time"]
    t_wall = time.time() - t_wall

    avg_wall = t_wall / nb_images if nb_images else 0
    avg_worker = sum_worker_time / nb_images if nb_images else 0
    log.info(
        "Terminé : %d images, %d détections\n"
        "  Wall time  : %.0fs (%.1fs/image)\n"
        "  Moy worker : %.1fs/image (somme sur les workers)",
        nb_images,
        total_detections,
        t_wall,
        avg_wall,
        avg_worker,
    )
    ray.shutdown()


if __name__ == "__main__":
    main()
