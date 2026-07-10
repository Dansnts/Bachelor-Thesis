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

import requests
import urllib3
from botocore.exceptions import BotoCoreError, ClientError

# S3 client shared with the rest of the project (the CLI runs from the repo)
sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "deploy", "jobs"),
)
from jobCore.s3 import make_s3_client

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Variables --------------------------------------------------
API_URL = os.getenv("API_URL", "https://sam3-api.iict-rad.iict-heig-vd.in")
BUCKET = os.getenv("BUCKET", "nearai")
IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png")


# Functions --------------------------------------------------
def images_prefix(acquisition):
    return "data/acquisitions/%s/01_images/" % acquisition


def results_prefix(acquisition):
    return "data/acquisitions/%s/09_Pipeline_result/" % acquisition


# API access --------------------------------------------------
def api_get(path, params=None):
    r = requests.get(API_URL + path, params=params, verify=False, timeout=60)
    r.raise_for_status()
    return r.json()


def api_post(path, body=None):
    r = requests.post(API_URL + path, json=body, verify=False, timeout=120)
    r.raise_for_status()
    return r.json()


# Commands --------------------------------------------------


def cmd_push(args):
    """Push local pictures to S3.

    Takes a local folder of pictures and uploads the images it contains to the
    acquisition's 01_images/ prefix in the bucket.

    Arguments :
    acquisition          name of the s3 acquisition folder
    directory            local folder holding the pictures
    bucket               s3 bucket where the pictures are uploaded
    """
    s3 = make_s3_client()
    prefix = images_prefix(args.acquisition)

    # Fail early if the directory is missing or unreadable rather than
    # dumping a raw OSError traceback on the user.
    try:
        entries = sorted(os.listdir(args.directory))
    except OSError as e:
        sys.exit("Cannot read directory %s: %s" % (args.directory, e))

    files = [f for f in entries if f.lower().endswith(IMAGE_EXTENSIONS)]
    if not files:
        sys.exit("No image found in %s" % args.directory)

    print("Uploading %d images to s3://%s/%s" % (len(files), args.bucket, prefix))

    # Upload one by one so a single bad file (unreadable, or an S3 error)
    # names the culprit instead of aborting the whole run silently.
    failed = 0
    for i, name in enumerate(files, 1):
        local = os.path.join(args.directory, name)
        try:
            s3.upload_file(local, args.bucket, prefix + name)
            print("  [%d/%d] %s" % (i, len(files), name))
        except (BotoCoreError, ClientError, OSError) as e:
            failed += 1
            print("  [%d/%d] %s FAILED: %s" % (i, len(files), name, e))

    if failed:
        sys.exit("%d/%d image(s) failed to upload" % (failed, len(files)))

    print("Done. Launch a batch with: nearai batch --acquisition %s" % args.acquisition)


def cmd_batch(args):
    """Launch a batch job on a whole acquisition via the API.

    Input and output prefixes are derived from the acquisition name, so the
    user only picks the labels and the parallelism.

    Arguments :
    acquisition          name of the s3 acquisition folder
    labels               comma-separated labels to segment
    workers              number of parallel Ray workers
    batch_size           images processed per worker step
    downsample           image scale factor before inference (1.0 = full size)
    bucket               s3 bucket holding the acquisition
    """

    body = {
        "s3Uri": images_prefix(args.acquisition),
        "s3OutputUri": results_prefix(args.acquisition),
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
    """Run inference on a single image via the API.

    The result is printed as-is (Label Studio JSON) for a quick check.

    Arguments :
    image                s3 key of the image to segment
    labels               comma-separated labels to segment
    downsample           image scale factor before inference (1.0 = full size)
    bucket               s3 bucket holding the image
    """

    body = {
        "imageUri": args.image,
        "s3Bucket": args.bucket,
        "labels": args.labels.split(","),
        "downsample": args.downsample,
    }
    print(api_post("/jobs/solo", body))


def cmd_status(args):
    """Show a batch job's progress, once or by polling.

    With --watch, poll every 5s until the run reports done.

    Arguments :
    job                  job name returned by `batch`
    watch                keep polling until the job finishes
    """
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
    """Fetch a solo job's stored result.

    Arguments :
    job                  job name returned by `solo`
    """
    print(api_get("/jobs/%s/result" % args.job))


def cmd_jobs(args):
    """List jobs, optionally filtered by kind (batch or solo).

    Arguments :
    kind                 restrict the listing to "batch" or "solo"
    """
    res = api_get("/jobs/", params={"kind": args.kind} if args.kind else None)
    for job in res.get("jobs", []):
        print(
            "%-28s %-7s %s" % (job.get("job_name"), job.get("kind"), job.get("status"))
        )


def cmd_import(args):
    """Convert an acquisition's Parquet output to Label Studio JSON.

    Targets every run by default, or a single run with --run. With --write the
    API stores the JSON back to S3 instead of only returning it.

    Arguments :
    acquisition          name of the s3 acquisition folder
    run                  job name of a specific run (default: all runs)
    write                store the JSON to S3 instead of returning it
    """
    query = "write=%s" % str(args.write).lower()
    if args.run:
        query += "&run=%s" % args.run
    res = api_post("/import/%s?%s" % (args.acquisition, query))
    print(res)


def cmd_segment(args):
    """Wake ("up") or sleep ("down") the segmentation service.

    Arguments :
    action               "up" to scale the service up, "down" to scale it down
    """
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

    p = sub.add_parser(
        "import", help="convert an acquisition's Parquet to Label Studio"
    )
    p.add_argument("acquisition")
    p.add_argument("--run", help="job name of a specific run (default: all runs)")
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
        sys.exit(
            "API error %s: %s"
            % (code, e.response.text if e.response is not None else e)
        )
    except requests.RequestException as e:
        sys.exit("Cannot reach the API at %s: %s" % (API_URL, e))


if __name__ == "__main__":
    main()
