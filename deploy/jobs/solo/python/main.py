import argparse
import io
import json
import logging

import ray
from PIL import Image

from jobCore.s3 import make_s3_client
from jobCore.worker import (
    DEFAULT_DOWNSAMPLE,
    DEFAULT_TILE_SIZE,
    DEFAULT_TILE_STRIDE,
    Sam3Model,
)

# Logging --------------------------------------------------
log = logging.getLogger(__name__)


# Helpers --------------------------------------------------
def get_image(bucket, key):
    obj = make_s3_client().get_object(Bucket=bucket, Key=key)
    return obj["Body"].read()


def to_label_studio(image_uri, polygons, img_w, img_h):
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


# Ray actor --------------------------------------------------
@ray.remote(num_gpus=1)  # single GPU since we are in solo mode
class SoloWorker:
    def __init__(self, tile_size, tile_stride, downsample):
        self.model = Sam3Model(
            tile_size=tile_size, tile_stride=tile_stride, downsample=downsample
        )

    def process(self, image_bytes, labels):
        image = Image.open(io.BytesIO(image_bytes))
        return self.model.infer(image, labels)


# Main --------------------------------------------------
def main():
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
    )

    parser = argparse.ArgumentParser()
    parser.add_argument("--image_uri", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--labels", nargs="+", required=True)
    parser.add_argument("--tile_size", type=int, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--tile_stride", type=int, default=DEFAULT_TILE_STRIDE)
    parser.add_argument("--downsample", type=float, default=DEFAULT_DOWNSAMPLE)
    parser.add_argument("--result_key", default=None)
    args = parser.parse_args()

    log.info("Downloading %s from bucket %s", args.image_uri, args.bucket)
    picture = get_image(args.bucket, args.image_uri)

    ray.init()
    try:
        worker = SoloWorker.remote(
            tile_size=args.tile_size,
            tile_stride=args.tile_stride,
            downsample=args.downsample,
        )
        polygons, width, height = ray.get(worker.process.remote(picture, args.labels))
    finally:
        ray.shutdown()

    body = json.dumps(to_label_studio(args.image_uri, polygons, width, height))
    print(body)

    if args.result_key:
        make_s3_client().put_object(
            Bucket=args.bucket,
            Key=args.result_key,
            Body=body.encode("utf-8"),
            ContentType="application/json",
        )
        log.info("Result written to s3://%s/%s", args.bucket, args.result_key)


if __name__ == "__main__":
    main()
