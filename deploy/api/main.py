import argparse
import json
import os
import uuid
from typing import List

import requests
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from kubernetes import client, config
from pydantic import (
    BaseModel,  # Pour faire de la validation / parsing de JSON. Pydantic permet de valider les types et convertir le JSON
)

try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()


load_dotenv()
app = FastAPI()

# Variables --------------------------------------------------
NAMESPACE = os.getenv("NAMESPACE", "dani")
S3_ENDPOINT = os.getenv(
    "S3_ENDPOINT_URL", "https://storage-kubernetes.iict-heig-vd.in:9000"
)
BATCH_IMAGE = os.getenv("BATCH_IMAGE", "ghcr.io/nearai-interreg/sam3-batch:latest")
SOLO_IMAGE = os.getenv("SOLO_IMAGE", "ghcr.io/nearai-interreg/sam3-solo:latest")
PORT = int(os.getenv("PORT", "8000"))
ADDRESS = os.getenv("V4_ADDRESS", "0.0.0.0")
BUCKET = os.getenv("BUCKET", "nearai")
SEGMENT_URL = os.getenv("SEGMENT_URL", "http://sam3-segment:8000")

batch_v1 = client.BatchV1Api()
core_v1 = client.CoreV1Api()


def s3Client():
    import boto3
    from botocore.client import Config

    return boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 1}),
        verify=False,
    )


# Classes --------------------------------------------------
class BatchRequest(BaseModel):
    s3Uri: str
    s3OutputUri: str
    s3Bucket: str
    labels: List[str]
    numWorkers: int
    batchSize: int  # Nombre d'images envoyées a un worker en une seule fois
    tileSize: int = 1008
    tileStride: int = 768  # Décalage entre les tiles, permet de chevaucher une image pour être sur l'avoir analyser une partie coupée


class SoloRequest(BaseModel):
    imageUri: str
    s3Bucket: str
    labels: List[str]
    tileSize: int = 1008
    tileStride: int = 768


class SegmentItem(BaseModel):
    point: List[int]  # [x, y]
    label: str


class SegmentRequest(BaseModel):
    url: str  # clé S3 de l'image
    items: List[SegmentItem]


# gpu=True : le pod réserve un GPU et tourne sous la runtime nvidia (cas solo, qui
#   fait tourner SAM3 dans son propre pod).
# gpu=False : driver CPU-only (cas batch) ; il se connecte au RayCluster et ce sont
#   les workers du cluster qui portent les GPUs, le driver n'en a pas besoin.
# accessKeyEnv : le pipeline batch lit AWS_ACCESS_KEY_ID, le job solo AWS_ACCESS_KEY.
def buildJob(name, image, command, args, gpu=True, accessKeyEnv="AWS_ACCESS_KEY"):
    env = [
        client.V1EnvVar(
            name=accessKeyEnv,
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
        # driver batch : juste de quoi orchestrer, le calcul est sur le RayCluster
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
            )  # Secret pour pull les images depuis le registre
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
            template=client.V1PodTemplateSpec(spec=pod_spec),
        ),
    )

    try:
        batch_v1.create_namespaced_job(NAMESPACE, job)
        return {"job_name": name, "status": "submitted"}
    except client.ApiException as e:
        raise HTTPException(status_code=e.status, detail=e.reason)


def toS3Uri(bucket, path):
    # le pipeline attend une URI s3://bucket/prefix. On accepte aussi bien un
    # préfixe simple ("data/...") qu'une URI déjà formée ("s3://bucket/...").
    if path.startswith("s3://"):
        return path
    return f"s3://{bucket}/{path.lstrip('/')}"


# Endpoints --------------------------------------------------
@app.get("/")
async def root():
    return {"message": "NearAPI is working."}


@app.post("/jobs/batch")
def submitBatch(req: BatchRequest):
    # Driver CPU-only : il se connecte au RayCluster et distribue les images du
    # préfixe S3 sur num_workers acteurs GPU. Réutilise le pipeline éprouvé
    # (même image que les workers Ray).
    name = f"sam3-batch-{uuid.uuid4().hex[:8]}"

    argList = [
        "--s3_uri",
        toS3Uri(req.s3Bucket, req.s3Uri),
        "--s3_output_uri",
        toS3Uri(req.s3Bucket, req.s3OutputUri),
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
    ]

    return buildJob(
        name,
        BATCH_IMAGE,
        ["python3.12", "/app/main.py"],
        argList,
        gpu=False,
        accessKeyEnv="AWS_ACCESS_KEY_ID",
    )


@app.post("/jobs/solo")
def submitSolo(req: SoloRequest):

    name = f"sam3-solo-{uuid.uuid4().hex[:8]}"

    argList = [
        "--imageUri",
        req.imageUri,
        "--bucket",
        req.s3Bucket,
        "--resultKey",
        f"results/{name}.json",
        "--tileSize",
        str(req.tileSize),
        "--tileStride",
        str(req.tileStride),
        "--labels",
    ] + req.labels

    return buildJob(name, SOLO_IMAGE, ["python3", "/app/main.py"], argList)


@app.get("/jobs/")
def get_jobs(name: str):

    pass


@app.get("/jobs/{name}")
def get_job(name: str):
    try:
        job = batch_v1.read_namespaced_job(name, NAMESPACE)
    except client.ApiException as e:
        raise HTTPException(status_code=e.status, detail=e.reason)

    s = job.status
    if s.succeeded:
        status = "Succeeded"
    elif s.failed:
        status = "Failed"
    elif s.active:
        status = "Active"
    else:
        status = "Pending"

    return {"job_name": name, "status": status}


@app.get("/jobs/{name}/result")
def get_result(name):
    key = f"results/{name}.json"
    s3 = s3Client()
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
    except s3.exceptions.NoSuchKey:
        raise HTTPException(status_code=404, detail="result not found")

    return json.loads(obj["Body"].read())


@app.post("/segment")
def segment(req: SegmentRequest):
    try:
        resp = requests.post(
            f"{SEGMENT_URL}/segment", json=req.model_dump(), timeout=120
        )
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"segment service unreachable: {e}")

    if resp.status_code != 200:
        raise HTTPException(status_code=resp.status_code, detail=resp.text)
    return resp.json()


@app.post("/import/{aquisitionId}")
def parquetToLabelStudio(aquisitionID: int):
    pass


#  Main --------------------------------------------------
def main():
    import uvicorn

    uvicorn.run(app, host=ADDRESS, port=PORT)


if __name__ == "__main__":
    main()
