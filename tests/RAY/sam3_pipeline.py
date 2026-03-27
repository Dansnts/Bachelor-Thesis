import os
import ray
import torch
import numpy as np
from PIL import Image
from exif import Image as ExifImage

RAY_HEAD = "ray://ray-head-svc:10001"
TILE_SIZE = 512
NUM_WORKERS = 3


# ── EXIF ──────────────────────────────────────────────────────────────────────

def load_exif_gps(image_path: str) -> dict:
    with open(image_path, 'rb') as f:
        img = ExifImage(f)
    if not img.has_exif:
        return {}
    metadata = {}
    for tag in ["gps_altitude", "gps_img_direction", "datetime_original"]:
        val = img.get(tag)
        if val is not None:
            metadata[tag] = val
    for ref_tag, tag in [("gps_latitude_ref", "gps_latitude"), ("gps_longitude_ref", "gps_longitude")]:
        metadata[tag] = (img.get(ref_tag), img.get(tag))
    return metadata


# ── TILING ────────────────────────────────────────────────────────────────────

def split_tiles(image_array: np.ndarray, tile_size: int = TILE_SIZE):
    h, w = image_array.shape[:2]
    tiles = []
    for row in range(0, h, tile_size):
        for col in range(0, w, tile_size):
            tile = image_array[row:row + tile_size, col:col + tile_size]
            tiles.append((tile, row, col))
    return tiles


# ── ACTOR SAM3 ────────────────────────────────────────────────────────────────

@ray.remote
class SAM3Worker:
    def __init__(self):
        from huggingface_hub import login
        from sam3.model_builder import build_sam3_image_model
        from sam3.model.sam3_image_processor import Sam3Processor

        hf_token = os.environ.get("HF_TOKEN")
        if hf_token:
            login(token=hf_token)

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        print(f"[SAM3Worker] Loading model on {self.device}...")
        model = build_sam3_image_model(device=self.device, load_from_HF=True, eval_mode=True)
        self.processor = Sam3Processor(model)
        print(f"[SAM3Worker] Ready on {self.device}")

    def segment_tile(self, tile: np.ndarray, row: int, col: int) -> dict:
        h, w = tile.shape[:2]
        state = self.processor.set_image(tile)
        box = [0, 0, w, h]
        result = self.processor.add_geometric_prompt(box=box, label=True, state=state)
        return {
            "tile_row": row,
            "tile_col": col,
            "tile_h": h,
            "tile_w": w,
            "result": result,
        }


# ── MAIN ──────────────────────────────────────────────────────────────────────

def run(image_path: str):
    gps = load_exif_gps(image_path)
    print(f"[EXIF] GPS metadata: {gps}")

    image_array = np.array(Image.open(image_path).convert("RGB"))
    print(f"[INFO] Image shape: {image_array.shape}")

    tiles = split_tiles(image_array)
    print(f"[INFO] {len(tiles)} tiles ({TILE_SIZE}x{TILE_SIZE})")

    num_gpus = 0 if os.environ.get("RAY_LOCAL") == "1" else 1
    workers = [SAM3Worker.options(num_gpus=num_gpus).remote() for _ in range(NUM_WORKERS)]

    futures = [
        workers[i % NUM_WORKERS].segment_tile.remote(tile, row, col)
        for i, (tile, row, col) in enumerate(tiles)
    ]

    results = ray.get(futures)

    for r in results:
        print(f"  Tile ({r['tile_row']:4d}, {r['tile_col']:4d}) → {type(r['result']).__name__}")

    print(f"\n[SUCCES] {len(results)} tiles segmentées.")
    print(f"[INFO] GPS associé : {gps}")
    return results, gps


if __name__ == "__main__":
    image_path = os.environ.get("IMAGE_PATH", "../images/20251211-NeoCapture_S001_Trimblemx50_000001.jpg")
    local = os.environ.get("RAY_LOCAL", "0") == "1"

    if local:
        ray.init()
    else:
        ray.init(RAY_HEAD)

    print(f"[INFO] {len(ray.nodes())} nodes dans le cluster")

    run(image_path)

    ray.shutdown()
