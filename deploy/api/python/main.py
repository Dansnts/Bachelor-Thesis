import argparse
import io
import json
import logging
import os
import time
import uuid
from typing import List

import requests
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
from kubernetes import client, config
from pydantic import (
    BaseModel,  # JSON validation / parsing: Pydantic validates types and converts the JSON
)

try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()


load_dotenv()

# Variables --------------------------------------------------
NAMESPACE = os.getenv("NAMESPACE", "dani")
S3_ENDPOINT = os.getenv(
    "S3_ENDPOINT_URL", "https://storage-kubernetes.iict-heig-vd.in:9000"
)
BATCH_IMAGE = os.getenv("BATCH_IMAGE", "ghcr.io/nearai-interreg/ray-sam3:staging")
SOLO_IMAGE = os.getenv("SOLO_IMAGE", "ghcr.io/nearai-interreg/sam3-solo:staging")
PORT = int(os.getenv("PORT", "8000"))
ADDRESS = os.getenv("V4_ADDRESS", "0.0.0.0")
BUCKET = os.getenv("BUCKET", "nearai")
SEGMENT_URL = os.getenv("SEGMENT_URL", "http://sam3-segment:8000")
SEGMENT_DEPLOYMENT = os.getenv("SEGMENT_DEPLOYMENT", "sam3-segment")

batch_v1 = client.BatchV1Api()
core_v1 = client.CoreV1Api()
apps_v1 = client.AppsV1Api()


# Classes --------------------------------------------------
# Pydantic field names stay camelCase: they are the public JSON API contract.
class BatchRequest(BaseModel):
    s3Uri: str
    s3OutputUri: str
    s3Bucket: str
    labels: List[str]
    numWorkers: int
    batchSize: int  # number of images sent to a worker at once
    tileSize: int = 1008
    tileStride: int = (
        768  # tile overlap, ensures objects split across a cut are still analysed
    )
    downsample: float = 1.0  # shrink factor before tiling (1.0 = full resolution)


class SoloRequest(BaseModel):
    imageUri: str
    s3Bucket: str
    labels: List[str]
    tileSize: int = 1008
    tileStride: int = 768
    downsample: float = 1.0


class SegmentItem(BaseModel):
    point: List[int]  # [x, y]
    label: str


class SegmentRequest(BaseModel):
    url: str  # S3 key of the image
    items: List[SegmentItem]


# Logging --------------------------------------------------
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s level=%(levelname)s logger=%(name)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("nearapi")

app = FastAPI()


@app.middleware("http")
async def log_requests(request, call_next):
    start = time.time()
    try:
        response = await call_next(request)
    except Exception:
        duration_ms = (time.time() - start) * 1000
        log.exception(
            "request method=%s path=%s status=500 duration_ms=%.1f",
            request.method,
            request.url.path,
            duration_ms,
        )
        raise
    duration_ms = (time.time() - start) * 1000
    level = logging.WARNING if response.status_code >= 400 else logging.INFO
    log.log(
        level,
        "request method=%s path=%s status=%d duration_ms=%.1f",
        request.method,
        request.url.path,
        response.status_code,
        duration_ms,
    )
    return response


# S3 --------------------------------------------------
def s3_client():
    import boto3
    import urllib3
    from botocore.client import Config

    # MinIO uses a self-signed certificate, so we connect with verify=False.
    # Silence the per-request InsecureRequestWarning that would flood the logs.
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    return boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 1}),
        verify=False,
    )


def to_s3_uri(bucket, path):
    # the pipeline expects an s3://bucket/prefix URI. We accept both.
    if path.startswith("s3://"):
        return path
    return f"s3://{bucket}/{path.lstrip('/')}"


def list_parquet_keys(s3, bucket, prefix):
    # Lists every .parquet object under the prefix.
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".parquet"):
                keys.append(obj["Key"])
    return keys


def read_parquet_file(s3, bucket, key):
    # Reads one .parquet and returns its rows as dicts (one row = one polygon).
    import pyarrow.parquet as pq

    body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    return pq.read_table(io.BytesIO(body)).to_pylist()


def stream_to_s3(s3, bucket, key, byte_iter):
    # Streams the byte chunks into a multipart upload so a large import (tens of
    # thousands of images, >1 GB of JSON) never sits whole in memory.
    PART = 5 * 1024 * 1024  # S3 requires parts >= 5 MiB (except the last one)
    upload_id = s3.create_multipart_upload(
        Bucket=bucket, Key=key, ContentType="application/json"
    )["UploadId"]
    parts = []
    buf = bytearray()
    part_no = 1
    try:
        for chunk in byte_iter:
            buf.extend(chunk)
            if len(buf) >= PART:
                r = s3.upload_part(
                    Bucket=bucket, Key=key, PartNumber=part_no,
                    UploadId=upload_id, Body=bytes(buf),
                )
                parts.append({"ETag": r["ETag"], "PartNumber": part_no})
                part_no += 1
                buf = bytearray()
        # last part (any size), or an empty body if there was nothing buffered
        if buf or not parts:
            r = s3.upload_part(
                Bucket=bucket, Key=key, PartNumber=part_no,
                UploadId=upload_id, Body=bytes(buf),
            )
            parts.append({"ETag": r["ETag"], "PartNumber": part_no})
        s3.complete_multipart_upload(
            Bucket=bucket, Key=key, UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )
    except Exception:
        s3.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
        raise
    return to_s3_uri(bucket, key)


# K8S API --------------------------------------------------
def build_job(name, image, command, args, gpu=True, access_key_env="AWS_ACCESS_KEY"):
    env = [
        client.V1EnvVar(
            name=access_key_env,
            value_from=client.V1EnvVarSource(
                secret_key_ref=client.V1SecretKeySelector(
                    name="minio-secret", key="access_key"
                )
            ),
        ),
        client.V1EnvVar(
            name="AWS_SECRET_ACCESS_KEY",
            value_from=client.V1EnvVarSource(
                secret_key_ref=client.V1SecretKeySelector(
                    name="minio-secret", key="secret_key"
                )
            ),
        ),
        client.V1EnvVar(
            name="HF_TOKEN",
            value_from=client.V1EnvVarSource(
                secret_key_ref=client.V1SecretKeySelector(
                    name="hf-secret", key="HF_TOKEN"
                )
            ),
        ),
        client.V1EnvVar(name="S3_ENDPOINT_URL", value=os.getenv("S3_ENDPOINT_URL")),
    ]

    if gpu:
        resources = client.V1ResourceRequirements(
            requests={"cpu": "4", "memory": "16Gi"},
            limits={"nvidia.com/gpu": "1", "cpu": "8", "memory": "32Gi"},
        )
    else:
        # batch driver: just enough to orchestrate, the compute is on the RayCluster
        resources = client.V1ResourceRequirements(
            requests={"cpu": "1", "memory": "2Gi"},
            limits={"cpu": "2", "memory": "4Gi"},
        )

    # Container
    container = client.V1Container(
        name=name,
        image=image,
        image_pull_policy="Always",
        command=command,
        args=args,
        env=env,
        resources=resources,
    )

    pod_spec = client.V1PodSpec(
        restart_policy="Never",
        image_pull_secrets=[
            client.V1LocalObjectReference(
                name="ghcr-secret"
            )  # secret to pull the images from the registry
        ],
        containers=[container],
    )
    if gpu:
        pod_spec.runtime_class_name = "nvidia"

    job = client.V1Job(
        api_version="batch/v1",
        kind="Job",
        metadata=client.V1ObjectMeta(name=name, namespace=NAMESPACE),
        spec=client.V1JobSpec(
            ttl_seconds_after_finished=3600,
            # Label the pod with its app name (sam3-batch / sam3-solo, derived
            # from the job name without its uuid suffix) so Alloy tags the logs
            # with `app` in Loki, like the other components.
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(
                    labels={"app": name.rsplit("-", 1)[0]}
                ),
                spec=pod_spec,
            ),
        ),
    )

    try:
        batch_v1.create_namespaced_job(NAMESPACE, job)
        log.info(
            "job_created job=%s image=%s gpu=%s namespace=%s",
            name,
            image,
            gpu,
            NAMESPACE,
        )
        return {"job_name": name, "status": "submitted"}
    except client.ApiException as e:
        log.error(
            "job_create_failed job=%s status=%s reason=%s", name, e.status, e.reason
        )
        raise HTTPException(status_code=e.status, detail=e.reason)


def scale_segment(replicas):
    try:
        apps_v1.patch_namespaced_deployment_scale(
            name=SEGMENT_DEPLOYMENT,
            namespace=NAMESPACE,
            body={"spec": {"replicas": replicas}},
        )
    except client.ApiException as e:
        log.error(
            "segment_scale_failed deployment=%s replicas=%s reason=%s",
            SEGMENT_DEPLOYMENT,
            replicas,
            e.reason,
        )
        raise HTTPException(status_code=e.status, detail=e.reason)
    log.info("segment_scaled deployment=%s replicas=%s", SEGMENT_DEPLOYMENT, replicas)
    return {"deployment": SEGMENT_DEPLOYMENT, "replicas": replicas}


# Helpers --------------------------------------------------
def job_status(job):
    # Maps a V1Job status to a single readable state.
    s = job.status
    if s.succeeded:
        return "Succeeded"
    if s.failed:
        return "Failed"
    if s.active:
        return "Active"
    return "Pending"


def rows_to_label_studio(bucket, rows):
    # Groups the polygon rows by image and builds one Label Studio task per
    # image (predictions = every polygon detected on that image). Points are
    # already stored as percentages, so they map straight onto the image.
    tasks = {}
    for r in rows:
        key = r["image_key"]
        task = tasks.get(key)
        if task is None:
            task = {
                "data": {"image": to_s3_uri(bucket, key)},
                "predictions": [{"model_version": "SAM3", "result": []}],
            }
            tasks[key] = task
        task["predictions"][0]["result"].append(
            {
                "type": "polygonlabels",
                "from_name": "label",
                "to_name": "image",
                "original_width": r["original_width"],
                "original_height": r["original_height"],
                "value": {
                    "closed": True,
                    "polygonlabels": [r["label"]],
                    "points": json.loads(r["points"]),
                },
            }
        )
    return list(tasks.values())


def iter_label_studio_tasks(s3, bucket, keys, workers=16):
    # Yields the Label Studio tasks one image at a time. The batch pipeline
    # writes one Parquet per image, so we read + convert file by file and never
    # hold the whole dataset in memory. Reads are done in parallel batches since
    # the cost is dominated by the S3 round-trips.
    from concurrent.futures import ThreadPoolExecutor

    batch = workers * 4
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for i in range(0, len(keys), batch):
            chunk = keys[i : i + batch]
            for rows in pool.map(lambda k: read_parquet_file(s3, bucket, k), chunk):
                for task in rows_to_label_studio(bucket, rows):
                    yield task


def iter_label_studio_json(task_iter):
    # Frames the streamed tasks as a single JSON array, without building it all
    # in memory. Yields bytes so it feeds both StreamingResponse and S3 upload.
    yield b"["
    first = True
    for task in task_iter:
        yield (b"" if first else b",") + json.dumps(task).encode()
        first = False
    yield b"]"


# Endpoints --------------------------------------------------
@app.get("/")
async def root():
    return {"message": "NearAPI is running."}


@app.get("/health")
def health():
    # confirms the API is up and the Kubernetes
    try:
        core_v1.list_namespaced_pod(NAMESPACE, limit=1)
    except client.ApiException as e:
        log.error("health_check_failed reason=%s", e.reason)
        raise HTTPException(status_code=503, detail="kubernetes api unreachable")

    return {"status": "ok"}


@app.post("/jobs/batch")
def submit_batch(req: BatchRequest):
    # CPU-only driver: it connects to the RayCluster and distributes the images
    # of the S3 prefix across num_workers GPU actors. Reuses the proven pipeline
    # (same image as the Ray workers).
    name = f"sam3-batch-{uuid.uuid4().hex[:8]}"
    log.info(
        "batch_submit job=%s input=%s workers=%d batch_size=%d tile=%d downsample=%.2f labels=%d",
        name,
        to_s3_uri(req.s3Bucket, req.s3Uri),
        req.numWorkers,
        req.batchSize,
        req.tileSize,
        req.downsample,
        len(req.labels),
    )

    arg_list = [
        "--s3_uri",
        to_s3_uri(req.s3Bucket, req.s3Uri),
        "--s3_output_uri",
        to_s3_uri(req.s3Bucket, req.s3OutputUri),
        "--labels",
        ",".join(req.labels),
        "--num_workers",
        str(req.numWorkers),
        "--batch_size",
        str(req.batchSize),
        "--tile_size",
        str(req.tileSize),
        "--tile_stride",
        str(req.tileStride),
        "--downsample",
        str(req.downsample),
        "--status_uri",
        to_s3_uri(BUCKET, f"results/{name}.status.json"),
    ]

    return build_job(
        name,
        BATCH_IMAGE,
        ["python3.12", "/app/main.py"],
        arg_list,
        gpu=False,
        access_key_env="AWS_ACCESS_KEY_ID",
    )


@app.post("/jobs/solo")
def submit_solo(req: SoloRequest):

    name = f"sam3-solo-{uuid.uuid4().hex[:8]}"
    log.info(
        "solo_submit job=%s image=%s tile=%d downsample=%.2f labels=%d",
        name,
        req.imageUri,
        req.tileSize,
        req.downsample,
        len(req.labels),
    )

    arg_list = [
        "--image_uri",
        req.imageUri,
        "--bucket",
        req.s3Bucket,
        "--result_key",
        f"results/{name}.json",
        "--tile_size",
        str(req.tileSize),
        "--tile_stride",
        str(req.tileStride),
        "--downsample",
        str(req.downsample),
        "--labels",
    ] + req.labels

    return build_job(name, SOLO_IMAGE, ["python3", "/app/main.py"], arg_list)


@app.get("/jobs/")
def get_jobs(kind: str = None):
    # Lists the sam3 batch and solo jobs of the namespace, newest first.
    # Optional kind filter: "batch" or "solo".
    try:
        jobs = batch_v1.list_namespaced_job(NAMESPACE).items
    except client.ApiException as e:
        log.error("jobs_list_failed status=%s reason=%s", e.status, e.reason)
        raise HTTPException(status_code=e.status, detail=e.reason)

    result = []

    for job in jobs:
        name = job.metadata.name
        if not name.startswith("sam3-batch-") and not name.startswith("sam3-solo-"):
            continue

        job_kind = "batch" if name.startswith("sam3-batch-") else "solo"

        if kind and job_kind != kind:
            continue
        result.append(
            {
                "job_name": name,
                "kind": job_kind,
                "status": job_status(job),
                "created_at": job.metadata.creation_timestamp.isoformat(),
            }
        )

    result.sort(key=lambda j: j["created_at"], reverse=True)
    log.info("jobs_list kind=%s count=%d", kind or "all", len(result))
    return {"jobs": result}


@app.get("/jobs/{name}")
def get_job(name: str):
    try:
        job = batch_v1.read_namespaced_job(name, NAMESPACE)
    except client.ApiException as e:
        log.warning(
            "job_read_failed job=%s status=%s reason=%s", name, e.status, e.reason
        )
        raise HTTPException(status_code=e.status, detail=e.reason)

    status = job_status(job)
    log.info("job_status job=%s status=%s", name, status)
    return {"job_name": name, "status": status}


@app.get("/jobs/{name}/status")
def get_status(name):
    # Reads back the progress file written by the batch driver on S3.
    key = f"results/{name}.status.json"
    s3 = s3_client()
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
    except s3.exceptions.NoSuchKey:
        log.warning("status_not_ready job=%s", name)
        raise HTTPException(status_code=404, detail="status not available yet")

    data = json.loads(obj["Body"].read())

    if not data.get("done") and data.get("started_at"):
        data["elapsed_seconds"] = round(time.time() - data["started_at"], 1)

    log.info(
        "status_read job=%s percent=%s processed=%s/%s elapsed=%s",
        name,
        data.get("percent"),
        data.get("processed"),
        data.get("total"),
        data.get("elapsed_seconds"),
    )

    # no-store: prevents the browser from serving a cached response on refresh
    return JSONResponse(content=data, headers={"Cache-Control": "no-store"})


@app.get("/jobs/{name}/result")
def get_result(name):
    key = f"results/{name}.json"
    s3 = s3_client()
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
    except s3.exceptions.NoSuchKey:
        log.warning("result_not_found job=%s", name)
        raise HTTPException(status_code=404, detail="result not found")

    return json.loads(obj["Body"].read())


@app.post("/segment")
def segment(req: SegmentRequest):
    try:
        resp = requests.post(
            f"{SEGMENT_URL}/segment", json=req.model_dump(), timeout=120
        )
    except requests.RequestException as e:
        log.error("segment_unreachable url=%s error=%s", SEGMENT_URL, e)
        raise HTTPException(status_code=502, detail=f"segment service unreachable: {e}")

    if resp.status_code != 200:
        log.warning("segment_upstream_error status=%d", resp.status_code)
        raise HTTPException(status_code=resp.status_code, detail=resp.text)

    log.info("segment_ok url=%s items=%d", req.url, len(req.items))
    return resp.json()


@app.post("/segment/up")
def segment_up():
    return scale_segment(1)


@app.post("/segment/down")
def segment_down():
    return scale_segment(0)


@app.post("/import/{acquisition_id}")
def parquet_to_label_studio(acquisition_id: str, prefix: str = None, write: bool = False):
    # Converts the Parquet predictions of an acquisition into a Label Studio
    # import payload (one task per image). Reads file by file with bounded
    # memory, so it scales to tens of thousands of images.
    #   - default     : streams the JSON array back in the response
    #   - ?write=true : writes it to MinIO and returns the resulting URI
    # By default it reads the acquisition layout; pass ?prefix= to read elsewhere.
    if prefix is None:
        prefix = f"data/acquisitions/{acquisition_id}/09_parquet/"
    s3 = s3_client()
    keys = list_parquet_keys(s3, BUCKET, prefix)
    if not keys:
        log.warning("import_empty acquisition=%s prefix=%s", acquisition_id, prefix)
        raise HTTPException(status_code=404, detail="no parquet found for this acquisition")

    json_bytes = iter_label_studio_json(iter_label_studio_tasks(s3, BUCKET, keys))

    if write:
        out_key = f"data/results/{acquisition_id}/label_studio_import.json"
        uri = stream_to_s3(s3, BUCKET, out_key, json_bytes)
        log.info("import_written acquisition=%s files=%d uri=%s", acquisition_id, len(keys), uri)
        return {"uri": uri, "files": len(keys)}

    log.info("import_stream acquisition=%s files=%d", acquisition_id, len(keys))
    return StreamingResponse(json_bytes, media_type="application/json")


#  Main --------------------------------------------------
def main():
    import uvicorn

    uvicorn.run(app, host=ADDRESS, port=PORT)


if __name__ == "__main__":
    main()
