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

batch_v1 = client.BatchV1Api()
core_v1 = client.CoreV1Api()

load_dotenv()
app = FastAPI()

# Variables
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


# Classes
class BatchRequest(BaseModel):
    s3Uri: str
    s3OutputUri: str
    s3Bucket: str
    labels: List[str]
    numWorkers: int
    batchSize: int  # Nombre d'images envoyées a un worker en une seule fois
    tileSize: int
    tileStride: int  # Décalage entre les tiles, permet de chevaucher une image pour être sur l'avoir analyser une partie coupée


class SoloRequest(BaseModel):
    imageUri: str
    s3Bucket: str
    labels: List[str]
    tileSize: int
    tileStride: int


class SegmentItem(BaseModel):
    point: List[int]  # [x, y]
    label: str


class SegmentRequest(BaseModel):
    url: str  # clé S3 de l'image
    items: List[SegmentItem]


def buildJob(name, image, args):
    env = [
        client.V1EnvVar(
            name="AWS_ACCESS_KEY",
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

    # Container
    container = client.V1Container(
        name=name,
        image=image,
        image_pull_policy="Always",
        command=["python3", "/app/main.py"],
        args=args,
        env=env,
        resources=client.V1ResourceRequirements(
            requests={"cpu": "4", "memory": "16Gi"},
            limits={"nvidia.com/gpu": "1", "cpu": "8", "memory": "32Gi"},
        ),
    )

    job = client.V1Job(
        api_version="batch/v1",
        kind="Job",
        metadata=client.V1ObjectMeta(name=name, namespace=NAMESPACE),
        spec=client.V1JobSpec(
            ttl_seconds_after_finished=3600,
            template=client.V1PodTemplateSpec(
                spec=client.V1PodSpec(
                    restart_policy="Never",
                    runtime_class_name="nvidia",
                    image_pull_secrets=[
                        client.V1LocalObjectReference(
                            name="ghcr-secret"
                        )  # Secret pour pull les images depuis le registre
                    ],
                    containers=[container],
                )
            ),
        ),
    )

    try:
        batch_v1.create_namespaced_job(NAMESPACE, job)
        return {"job_name": name, "status": "submitted"}
    except client.ApiException as e:
        raise HTTPException(status_code=e.status, detail=e.reason)


@app.get("/")
async def root():
    return {"message": "NearAPI is working."}


@app.post("/jobs/batch")
def submitBatch(req: BatchRequest):
    pass


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

    return buildJob(name, SOLO_IMAGE, argList)


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
    # L'API ne fait pas tourner le modèle (pas de GPU) : elle relaie la requête
    # vers le service interne sam3-segment (modèle chargé en permanence).
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


# Main
def main():
    import uvicorn

    uvicorn.run(app, host=ADDRESS, port=PORT)


if __name__ == "__main__":
    main()
