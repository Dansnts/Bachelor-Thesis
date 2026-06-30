#!/usr/bin/env python3
"""Command-line client for the NearAI segmentation pipeline.

Wraps the REST API so a user can push images and launch a batch without
touching Kubernetes or Ray. Configuration comes from the environment, with
command-line flags taking precedence:

    API_URL              base URL of the API (default: the cluster ingress)
    S3_ENDPOINT_URL      MinIO endpoint (only needed for `push`)
    BUCKET               default bucket
    AWS_ACCESS_KEY       MinIO access key (only needed for `push`)
    AWS_SECRET_ACCESS_KEY

Typical flow:

    nearai push ./my_images --acquisition Vevey2
    nearai batch --acquisition Vevey2 --labels sign,road_marking --workers 3
    nearai status sam3-batch-xxxx --watch
"""

import argparse
import os
import sys
import time

import boto3
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

API_URL = os.getenv("API_URL", "https://sam3-api.iict-rad.iict-heig-vd.in")
BUCKET = os.getenv("BUCKET", "nearai")
IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png")


# Helpers --------------------------------------------------
def api_get(path, params=None):
    r = requests.get(API_URL + path, params=params, verify=False, timeout=60)
    r.raise_for_status()
    return r.json()


def api_post(path, body=None):
    r = requests.post(API_URL + path, json=body, verify=False, timeout=120)
    r.raise_for_status()
    return r.json()


def make_s3_client():
    return boto3.client(
        "s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        verify=False,
    )


def images_prefix(acquisition):
    return "data/acquisitions/%s/01_images/" % acquisition


def parquet_prefix(acquisition):
    return "data/acquisitions/%s/09_parquet/" % acquisition


# Commands --------------------------------------------------
def cmd_push(args):
    s3 = make_s3_client()
    prefix = images_prefix(args.acquisition)
    files = [
        f
        for f in sorted(os.listdir(args.directory))
        if f.lower().endswith(IMAGE_EXTENSIONS)
    ]
    if not files:
        sys.exit("No image found in %s" % args.directory)

    print("Uploading %d images to s3://%s/%s" % (len(files), args.bucket, prefix))
    for i, name in enumerate(files, 1):
        local = os.path.join(args.directory, name)
        s3.upload_file(local, args.bucket, prefix + name)
        print("  [%d/%d] %s" % (i, len(files), name))
    print("Done. Launch a batch with: nearai batch --acquisition %s" % args.acquisition)


def cmd_batch(args):
    body = {
        "s3Uri": images_prefix(args.acquisition),
        "s3OutputUri": parquet_prefix(args.acquisition),
        "s3Bucket": args.bucket,
        "labels": args.labels.split(","),
        "numWorkers": args.workers,
        "batchSize": args.batch_size,
        "downsample": args.downsample,
    }
    res = api_post("/jobs/batch", body)
    print("Submitted %s (%s)" % (res["job_name"], res["status"]))
    print("Follow it with: nearai status %s --watch" % res["job_name"])


def cmd_solo(args):
    body = {
        "imageUri": args.image,
        "s3Bucket": args.bucket,
        "labels": args.labels.split(","),
        "downsample": args.downsample,
    }
    print(api_post("/jobs/solo", body))


def cmd_status(args):
    while True:
        try:
            s = api_get("/jobs/%s/status" % args.job)
        except requests.HTTPError as e:
            # The driver writes its status file only once the run has started.
            # Until then /status returns 404: keep waiting in watch mode.
            if e.response is not None and e.response.status_code == 404 and args.watch:
                print("\rwaiting for the run to start ...", end="", flush=True)
                time.sleep(5)
                continue
            raise
        line = "%s : %s%% (%s/%s) elapsed=%ss" % (
            args.job,
            s.get("percent"),
            s.get("processed"),
            s.get("total"),
            int(s.get("elapsed_seconds", 0)),
        )
        if not args.watch:
            print(line)
            return
        print("\r" + line + "   ", end="", flush=True)
        if s.get("done"):
            print()
            return
        time.sleep(5)


def cmd_result(args):
    print(api_get("/jobs/%s/result" % args.job))


def cmd_jobs(args):
    res = api_get("/jobs/", params={"kind": args.kind} if args.kind else None)
    for job in res.get("jobs", []):
        print(
            "%-28s %-7s %s"
            % (job.get("job_name"), job.get("kind"), job.get("status"))
        )


def cmd_import(args):
    res = api_post("/import/%s?write=%s" % (args.acquisition, str(args.write).lower()))
    print(res)


def cmd_segment(args):
    print(api_post("/segment/%s" % args.action))


# Main --------------------------------------------------
def main():
    parser = argparse.ArgumentParser(prog="nearai", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("push", help="upload local images to the bucket")
    p.add_argument("directory")
    p.add_argument("--acquisition", required=True)
    p.add_argument("--bucket", default=BUCKET)
    p.set_defaults(func=cmd_push)

    p = sub.add_parser("batch", help="run a batch on an acquisition")
    p.add_argument("--acquisition", required=True)
    p.add_argument("--labels", required=True, help="comma-separated labels")
    p.add_argument("--workers", type=int, default=3)
    p.add_argument("--batch-size", type=int, default=4)
    p.add_argument("--downsample", type=float, default=1.0)
    p.add_argument("--bucket", default=BUCKET)
    p.set_defaults(func=cmd_batch)

    p = sub.add_parser("solo", help="run inference on a single image")
    p.add_argument("--image", required=True, help="S3 key of the image")
    p.add_argument("--labels", required=True, help="comma-separated labels")
    p.add_argument("--downsample", type=float, default=1.0)
    p.add_argument("--bucket", default=BUCKET)
    p.set_defaults(func=cmd_solo)

    p = sub.add_parser("status", help="show a job's progress")
    p.add_argument("job")
    p.add_argument("--watch", action="store_true", help="poll until done")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("result", help="fetch a solo job result")
    p.add_argument("job")
    p.set_defaults(func=cmd_result)

    p = sub.add_parser("jobs", help="list jobs")
    p.add_argument("--kind", choices=["batch", "solo"])
    p.set_defaults(func=cmd_jobs)

    p = sub.add_parser("import", help="convert an acquisition's Parquet to Label Studio")
    p.add_argument("acquisition")
    p.add_argument("--write", action="store_true", help="write the JSON to S3")
    p.set_defaults(func=cmd_import)

    p = sub.add_parser("segment", help="wake or sleep the segmentation service")
    p.add_argument("action", choices=["up", "down"])
    p.set_defaults(func=cmd_segment)

    args = parser.parse_args()
    try:
        args.func(args)
    except requests.HTTPError as e:
        code = e.response.status_code if e.response is not None else "?"
        sys.exit("API error %s: %s" % (code, e.response.text if e.response is not None else e))
    except requests.RequestException as e:
        sys.exit("Cannot reach the API at %s: %s" % (API_URL, e))


if __name__ == "__main__":
    main()
