import argparse
import io
import json
import logging

import ray
from PIL import Image

from jobCore.labelstudio import polygon_result
from jobCore.s3 import get_object_bytes, make_s3_client
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
    """Download the image to segment from the bucket."""
    return get_object_bytes(make_s3_client(), bucket, key)


def to_label_studio(image_uri, polygons, img_w, img_h):
    """Wrap the detected polygons as one Label Studio task.

    Arguments :
    image_uri            URI of the segmented image, echoed in the task data
    polygons             list of (label, points, score) from the model
    img_w                original image width in pixels
    img_h                original image height in pixels
    """
    results = []
    scores = []
    for label, points, score in polygons:
        scores.append(score)
        results.append(polygon_result(label, points, img_w, img_h, score))
    # Prediction-level score = mean detection confidence, used by Label Studio
    # to rank predictions.
    prediction = {"model_version": "SAM3", "result": results}
    if scores:
        prediction["score"] = round(sum(scores) / len(scores), 4)
    return [
        {
            "data": {"image": image_uri},
            "predictions": [prediction],
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
