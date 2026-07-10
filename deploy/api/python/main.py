import argparse
import io
import json
import logging
import os
import time
import uuid
from typing import List, Optional

import requests
from botocore.exceptions import BotoCoreError, ClientError
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import (
    FileResponse,
    JSONResponse,
    RedirectResponse,
    StreamingResponse,
)
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
    """Body of POST /jobs/batch: one segmentation run over an S3 prefix.

    Attributes:
        s3Uri: prefix (or s3:// URI) of the images to segment.
        s3Uris: explicit list of full s3://bucket/key image URLs, as an
            alternative to s3Uri; exactly one of the two must be provided.
            The scheme is mandatory so a future https:// source can be added
            explicitly. The images can live in any bucket; the results still
            land under a single output prefix.
        s3OutputUri: where to write the Parquet results; derived from s3Uri (or the first of s3Uris) when omitted (see default_output_prefix).
        s3Bucket: bucket holding the images and receiving the results.
        labels: text labels the model looks for.
        numWorkers: number of parallel GPU actors on the RayCluster.
        batchSize: images sent to a worker at once.
        tileSize: side of the square tiles the images are cut into.
        tileStride: tile step; a stride < tileSize overlaps tiles so an object split across a cut is still analysed whole.
        downsample: shrink factor applied before tiling (1.0 = full resolution).
    """

    s3Uri: Optional[str] = None
    s3Uris: Optional[List[str]] = None
    s3OutputUri: Optional[str] = None
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
    """Body of POST /jobs/solo: run the pipeline on a single image.

    Attributes:
        imageUri: S3 key (or s3:// URI) of the image to segment.
        s3Bucket: bucket holding the image.
        labels: text labels the model looks for.
        tileSize: side of the square tiles the image is cut into.
        tileStride: tile step; a stride < tileSize overlaps tiles so an object split across a cut is still analysed whole.
        downsample: shrink factor applied before tiling (1.0 = full resolution).
    """

    imageUri: str
    s3Bucket: str
    labels: List[str]
    tileSize: int = 1008
    tileStride: int = 768
    downsample: float = 1.0


class SegmentItem(BaseModel):
    """One interactive prompt for the segment service with a labelled click.

    Attributes:
        point: [x, y] pixel coordinates of the click on the image.
        label: label to assign to the object under that point.
    """

    point: List[int]  # [x, y]
    label: str


class SegmentRequest(BaseModel):
    """Body of POST /segment: interactive segmentation from clicks.

    Attributes:
        url: S3 key of the image to segment.
        items: the labelled clicks driving the segmentation.
    """

    url: str  # S3 key of the image
    items: List[SegmentItem]


# Logging --------------------------------------------------
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s level=%(levelname)s logger=%(name)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("nearapi")

app = FastAPI(
    title="NearAI API",
    version="1.0",
    description="Pilotage de la pipeline d'annotation SAM3 : jobs batch et solo, "
    "segmentation interactive, import Label Studio. Console web sur /ui.",
)


@app.middleware("http")
async def log_requests(request, call_next):
    """Emit one structured log line per HTTP request.

    Logs method, path, status and duration for every call so it is traceable.
    An unhandled error is logged as a 500 with its traceback before re-raising.
    """
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
_s3_client = None


def s3_client():
    # Built once and reused: creating a boto3 client loads the botocore
    # service models (expensive in CPU and memory), and the console polls
    # /jobs/{name}/status for every batch — one client per request pinned
    # the pod at its CPU limit. boto3 clients are thread-safe.
    global _s3_client
    if _s3_client is not None:
        return _s3_client

    import boto3
    import urllib3
    from botocore.client import Config

    # Silence the per-request InsecureRequestWarning that would flood the logs.
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    _s3_client = boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(
            connect_timeout=5,
            read_timeout=10,
            retries={"max_attempts": 1},
            max_pool_connections=32,  # parallel /import reads share the client
        ),
        verify=False,  # We deactivate SSL verification here, we should enable it for security measures only when we are running with a non auto signed certificate
    )
    return _s3_client


def to_s3_uri(bucket, path):
    # the pipeline expects an s3://bucket/prefix URI. We accept both.
    if path.startswith("s3://"):
        return path

    return f"s3://{bucket}/{path.lstrip('/')}"


def require_s3_url(url):
    """Validate one full s3://bucket/key image URL, or raise a 422.

    Explicit image lists demand the scheme: a bare key would be ambiguous,
    and a future https:// source (downloading straight from the image
    provider) must be added explicitly, not guessed from the path.

        Attributes:
            url : one image URL from the request's s3Uris list
    """
    if not url.startswith("s3://"):
        raise HTTPException(
            status_code=422,
            detail="unsupported URL '%s': only s3:// is handled for now" % url,
        )
    bucket, _, key = url[5:].partition("/")
    if not bucket or not key:
        raise HTTPException(
            status_code=422, detail="expected s3://bucket/key, got '%s'" % url
        )
    return url


def default_output_prefix(s3_uri):
    """Creates the full path for the output folder.

    Each parquet file should be organized with his metadata and JSON parameters, so we create an universal rule to store our output.
    We simply take our uri, stripe the end of the path and add /09_Pipeline_result/ to it.

        Attributes:
            s3_uri :  base uri of the s3 of the folder

    """
    # Results location derived from the images prefix when the caller does not
    # pass s3OutputUri: everything up to the acquisition folder, then
    # 09_Pipeline_result/. Works whether s3_uri is .../<acq>/01_images/ or just
    # .../<acq>/, and whether it is a plain prefix or a full s3:// URI.
    path = s3_uri

    if path.startswith("s3://"):
        rest = path[len("s3://") :]
        path = rest.split("/", 1)[1] if "/" in rest else ""

    path = path.strip("/")
    acq_root = path.split("/01_images", 1)[0] if "/01_images" in path else path

    return acq_root + "/09_Pipeline_result/"


def list_parquet_keys(s3, bucket, prefix):
    keys = []
    paginator = s3.get_paginator("list_objects_v2")

    # Lists every .parquet object under the prefix.
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
    """Uploads a stream of bytes to S3 without holding it all in memory.

    Feeds the byte chunks into a multipart upload (parts of >= 5 MiB), so a
    large import (tens of thousands of images, >1 GB of JSON) never sits whole
    in memory. On any error the multipart upload is aborted before re-raising,
    so a failed write leaves no orphan parts behind.

        Attributes:
            s3        : the boto3 S3 client
            bucket    : destination bucket
            key       : destination object key
            byte_iter : iterable yielding the body as byte chunks

    Returns the s3:// URI of the written object.

    Function fully made with Claude Code.
    """
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
                    Bucket=bucket,
                    Key=key,
                    PartNumber=part_no,
                    UploadId=upload_id,
                    Body=bytes(buf),
                )
                parts.append({"ETag": r["ETag"], "PartNumber": part_no})
                part_no += 1
                buf = bytearray()
        # last part (any size), or an empty body if there was nothing buffered
        if buf or not parts:
            r = s3.upload_part(
                Bucket=bucket,
                Key=key,
                PartNumber=part_no,
                UploadId=upload_id,
                Body=bytes(buf),
            )
            parts.append({"ETag": r["ETag"], "PartNumber": part_no})
        s3.complete_multipart_upload(
            Bucket=bucket,
            Key=key,
            UploadId=upload_id,
            MultipartUpload={"Parts": parts},
        )
    except Exception:
        s3.abort_multipart_upload(Bucket=bucket, Key=key, UploadId=upload_id)
        raise

    return to_s3_uri(bucket, key)


# K8S API --------------------------------------------------
def build_job(name, image, command, args, gpu=True, access_key_env="AWS_ACCESS_KEY"):
    """Build and submit a Kubernetes Job.

    The single path every run goes through (batch driver and solo inference):
    injects the MinIO/HF secrets as env, sizes the pod (GPU worker vs CPU-only
    driver), pins GPU pods to the capable nodes and keeps finished pods 48h for
    their logs.

    Arguments :
    name                 job name, also its pod label prefix
    image                container image to run
    command              container entrypoint (argv list)
    args                 arguments passed to the entrypoint
    gpu                  True for a GPU inference pod, False for the CPU driver
    access_key_env       env var name receiving the MinIO access key

    Returns the {job_name, status} handle, or raises HTTPException carrying the Kubernetes API error.
    """
    # Environnement Variables
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
        # Place the GPU pod on suchet (L40S) or node4 (A40) only.
        # Chasseron (L4) causes too many issues (weaker card, disk-pressure evictions).
        pod_spec.affinity = client.V1Affinity(
            node_affinity=client.V1NodeAffinity(
                required_during_scheduling_ignored_during_execution=client.V1NodeSelector(
                    node_selector_terms=[
                        client.V1NodeSelectorTerm(
                            match_expressions=[
                                client.V1NodeSelectorRequirement(
                                    key="kubernetes.io/hostname",
                                    operator="In",
                                    values=["iict-suchet", "iict-k8s-node4-rad"],
                                )
                            ]
                        )
                    ]
                )
            )
        )

    # Job Creation
    job = client.V1Job(
        api_version="batch/v1",
        kind="Job",
        metadata=client.V1ObjectMeta(name=name, namespace=NAMESPACE),
        spec=client.V1JobSpec(
            ttl_seconds_after_finished=172800,  # garde les pods (logs, Done:) 48h après la fin de vie
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(labels={"app": name.rsplit("-", 1)[0]}),
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
    """Scale the on-demand segment deployment.

    Backs /segment/up and /segment/down so the GPU service only runs while
    someone is annotating interactively.

    Arguments :
        replicas             target replica count (0 = asleep, 1 = awake)
    """
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
    # Groups the polygon rows by image and builds one Label Studio task per image (predictions = every polygon detected on that image).
    # Points are already stored as percentages, so they map straight onto the image.
    tasks = {}

    for r in rows:
        key = r["image_key"]
        task = tasks.get(key)

        if task is None:
            # lat/lon are per-image (same on every row of that image), so we set
            # them once when the task is created; they travel to Label Studio in
            # the task data alongside the image URI.
            task = {
                "data": {
                    "image": to_s3_uri(bucket, key),
                    "latitude": r.get("latitude"),
                    "longitude": r.get("longitude"),
                },
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

    # 4 keys queued per thread: over-subscribe so no thread idles at a chunk boundary while a slow S3 read finishes (pool.map buffers <= batch results).
    batch = workers * 4

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for i in range(0, len(keys), batch):
            chunk = keys[i : i + batch]
            for rows in pool.map(lambda k: read_parquet_file(s3, bucket, k), chunk):
                for task in rows_to_label_studio(bucket, rows):
                    yield task


def iter_label_studio_json(task_iter):
    # Frames the streamed tasks as a single JSON array, without building it all in memory.
    # Yields bytes so it feeds both StreamingResponse and S3 upload.
    yield b"["
    first = True
    for task in task_iter:
        yield (b"" if first else b",") + json.dumps(task).encode()
        first = False
    yield b"]"


# Endpoints --------------------------------------------------
@app.get("/")
async def root(request: Request):
    # A browser landing on the bare API URL is sent to the console (which
    # links the OpenAPI doc); API clients keep getting the JSON banner.
    if "text/html" in request.headers.get("accept", ""):
        return RedirectResponse("/ui")
    return {"message": "NearAPI is running."}


@app.get("/ui")
def ui():
    # Control panel for demos: a single self-contained page served by the API
    # itself, so the browser talks to the same origin (no CORS to configure).
    return FileResponse(os.path.join(os.path.dirname(__file__), "index.html"))


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
    # Creates a new batch job
    if bool(req.s3Uri) == bool(req.s3Uris):
        raise HTTPException(
            status_code=422, detail="exactly one of s3Uri or s3Uris is required"
        )

    name = f"sam3-batch-{uuid.uuid4().hex[:8]}"

    if req.s3Uris:
        urls = [require_s3_url(u) for u in req.s3Uris]
        input_args = ["--s3_uris", ",".join(urls)]
        input_log = "%d explicit urls" % len(urls)
        # no common prefix on an explicit list: derive from the first image
        base_output = req.s3OutputUri or default_output_prefix(
            urls[0].rsplit("/", 1)[0] + "/"
        )
    else:
        input_uri = to_s3_uri(req.s3Bucket, req.s3Uri)
        input_args = ["--s3_uri", input_uri]
        input_log = input_uri
        base_output = req.s3OutputUri or default_output_prefix(req.s3Uri)

    output_uri = to_s3_uri(
        req.s3Bucket, "%s%s/" % (base_output.rstrip("/") + "/", name)
    )
    log.info(
        "batch_submit job=%s input=%s workers=%d batch_size=%d tile=%d downsample=%.2f labels=%d",
        name,
        input_log,
        req.numWorkers,
        req.batchSize,
        req.tileSize,
        req.downsample,
        len(req.labels),
    )

    arg_list = input_args + [
        "--s3_output_uri",
        output_uri,
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
    # Creates a new solo job
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
    """Return a single job's high-level state.

    One of Succeeded/Failed/Active/Pending. For a batch's fine-grained progress use /jobs/{name}/status instead.

    Arguments :
    name                 job name to read
    """

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
    except (ClientError, BotoCoreError) as e:
        log.error("status_read_failed job=%s error=%s", name, e)
        raise HTTPException(status_code=503, detail="storage unreachable")

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

    # no-store prevents the browser from serving a cached response on refresh
    return JSONResponse(content=data, headers={"Cache-Control": "no-store"})


@app.get("/jobs/{name}/result")
def get_result(name):
    """Return a solo job's result JSON from S3.

    404 until the job has written it, 503 if the storage is unreachable.

    Arguments :
    name                 solo job name whose result to fetch
    """

    key = f"results/{name}.json"
    s3 = s3_client()

    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
    except s3.exceptions.NoSuchKey:
        log.warning("result_not_found job=%s", name)
        raise HTTPException(status_code=404, detail="result not found")
    except (ClientError, BotoCoreError) as e:
        log.error("result_read_failed job=%s error=%s", name, e)
        raise HTTPException(status_code=503, detail="storage unreachable")

    return json.loads(obj["Body"].read())


@app.post("/segment")
def segment(req: SegmentRequest):
    """Proxy an interactive segmentation to the segment service.

    The service must be awake (see /segment/up). Returns 502 if it is
    unreachable, otherwise forwards its status and body.

    Arguments :
    req                  the image key and the labelled clicks to segment
    """

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


@app.get("/segment/status")
def segment_status():
    """Return the segment deployment's state so the UI can display it.

    replicas is the wanted scale (0 = asleep), ready the pods actually
    serving; "démarrage" is the window where replicas > ready.
    """
    try:
        dep = apps_v1.read_namespaced_deployment(SEGMENT_DEPLOYMENT, NAMESPACE)
    except client.ApiException as e:
        log.error(
            "segment_status_failed deployment=%s reason=%s", SEGMENT_DEPLOYMENT, e.reason
        )
        raise HTTPException(status_code=e.status, detail=e.reason)

    replicas = dep.spec.replicas or 0
    ready = dep.status.ready_replicas or 0
    return {"deployment": SEGMENT_DEPLOYMENT, "replicas": replicas, "ready": ready}


@app.post("/segment/up")
def segment_up():
    return scale_segment(1)


@app.post("/segment/down")
def segment_down():
    return scale_segment(0)


@app.post("/import/{acquisition_id}")
def parquet_to_label_studio(
    acquisition_id: str, run: str = None, prefix: str = None, write: bool = False
):
    if prefix is None:
        base = f"data/acquisitions/{acquisition_id}/09_Pipeline_result/"
        prefix = f"{base}{run}/" if run else base
    s3 = s3_client()
    try:
        keys = list_parquet_keys(s3, BUCKET, prefix)
    except (ClientError, BotoCoreError) as e:
        log.error("import_list_failed acquisition=%s error=%s", acquisition_id, e)
        raise HTTPException(status_code=503, detail="storage unreachable")
    if not keys:
        log.warning("import_empty acquisition=%s prefix=%s", acquisition_id, prefix)
        raise HTTPException(
            status_code=404, detail="no parquet found for this acquisition"
        )

    json_bytes = iter_label_studio_json(iter_label_studio_tasks(s3, BUCKET, keys))

    if write:
        out_key = f"data/results/{acquisition_id}/label_studio_import.json"
        try:
            uri = stream_to_s3(s3, BUCKET, out_key, json_bytes)
        except (ClientError, BotoCoreError) as e:
            log.error("import_write_failed acquisition=%s error=%s", acquisition_id, e)
            raise HTTPException(status_code=503, detail="storage unreachable")
        log.info(
            "import_written acquisition=%s files=%d uri=%s",
            acquisition_id,
            len(keys),
            uri,
        )
        return {"uri": uri, "files": len(keys)}

    log.info("import_stream acquisition=%s files=%d", acquisition_id, len(keys))
    return StreamingResponse(json_bytes, media_type="application/json")


#  Main --------------------------------------------------
def main():
    import uvicorn

    uvicorn.run(app, host=ADDRESS, port=PORT)


if __name__ == "__main__":
    main()
