"""Distributed batch pipeline: Ray workers + MinIO I/O + Parquet output.

The driver connects to the RayCluster, lists the images of an S3 prefix and
distributes them across num_workers GPU actors. Each worker loads SAM3 once (via
Sam3Model), processes its images, extracts GPS from EXIF and writes the polygons
as Parquet on MinIO.

Parquet schema: image_key, acquisition_id, label, score, points,
                original_width, original_height, latitude, longitude

Usage:
    # on the cluster (connects to the RayCluster head)
    python3.12 main.py \
        --s3_uri s3://nearai/data/acquisitions/Samples/01_images/ \
        --s3_output_uri s3://nearai/data/acquisitions/Samples/09_parquet/ \
        --labels sign,road_marking \
        --num_workers 2

    # local test (single GPU, no cluster)
    python3.12 main.py --local --s3_uri ... --s3_output_uri ... --labels sign
"""

import argparse
import io
import json
import logging
import time
from datetime import datetime, timezone
from pathlib import Path

import ray
from PIL import Image

from jobCore.s3 import make_s3_client
from jobCore.worker import DEFAULT_BATCH_SIZE, DEFAULT_DOWNSAMPLE, DEFAULT_TILE_SIZE, DEFAULT_TILE_STRIDE, Sam3Model

# Variables --------------------------------------------------
RAY_HEAD = "ray://ray-cluster-head-svc:10001"
SUPPORTED_EXT = {".jpg", ".jpeg", ".png", ".tiff", ".tif"}


# Logging --------------------------------------------------
log = logging.getLogger(__name__)


# S3 / EXIF --------------------------------------------------


def list_images(client, bucket, prefix):
    keys = []
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if Path(key).suffix.lower() in SUPPORTED_EXT:
                keys.append(key)
    return sorted(keys)


def already_processed(client, bucket, prefix):
    done = set()
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".parquet"):
                done.add(Path(key).stem)
    return done


def dms_to_decimal(dms, ref):
    d, m, s = dms
    decimal = d + m / 60 + s / 3600
    return -decimal if ref in ("S", "W") else decimal


def download_image(client, bucket, key):
    resp = client.get_object(Bucket=bucket, Key=key)
    raw = resp["Body"].read()
    img = Image.open(io.BytesIO(raw)).convert("RGB")

    lat, lon = None, None
    # dataset metadata propagated to the run summary. Resolution comes from the
    # decoded image (not always in EXIF); the rest comes from EXIF when present.
    meta = {
        "make": None,
        "model": None,
        "software": None,
        "img_direction": None,
        "width": img.size[0],
        "height": img.size[1],
    }
    try:
        from exif import Image as ExifImage

        exif = ExifImage(raw)
        if exif.has_exif:
            # get() returns None when the field is absent, so a camera that does
            # not record a value simply leaves it empty in the summary
            meta["make"] = exif.get("make")
            meta["model"] = exif.get("model")
            meta["software"] = exif.get("software")
            meta["img_direction"] = exif.get("gps_img_direction")
            # GPS coordinates, only if the device recorded them
            if exif.get("gps_latitude") and exif.get("gps_longitude"):
                lat = dms_to_decimal(exif.gps_latitude, exif.gps_latitude_ref)
                lon = dms_to_decimal(exif.gps_longitude, exif.gps_longitude_ref)
    except Exception:
        pass
    return img, lat, lon, meta


def upload_parquet(client, bucket, key, rows):
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


def write_dataset_info(client, bucket, prefix, labels, info):
    # Human-readable summary of the dataset, written once at the root of the
    # results. "info" is filled by the driver as images come back from the
    # workers (camera models, resolutions, GPS coverage, camera direction).
    cameras = sorted(c for c in info["cameras"] if c)
    softwares = sorted(s for s in info["softwares"] if s)
    resolutions = sorted("%dx%d" % (w, h) for (w, h) in info["resolutions"])

    if info["directions"]:
        lo = min(info["directions"])
        hi = max(info["directions"])
        direction_line = "available on %d images (%.1f to %.1f)" % (
            len(info["directions"]), lo, hi
        )
    else:
        direction_line = "not provided by the device"

    lines = []
    lines.append("Dataset analysis summary")
    lines.append("========================")
    lines.append("Generated (UTC) : %s" % datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"))
    lines.append("Images processed : %d" % info["images"])
    lines.append("Labels           : %s" % ", ".join(labels))
    lines.append("")
    lines.append("Camera(s)        : %s" % (", ".join(cameras) if cameras else "unknown"))
    lines.append("Software         : %s" % (", ".join(softwares) if softwares else "unknown"))
    lines.append("Resolution(s)    : %s" % (", ".join(resolutions) if resolutions else "unknown"))
    lines.append("GPS available    : %d/%d images" % (info["gps_count"], info["images"]))
    lines.append("Camera direction : %s" % direction_line)
    body = "\n".join(lines) + "\n"

    key = "%s/dataset_info.txt" % prefix.rstrip("/")
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="text/plain",
    )


def write_status(client, bucket, key, processed, total, started_at, done=False):
    # Small progress file read back by the API on /jobs/{name}/status.
    # Rewritten at every percent step during the run.
    # We store started_at (epoch) rather than the elapsed time: the API
    # recomputes elapsed_seconds on each read, so the time keeps moving even
    # between steps. On the final write (done=True) we freeze elapsed_seconds.
    percent = int(processed * 100 / total) if total else 0
    body = {
        "total": total,
        "processed": processed,
        "percent": percent,
        "started_at": started_at,
        "done": done,
    }
    if done:
        body["elapsed_seconds"] = round(time.time() - started_at, 1)
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(body).encode(),
        ContentType="application/json",
    )


def get_acquisition_id(key):
    parts = Path(key).parts
    try:
        idx = list(parts).index("acquisitions")
        return parts[idx + 1]
    except (ValueError, IndexError):
        return Path(key).parent.parent.name


# Ray actor --------------------------------------------------


@ray.remote(num_gpus=1)
class SAM3Worker:
    def __init__(self, batch_size=DEFAULT_BATCH_SIZE, tile_size=DEFAULT_TILE_SIZE, tile_stride=DEFAULT_TILE_STRIDE, downsample=DEFAULT_DOWNSAMPLE):
        self.model = Sam3Model(
            tile_size=tile_size, tile_stride=tile_stride, batch_size=batch_size, downsample=downsample
        )
        self.s3 = make_s3_client()
        logging.basicConfig(level=logging.INFO)
        self.log = logging.getLogger(__name__)

    def process(self, bucket, key, out_bucket, out_prefix, labels):
        t0 = time.time()
        image, lat, lon, meta = download_image(self.s3, bucket, key)
        polygons, w, h = self.model.infer(image, labels)
        acq_id = get_acquisition_id(key)

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
        upload_parquet(self.s3, out_bucket, out_key, rows)

        elapsed = time.time() - t0
        self.log.info("%s -> %d detections in %.1fs", Path(key).name, len(rows), elapsed)
        return {
            "key": key,
            "detections": len(rows),
            "time": elapsed,
            "has_gps": lat is not None,
            "meta": meta,
        }


# Main --------------------------------------------------


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--s3_uri", required=True, help="s3://bucket/prefix/")
    parser.add_argument("--s3_output_uri", required=True, help="s3://bucket/prefix/")
    parser.add_argument("--labels", required=True, help="comma-separated labels")
    parser.add_argument("--batch_size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--num_workers", type=int, default=2)
    parser.add_argument("--tile_size", type=int, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--tile_stride", type=int, default=DEFAULT_TILE_STRIDE)
    parser.add_argument("--downsample", type=float, default=DEFAULT_DOWNSAMPLE)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--local", action="store_true", help="ray.init() without cluster")
    parser.add_argument(
        "--status_uri",
        default=None,
        help="s3://bucket/key where progress is written (read back by the API)",
    )
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    labels = [l.strip() for l in args.labels.split(",") if l.strip()]
    in_bucket, in_prefix = args.s3_uri[5:].split("/", 1)
    out_bucket, out_prefix = args.s3_output_uri[5:].split("/", 1)

    ray.init() if args.local else ray.init(RAY_HEAD)
    log.info("Ray: %d node(s)", len(ray.nodes()))

    client = make_s3_client()
    keys = list_images(client, in_bucket, in_prefix)

    if args.resume:
        done = already_processed(client, out_bucket, out_prefix)
        keys = [k for k in keys if Path(k).stem not in done]
        log.info("Resume: %d images left", len(keys))
    else:
        log.info("Processing %d images", len(keys))

    if not keys:
        ray.shutdown()
        return

    n = args.num_workers
    workers = [
        SAM3Worker.remote(
            batch_size=args.batch_size,
            tile_size=args.tile_size,
            tile_stride=args.tile_stride,
            downsample=args.downsample,
        )
        for _ in range(n)
    ]

    if args.status_uri:
        status_bucket, status_key = args.status_uri[5:].split("/", 1)
    else:
        status_bucket = status_key = None

    # round-robin dispatch: image i -> worker (i mod n)
    futures = [
        workers[i % n].process.remote(in_bucket, key, out_bucket, out_prefix, labels)
        for i, key in enumerate(keys)
    ]

    started_at = time.time()
    total_detections = 0
    sum_worker_time = 0.0
    total_images = len(keys)
    processed_images = 0
    last_percent = -1

    # dataset metadata aggregated as images come back, written once at the end
    dataset_info = {
        "images": 0,
        "gps_count": 0,
        "cameras": set(),
        "softwares": set(),
        "resolutions": set(),
        "directions": [],
    }

    # ray.wait returns the futures as they complete (not in one block like
    # ray.get), which lets us increment the counter image by image.
    pending = futures
    while pending:
        done, pending = ray.wait(pending, num_returns=1)
        result = ray.get(done[0])
        total_detections += result["detections"]
        sum_worker_time += result["time"]
        processed_images += 1

        # accumulate dataset metadata
        meta = result["meta"]
        dataset_info["images"] += 1
        if result["has_gps"]:
            dataset_info["gps_count"] += 1
        camera = " ".join(p for p in (meta["make"], meta["model"]) if p)
        if camera:
            dataset_info["cameras"].add(camera)
        if meta["software"]:
            dataset_info["softwares"].add(meta["software"])
        dataset_info["resolutions"].add((meta["width"], meta["height"]))
        if meta["img_direction"] is not None:
            dataset_info["directions"].append(meta["img_direction"])

        percent = int(processed_images * 100 / total_images)
        if percent != last_percent:
            last_percent = percent
            log.info(
                "Progress: %d %% (%d/%d)", percent, processed_images, total_images
            )
            if status_key:
                write_status(
                    client, status_bucket, status_key, processed_images, total_images, started_at
                )

    # final frozen status (done=True): elapsed_seconds will no longer change
    if status_key:
        write_status(
            client, status_bucket, status_key, processed_images, total_images, started_at, done=True
        )

    # dataset summary at the root of the results
    write_dataset_info(client, out_bucket, out_prefix, labels, dataset_info)

    wall_time = time.time() - started_at
    num_images = total_images

    avg_wall = wall_time / num_images if num_images else 0
    avg_worker = sum_worker_time / num_images if num_images else 0
    log.info(
        "Done: %d images, %d detections\n"
        "  Wall time   : %.0fs (%.1fs/image)\n"
        "  Worker avg  : %.1fs/image (summed over workers)",
        num_images,
        total_detections,
        wall_time,
        avg_wall,
        avg_worker,
    )
    ray.shutdown()


if __name__ == "__main__":
    main()
