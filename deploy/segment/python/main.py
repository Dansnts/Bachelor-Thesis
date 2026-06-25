import io
import logging
import os
import threading
from contextlib import asynccontextmanager

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from jobCore.postprocess import mask_to_polygon
from jobCore.s3 import make_s3_client
from PIL import Image
from pydantic import BaseModel

load_dotenv()


# Variables --------------------------------------------------
SAM3_REPO = os.getenv("SAM3_REPO", "facebook/sam3")
SAM3_MODEL = os.getenv("SAM3_MODEL", "sam3.pt")
BUCKET = os.getenv("BUCKET", "nearai")

# A lock serialises the inferences (single GPU, model not guaranteed thread-safe).
model = None
model_lock = threading.Lock()


# Classes --------------------------------------------------
class SegmentItem(BaseModel):
    point: list[int]  # [x, y]
    label: str


class SegmentRequest(BaseModel):
    url: str  # S3 key of the image in the bucket
    items: list[SegmentItem]


# Logging --------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


# App --------------------------------------------------
@asynccontextmanager
async def lifespan(app):
    global model
    from huggingface_hub import hf_hub_download
    from ultralytics import SAM

    log.info("Downloading weights %s/%s from HuggingFace ...", SAM3_REPO, SAM3_MODEL)
    weights = hf_hub_download(
        repo_id=SAM3_REPO, filename=SAM3_MODEL, token=os.getenv("HF_TOKEN")
    )
    log.info("Loading model (%s) ...", weights)
    model = SAM(weights)
    log.info("Model loaded, service ready")
    yield


app = FastAPI(lifespan=lifespan)


# Helpers --------------------------------------------------
def get_image(bucket, key):
    obj = make_s3_client().get_object(Bucket=bucket, Key=key)
    return obj["Body"].read()


# Endpoints --------------------------------------------------
@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": model is not None}


@app.post("/segment")
def segment(req: SegmentRequest):
    image = Image.open(io.BytesIO(get_image(BUCKET, req.url))).convert("RGB")
    w, h = image.size

    results = []
    # Single lock for the whole batch: the model (1 GPU) processes points serially.
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
            points = mask_to_polygon(mask, w, h)
            results.append(
                {"label": item.label, "points": points, "found": bool(points)}
            )

    return {"results": results}
