import argparse
import os
import uuid
from typing import List

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
        "--tileSize",
        str(req.tileSize),
        "--tileStride",
        str(req.tileStride),
        "--labels",
    ] + req.labels

    return buildJob(name, SOLO_IMAGE, argList)


@app.get("/jobs/{name}")
def get_job(name: str):
    pass


@app.post("/import/{aquisitionId}")
def parquetToLabelStudio(aquisitionID: int):
    pass


# Main
def main():
    import uvicorn

    uvicorn.run(app, host=ADDRESS, port=PORT)


if __name__ == "__main__":
    main()
