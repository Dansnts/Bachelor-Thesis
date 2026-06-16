import argparse
import io
import json
import logging

import ray
from PIL import Image

from jobCore.s3 import make_s3_client
from jobCore.worker import DEFAULT_TILE_SIZE, DEFAULT_TILE_STRIDE, Sam3Model

log = logging.getLogger(__name__)


def getImage(bucket, key):
    obj = make_s3_client().get_object(Bucket=bucket, Key=key)
    return obj["Body"].read()


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


@ray.remote(num_gpus=1)  # 1 seul GPU car nous sommes en solo
class SoloWorker:
    def __init__(self, tile_size, tile_stride):
        self.model = Sam3Model(tile_size=tile_size, tile_stride=tile_stride)

    def process(self, image_bytes, labels):
        image = Image.open(io.BytesIO(image_bytes))
        return self.model.infer(image, labels)


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
        worker = SoloWorker.remote(tile_size=args.tileSize, tile_stride=args.tileStride)
        polygons, width, height = ray.get(worker.process.remote(picture, args.labels))
    finally:
        ray.shutdown()

    body = json.dumps(toLabelStudio(args.imageUri, polygons, width, height))
    print(body)

    if args.resultKey:
        make_s3_client().put_object(
            Bucket=args.bucket,
            Key=args.resultKey,
            Body=body.encode("utf-8"),
            ContentType="application/json",
        )
        log.info("Résultat écrit sur s3://%s/%s", args.bucket, args.resultKey)


if __name__ == "__main__":
    main()
