"""Convertit un Parquet de pre-annotations SAM3 en JSON Label Studio.

Une ligne Parquet = un polygone. On regroupe par image_key : chaque image
devient une tache Label Studio avec ses predictions polygonlabels.

Usage :
    python parquet_to_labelstudio.py input.parquet --bucket nearai -o out.json
"""

import argparse
import json

import pyarrow.parquet as pq


def parquet_to_tasks(path, bucket):
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
            {
                "type": "polygonlabels",
                "from_name": "label",
                "to_name": "image",
                "original_width": r["original_width"],
                "original_height": r["original_height"],
                "score": r["score"],
                "value": {
                    "closed": True,
                    "polygonlabels": [r["label"]],
                    "points": points,
                },
            }
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
    print("%d tache(s), %d polygone(s) -> %s" % (len(tasks), n_poly, args.output))


if __name__ == "__main__":
    main()
