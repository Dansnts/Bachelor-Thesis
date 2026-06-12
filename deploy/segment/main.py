import io
import logging
import os
import threading
from contextlib import asynccontextmanager

import numpy as np
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from PIL import Image
from pydantic import BaseModel

load_dotenv()
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

SAM3_REPO = os.getenv("SAM3_REPO", "facebook/sam3")
SAM3_MODEL = os.getenv("SAM3_MODEL", "sam3.pt")
BUCKET = os.getenv("BUCKET", "nearai")

# Le modèle est chargé une seule fois au démarrage (cf. lifespan) et gardé
# en mémoire GPU. Un lock sérialise les inférences (un seul GPU, modèle non
# garanti thread-safe).
model = None
model_lock = threading.Lock()


def s3Client():
    import boto3
    from botocore.client import Config

    return boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(connect_timeout=5, read_timeout=30, retries={"max_attempts": 2}),
        verify=False,
    )


def getImage(bucket, key):
    obj = s3Client().get_object(Bucket=bucket, Key=key)
    return obj["Body"].read()


def maskToPolygon(mask, w, h):
    import cv2

    contours, _ = cv2.findContours(
        (mask > 0).astype(np.uint8) * 255, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )
    if not contours:
        return []
    contour = max(contours, key=cv2.contourArea)
    epsilon = 0.002 * cv2.arcLength(contour, True)
    simplified = cv2.approxPolyDP(contour, epsilon, True)
    if len(simplified) < 3:
        return []
    return [[p[0][0] * 100.0 / w, p[0][1] * 100.0 / h] for p in simplified]


@asynccontextmanager
async def lifespan(app):
    global model
    from huggingface_hub import hf_hub_download
    from ultralytics import SAM

    log.info("Téléchargement des poids %s/%s depuis HuggingFace ...", SAM3_REPO, SAM3_MODEL)
    weights = hf_hub_download(
        repo_id=SAM3_REPO, filename=SAM3_MODEL, token=os.getenv("HF_TOKEN")
    )
    log.info("Chargement du modèle (%s) ...", weights)
    model = SAM(weights)
    log.info("Modèle chargé, service prêt")
    yield


app = FastAPI(lifespan=lifespan)


class SegmentItem(BaseModel):
    point: list[int]  # [x, y]
    label: str


class SegmentRequest(BaseModel):
    url: str  # clé S3 de l'image dans le bucket
    items: list[SegmentItem]


@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": model is not None}


@app.post("/segment")
def segment(req: SegmentRequest):
    image = Image.open(io.BytesIO(getImage(BUCKET, req.url))).convert("RGB")
    w, h = image.size

    results = []
    # Un seul lock pour tout le lot : le modèle (1 GPU) traite les points en série.
    with model_lock:
        for item in req.items:
            x, y = item.point
            preds = model.predict(
                source=image, points=[[x, y]], labels=[1], verbose=False
            )
            masks = preds[0].masks
            if masks is None or len(masks.data) == 0:
                results.append({"label": item.label, "points": [], "found": False})
                continue
            mask = masks.data[0].cpu().numpy()
            points = maskToPolygon(mask, w, h)
            results.append(
                {"label": item.label, "points": points, "found": bool(points)}
            )

    return {"results": results}
