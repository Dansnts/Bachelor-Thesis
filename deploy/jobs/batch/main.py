"""Distributed batch pipeline: Ray workers + MinIO I/O + Parquet output.

The driver connects to the RayCluster, lists the images of an S3 prefix and
distributes them across num_workers GPU actors. Each worker loads SAM3 once (via
Sam3Model), processes its images, reads their GPS from the acquisition's pose
trajectory (EXIF fallback) and writes the polygons as Parquet on MinIO.

Parquet schema: image_key, acquisition_id, label, score, points,
                original_width, original_height, latitude, longitude

Usage:
    # on the cluster (connects to the RayCluster head)
    python3.12 main.py \
        --s3_uri s3://nearai/data/acquisitions/Samples/01_images/ \
        --s3_output_uri s3://nearai/data/acquisitions/Samples/09_Pipeline_result/<run>/ \
        --labels sign,road_marking \
        --num_workers 2

The output mirrors the sub-structure of the input prefix: an image at
<input>/S001/foo.jpg lands at <output>/S001/foo.parquet. A params.json and a
dataset_info.txt describing the run are written at the root of <output>.

Instead of a prefix, --s3_uris takes an explicit comma-separated list of full
s3://bucket/key image URLs. The images can then live anywhere (any bucket, any
prefix); the output still lands under the single --s3_output_uri, each Parquet
mirroring its image's full parent path so scattered inputs cannot collide.

    # local test (single GPU, no cluster)
    python3.12 main.py --local --s3_uri ... --s3_output_uri ... --labels sign
"""

import argparse
import io
import json
import logging
import re
import time
from datetime import datetime, timezone
from pathlib import Path

import ray
from jobCore.s3 import get_object_bytes, iter_keys, make_s3_client
from jobCore.worker import (
    DEFAULT_BATCH_SIZE,
    DEFAULT_DOWNSAMPLE,
    DEFAULT_TILE_SIZE,
    DEFAULT_TILE_STRIDE,
    Sam3Model,
)
from PIL import Image

# Variables --------------------------------------------------
RAY_HEAD = "ray://ray-cluster-head-svc:10001"
SUPPORTED_EXT = {".jpg", ".jpeg", ".png", ".tiff", ".tif"}

# Logging --------------------------------------------------
log = logging.getLogger(__name__)


# S3 / EXIF --------------------------------------------------
def parse_s3_url(url):
    """Split a full s3://bucket/key image URL into (bucket, key).

    The scheme is mandatory: anything else is rejected, so a future source
    (e.g. https:// to download straight from the image provider) gets its own
    explicit handling instead of being silently misread as an S3 key.

    Arguments :
    url                  full URL of one image
    """
    if not url.startswith("s3://"):
        raise ValueError("unsupported URL (only s3:// is handled): %s" % url)
    bucket, _, key = url[5:].partition("/")
    if not bucket or not key:
        raise ValueError("expected s3://bucket/key, got: %s" % url)
    return bucket, key


def list_images(client, bucket, prefix):
    """List every supported image under an S3 prefix, sorted.

    Arguments :
    client               boto3 S3 client
    bucket               bucket to scan
    prefix               prefix under which to list the images
    """
    return sorted(
        key
        for key in iter_keys(client, bucket, prefix)
        if Path(key).suffix.lower() in SUPPORTED_EXT
    )


def already_processed(client, bucket, prefix):
    """Return the stems of the images already written as Parquet.

    Used by --resume to skip images whose result exists. Matches by file stem,
    so <img>.jpg is considered done once <img>.parquet is present.

    Arguments :
    client               boto3 S3 client
    bucket               output bucket to scan
    prefix               output prefix holding the existing Parquet
    """
    return {
        Path(key).stem
        for key in iter_keys(client, bucket, prefix)
        if key.endswith(".parquet")
    }


def dms_to_decimal(dms, ref):
    """Convert EXIF GPS degrees/minutes/seconds to a signed decimal degree.

    Arguments :
    dms                  (degrees, minutes, seconds) tuple from EXIF
    ref                  hemisphere ref; "S" or "W" makes the result negative
    """
    d, m, s = dms
    decimal = d + m / 60 + s / 3600
    return -decimal if ref in ("S", "W") else decimal


def download_image(client, bucket, key):
    """Download an image and pull its metadata (resolution, camera, GPS).

    Resolution comes from the decoded image; the camera fields and GPS come
    from EXIF when present. Missing or unreadable EXIF is not fatal: the
    coordinates stay None and the metadata fields stay empty.

    Arguments :
    client               boto3 S3 client
    bucket               bucket holding the image
    key                  S3 key of the image

    Returns (image, latitude, longitude, meta).
    """
    raw = get_object_bytes(client, bucket, key)
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    lat, lon = None, None
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
    """Write one image's detections as a Snappy-compressed Parquet on S3.

    One row = one detected polygon, following the pipeline schema (image_key,
    acquisition_id, label, score, points, resolution, latitude, longitude).

    Arguments :
    client               boto3 S3 client
    bucket               destination bucket
    key                  destination Parquet key
    rows                 list of row dicts matching the schema
    """
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
    """Write a human-readable dataset summary at the root of the results.

    "info" is filled by the driver as images come back from the workers
    (camera models, resolutions, GPS coverage, camera direction).

    Arguments :
    client               boto3 S3 client
    bucket               output bucket
    prefix               output prefix; the file lands at <prefix>/dataset_info.txt
    labels               labels segmented in this run
    info                 aggregated dataset metadata (see the driver's dataset_info)
    """
    cameras = sorted(c for c in info["cameras"] if c)
    softwares = sorted(s for s in info["softwares"] if s)
    resolutions = sorted("%dx%d" % (w, h) for (w, h) in info["resolutions"])

    if info["directions"]:
        lo = min(info["directions"])
        hi = max(info["directions"])
        direction_line = "available on %d images (%.1f to %.1f)" % (
            len(info["directions"]),
            lo,
            hi,
        )
    else:
        direction_line = "not provided by the device"

    lines = []
    lines.append("Dataset analysis summary")
    lines.append("========================")
    lines.append(
        "Generated (UTC) : %s"
        % datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    )
    lines.append("Images processed : %d" % info["images"])
    lines.append("Labels           : %s" % ", ".join(labels))
    lines.append("")
    lines.append(
        "Camera(s)        : %s" % (", ".join(cameras) if cameras else "unknown")
    )
    lines.append(
        "Software         : %s" % (", ".join(softwares) if softwares else "unknown")
    )
    lines.append(
        "Resolution(s)    : %s" % (", ".join(resolutions) if resolutions else "unknown")
    )
    lines.append(
        "GPS available    : %d/%d images" % (info["gps_count"], info["images"])
    )
    lines.append("Camera direction : %s" % direction_line)
    body = "\n".join(lines) + "\n"

    key = "%s/dataset_info.txt" % prefix.rstrip("/")
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="text/plain",
    )


def write_run_params(client, bucket, prefix, args, labels, images, detections):
    """Write the machine-readable run config as params.json.

    Sits at the root of the results so each run is self-documented: which
    parameters produced these Parquet.

    Arguments :
    client               boto3 S3 client
    bucket               output bucket
    prefix               output prefix; the file lands at <prefix>/params.json
    args                 parsed CLI args (uris, tiling, workers, downsample)
    labels               labels segmented in this run
    images               number of images processed
    detections           total polygons detected across the run
    """
    params = {
        "run": prefix.strip("/").rsplit("/", 1)[-1],
        "generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
        "input_uri": args.s3_uri or "explicit list of %d s3 urls" % images,
        "output_uri": args.s3_output_uri,
        "labels": labels,
        "num_workers": args.num_workers,
        "batch_size": args.batch_size,
        "tile_size": args.tile_size,
        "tile_stride": args.tile_stride,
        "downsample": args.downsample,
        "images_processed": images,
        "total_detections": detections,
    }
    key = "%s/params.json" % prefix.rstrip("/")
    client.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(params, indent=2).encode(),
        ContentType="application/json",
    )


def write_status(client, bucket, key, processed, total, started_at, done=False):
    """Write the run's progress file, read back by the API's /status endpoint.

    Arguments :
    client               boto3 S3 client
    bucket               bucket holding the status file
    key                  status object key
    processed            images done so far
    total                total images in the run
    started_at           run start (epoch seconds), for the elapsed time
    done                 True to freeze the file as final (adds elapsed_seconds)
    """
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


def relative_to_prefix(key, prefix):
    """Return an image's path relative to the input prefix.

    Lets the output mirror only the sub-structure of the input: an image at
    <prefix>/S001/foo.jpg yields "S001". Guards against false positives like
    "01_images_backup" matching "01_images". Returns "" when the image sits
    directly at the prefix root.

    Arguments :
    key                  S3 key of the image
    prefix               input prefix the key lives under
    """
    parent = str(Path(key).parent).strip("/")
    base = prefix.strip("/")
    if base and (parent == base or parent.startswith(base + "/")):
        return parent[len(base) :].strip("/")
    return parent


def get_acquisition_id(key):
    """Extract the acquisition name from an image key.

    Takes the segment right after "acquisitions/" in the path; falls back to
    the image's grand-parent folder name when the path has no such marker.

    Arguments :
    key                  S3 key of the image
    """
    parts = Path(key).parts
    try:
        idx = list(parts).index("acquisitions")
        return parts[idx + 1]
    except (ValueError, IndexError):
        return Path(key).parent.parent.name


# GPS / poses --------------------------------------------------
def _to_float(value):
    """Parse a CSV cell to float, returning None on empty or bad values.

    Arguments :
    value                raw string from the trajectory CSV
    """
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def pose_csv_key(key):
    """Derive the trajectory CSV key for an image, or None.

    An image's GPS poses live in <acq>/02_poses/<session>_trajectory.csv. The
    session comes from the folder between 01_images and the file when the
    acquisition is nested (<acq>/01_images/<session>/<name>), otherwise from the
    S<NNN> token in the filename for flat acquisitions (<acq>/01_images/<name>,
    with names like ..._S001_...). Returns None when neither yields a session.

    Arguments :
    key                  S3 key of the image
    """
    parts = list(Path(key).parts)
    try:
        idx = parts.index("01_images")
    except ValueError:
        return None
    if idx + 2 < len(parts):
        session = parts[idx + 1]  # nested: <acq>/01_images/<session>/<file>
    else:
        m = re.search(r"_(S\d+)_", Path(key).name)  # flat: session in the name
        session = m.group(1) if m else None
    if not session:
        return None
    acq_prefix = "/".join(parts[:idx])
    return "%s/02_poses/%s_trajectory.csv" % (acq_prefix, session)


def load_poses(client, bucket, csv_key):
    """Load a session's trajectory into {image_name: (lat, lon, heading)}.

    The trajectory file is the authoritative GPS source of an acquisition: each
    row ties an image_name to its gps_latitude / gps_longitude (and heading),
    unlike EXIF which is absent on Ladybug panoramas. A missing or unreadable
    file yields an empty map, so callers fall back to EXIF.

    Arguments :
    client               boto3 S3 client
    bucket               bucket holding the poses
    csv_key              S3 key of the <session>_trajectory.csv
    """
    import csv

    poses = {}
    try:
        raw = get_object_bytes(client, bucket, csv_key)
    except Exception:
        return poses
    lines = raw.decode("utf-8", "replace").splitlines()
    for row in csv.DictReader(lines):
        name = row.get("image_name")
        if not name:
            continue
        poses[name] = (
            _to_float(row.get("gps_latitude")),
            _to_float(row.get("gps_longitude")),
            _to_float(row.get("heading_deg")),
        )
    return poses


# Ray actor --------------------------------------------------


@ray.remote(num_gpus=1)
class SAM3Worker:
    """A GPU actor that segments images on the RayCluster.

    Each instance owns one GPU, loads SAM3 once at creation and then processes
    the images the driver dispatches to it. The driver spawns num_workers of
    these and hands out images round-robin.

    Attributes:
        model: the SAM3 model, loaded once and reused for every image.
        s3: this worker's own boto3 S3 client (for download and upload).
    """

    def __init__(
        self,
        batch_size=DEFAULT_BATCH_SIZE,
        tile_size=DEFAULT_TILE_SIZE,
        tile_stride=DEFAULT_TILE_STRIDE,
        downsample=DEFAULT_DOWNSAMPLE,
    ):
        """Load SAM3 on the actor's GPU and open its S3 client.

        Arguments :
        batch_size           tiles inferred at once on the GPU
        tile_size            side of the square tiles the image is cut into
        tile_stride          tile step; < tile_size overlaps the tiles
        downsample           shrink factor applied before tiling
        """
        self.model = Sam3Model(
            tile_size=tile_size,
            tile_stride=tile_stride,
            batch_size=batch_size,
            downsample=downsample,
        )
        self.s3 = make_s3_client()
        self.poses = {}
        self.log = logging.getLogger("jobCore")
        self.log.info(
            "Worker ready on node %s", ray.get_runtime_context().get_node_id()[:12]
        )

    def gps_for(self, bucket, key):
        """Look up an image's GPS in its session trajectory (cached per session).

        Returns (lat, lon, heading), each None when the pose is unavailable.

        Arguments :
        bucket               bucket holding the poses
        key                  S3 key of the image
        """
        csv_key = pose_csv_key(key)
        if csv_key is None:
            return None, None, None
        if csv_key not in self.poses:
            self.poses[csv_key] = load_poses(self.s3, bucket, csv_key)
        return self.poses[csv_key].get(Path(key).name, (None, None, None))

    def process(self, bucket, key, in_prefix, out_bucket, out_prefix, labels):
        """Segment one image and write its detections as Parquet.

        Downloads the image, runs inference, and writes <stem>.parquet under
        out_prefix at the same sub-path the image had under in_prefix (so the
        output mirrors the input layout).

        Arguments :
        bucket               bucket holding the image
        key                  S3 key of the image
        in_prefix            input prefix, used to mirror the layout in the output
        out_bucket           destination bucket for the Parquet
        out_prefix           destination prefix (this run's folder)
        labels               labels to segment

        Returns a dict the driver aggregates (detections, time, GPS, metadata).
        """
        t0 = time.time()
        image, lat, lon, meta = download_image(self.s3, bucket, key)
        pose_lat, pose_lon, heading = self.gps_for(bucket, key)
        if pose_lat is not None and pose_lon is not None:
            lat, lon = pose_lat, pose_lon
        if heading is not None:
            meta["img_direction"] = heading
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
        rel = relative_to_prefix(key, in_prefix)
        out_key = (
            f"{out_prefix.rstrip('/')}/{rel}/{stem}.parquet"
            if rel
            else f"{out_prefix.rstrip('/')}/{stem}.parquet"
        )
        upload_parquet(self.s3, out_bucket, out_key, rows)

        elapsed = time.time() - t0
        self.log.info(
            "%s -> %d detections in %.1fs", Path(key).name, len(rows), elapsed
        )
        return {
            "key": key,
            "detections": len(rows),
            "time": elapsed,
            "has_gps": lat is not None,
            "meta": meta,
        }


# Main --------------------------------------------------


def connect_ray(address, attempts=5, delay=10):
    """Connect to the RayCluster head, retrying the flaky first contact.

    The Ray Client proxier occasionally dies while spawning the per-connection
    server (gRPC fork race), which aborts the very first connection. Retrying
    in place is much cheaper than letting the whole pod fail and restart.

    Arguments :
    address              ray://host:port of the cluster head
    attempts             connection attempts before giving up
    delay                seconds between attempts
    """
    for i in range(attempts):
        try:
            return ray.init(address)
        except ConnectionError as e:
            if i == attempts - 1:
                raise
            log.warning(
                "Ray connection failed (%s), retry %d/%d in %ds",
                e,
                i + 1,
                attempts - 1,
                delay,
            )
            time.sleep(delay)


def main():
    """Driver: connect to Ray, dispatch the images, aggregate the results.

    Lists the images of the input prefix, spawns num_workers GPU actors and
    hands out the images round-robin. Consumes results as they complete to keep
    the progress file live, then writes dataset_info.txt and params.json at the
    root of the output. Parameters come from the command line (see --help).
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("--s3_uri", default=None, help="s3://bucket/prefix/")
    parser.add_argument(
        "--s3_uris",
        default=None,
        help="comma-separated full s3://bucket/key image URLs (alternative to --s3_uri)",
    )
    parser.add_argument("--s3_output_uri", required=True, help="s3://bucket/prefix/")
    parser.add_argument("--labels", required=True, help="comma-separated labels")
    parser.add_argument("--batch_size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--num_workers", type=int, default=2)
    parser.add_argument("--tile_size", type=int, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--tile_stride", type=int, default=DEFAULT_TILE_STRIDE)
    parser.add_argument("--downsample", type=float, default=DEFAULT_DOWNSAMPLE)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument(
        "--local", action="store_true", help="ray.init() without cluster"
    )
    parser.add_argument(
        "--status_uri",
        default=None,
        help="s3://bucket/key where progress is written (read back by the API)",
    )
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    if bool(args.s3_uri) == bool(args.s3_uris):
        parser.error("exactly one of --s3_uri or --s3_uris is required")
    if not args.s3_output_uri.startswith("s3://"):
        parser.error("--s3_output_uri must be a full s3://bucket/prefix/ URI")

    labels = [l.strip() for l in args.labels.split(",") if l.strip()]
    out_bucket, out_prefix = args.s3_output_uri[5:].split("/", 1)

    ray.init() if args.local else connect_ray(RAY_HEAD)
    log.info("Ray: %d node(s)", len(ray.nodes()))

    client = make_s3_client()
    if args.s3_uri:
        if not args.s3_uri.startswith("s3://"):
            parser.error("--s3_uri must be a full s3://bucket/prefix/ URI")
        in_bucket, in_prefix = args.s3_uri[5:].split("/", 1)
        images = [(in_bucket, k) for k in list_images(client, in_bucket, in_prefix)]
    else:
        # explicit list: the images can live anywhere; with no common prefix to
        # strip, each Parquet mirrors its image's full parent path in the output
        in_prefix = ""
        images = [parse_s3_url(u.strip()) for u in args.s3_uris.split(",") if u.strip()]

    if args.resume:
        done = already_processed(client, out_bucket, out_prefix)
        images = [(b, k) for b, k in images if Path(k).stem not in done]
        log.info("Resume: %d images left", len(images))
    else:
        log.info("Processing %d images", len(images))

    if not images:
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
        workers[i % n].process.remote(
            bucket, key, in_prefix, out_bucket, out_prefix, labels
        )
        for i, (bucket, key) in enumerate(images)
    ]

    started_at = time.time()
    total_detections = 0
    sum_worker_time = 0.0
    total_images = len(images)
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
            log.info("Progress: %d %% (%d/%d)", percent, processed_images, total_images)
            if status_key:
                write_status(
                    client,
                    status_bucket,
                    status_key,
                    processed_images,
                    total_images,
                    started_at,
                )

    # final frozen status (done=True): elapsed_seconds will no longer change
    if status_key:
        write_status(
            client,
            status_bucket,
            status_key,
            processed_images,
            total_images,
            started_at,
            done=True,
        )

    # dataset summary + run parameters at the root of the results
    write_dataset_info(client, out_bucket, out_prefix, labels, dataset_info)
    write_run_params(
        client, out_bucket, out_prefix, args, labels, total_images, total_detections
    )

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
