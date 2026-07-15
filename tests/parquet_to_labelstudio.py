"""Convert a Parquet of SAM3 pre-annotations to Label Studio JSON.

One Parquet row = one polygon. Rows are grouped by image_key: each image
becomes one Label Studio task with its polygonlabels predictions. Offline
twin of the API's /import endpoint, handy to inspect a single file.

Usage :
    python parquet_to_labelstudio.py input.parquet --bucket nearai -o out.json
"""

import argparse
import json
import os
import sys

import pyarrow.parquet as pq

# Label Studio result format shared with the rest of the project
sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "deploy", "jobs"),
)
from jobCore.labelstudio import polygon_result


def parquet_to_tasks(path, bucket):
    """Group the Parquet rows into Label Studio tasks, one per image.

    Arguments :
    path                 local path of the Parquet file
    bucket               bucket name used to build the tasks' image URIs
    """
    rows = pq.read_table(path).to_pylist()

    tasks = {}
    for r in rows:
        key = r["image_key"]
        if key not in tasks:
            tasks[key] = {
                "data": {"image": "s3://%s/%s" % (bucket, key)},
                "predictions": [{"model_version": "SAM3", "result": []}],
            }
        points = r["points"]
        if isinstance(points, str):
            points = json.loads(points)
        tasks[key]["predictions"][0]["result"].append(
            polygon_result(
                r["label"],
                points,
                r["original_width"],
                r["original_height"],
                r["score"],
            )
        )
    return list(tasks.values())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("parquet")
    parser.add_argument("--bucket", default="nearai")
    parser.add_argument("-o", "--output", default="labelstudio.json")
    args = parser.parse_args()

    tasks = parquet_to_tasks(args.parquet, args.bucket)
    with open(args.output, "w") as f:
        json.dump(tasks, f, indent=2)

    n_poly = sum(len(t["predictions"][0]["result"]) for t in tasks)
    print("%d task(s), %d polygon(s) -> %s" % (len(tasks), n_poly, args.output))


if __name__ == "__main__":
    main()
