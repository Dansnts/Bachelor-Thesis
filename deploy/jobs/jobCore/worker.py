import logging
import os
import time

import numpy as np
import torch

from jobCore.postprocess import mask_to_polygon, merge_masks
from jobCore.tiling import extract_tiles

# Variables --------------------------------------------------
CONF_THRESHOLD = 0.5
# SAM3's backbone is locked to a 1008x1008 input (its RoPE positional encoding
# is precomputed for that grid and never rebuilt). Every tile is resized to this
# size before inference, which lets us tile at any size (cf. _make_datapoint).
MODEL_INPUT_SIZE = 1008
DEFAULT_TILE_SIZE = 1008
DEFAULT_TILE_STRIDE = 768
DEFAULT_BATCH_SIZE = 4
DEFAULT_DOWNSAMPLE = 1.0


# Logging --------------------------------------------------
log = logging.getLogger(__name__)


def configure_logging():
    """Attach an INFO StreamHandler to the jobCore logger.

    Ray configures the root logger inside its worker processes, which makes
    logging.basicConfig() a no-op there: our log.info() calls would be dropped.
    We set up the jobCore logger explicitly so the actor logs reach stderr,
    captured by Ray (worker logs + driver) and forwarded to Loki by Alloy.
    Idempotent: safe to call from every actor __init__.
    """
    logger = logging.getLogger("jobCore")
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(
            logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
        )
        logger.addHandler(handler)
        logger.propagate = False


# Classes --------------------------------------------------
class Sam3Model:
    """Loads SAM3 once and detects concepts (text labels) on an image.

    Independent of Ray and of I/O: given a PIL image and a list of labels, it
    returns polygons. The solo and batch modes each wrap it in their own Ray
    actor with their own I/O.
    """

    def __init__(
        self,
        tile_size=DEFAULT_TILE_SIZE,
        tile_stride=DEFAULT_TILE_STRIDE,
        batch_size=DEFAULT_BATCH_SIZE,
        downsample=DEFAULT_DOWNSAMPLE,
    ):
        from huggingface_hub import login
        from sam3 import build_sam3_image_model
        from sam3.eval.postprocessors import PostProcessImage
        from sam3.train.transforms.basic_for_api import (
            ComposeAPI,
            NormalizeAPI,
            ToTensorAPI,
        )

        configure_logging()

        hf_token = os.getenv("HF_TOKEN")
        if hf_token:
            login(token=hf_token)

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.tile_size = tile_size
        self.tile_stride = tile_stride
        self.batch_size = batch_size
        self.downsample = downsample
        self._counter = 1

        log.info(
            "Loading SAM3 on %s (tile=%d stride=%d downsample=%.2f)",
            self.device, self.tile_size, self.tile_stride, self.downsample,
        )
        t_load = time.time()
        self.model = build_sam3_image_model(
            device=self.device,
            eval_mode=True,
            load_from_HF=True,
            enable_segmentation=True,
            enable_inst_interactivity=True,
        )

        self.transform = ComposeAPI(
            transforms=[
                ToTensorAPI(),
                NormalizeAPI(mean=[0.5, 0.5, 0.5], std=[0.5, 0.5, 0.5]),
            ]
        )

        self.postprocessor = PostProcessImage(
            max_dets_per_img=-1,
            iou_type="segm",
            use_original_sizes_box=True,
            use_original_sizes_mask=True,
            convert_mask_to_rle=False,
            detection_threshold=CONF_THRESHOLD,
            to_cpu=True,
        )
        log.info("Sam3Model ready on %s in %.1fs", self.device, time.time() - t_load)

    def _make_datapoint(self, tile_image, labels):
        from PIL import Image
        from sam3.train.data.sam3_image_dataset import (
            Datapoint,
            FindQueryLoaded,
            InferenceMetadata,
        )
        from sam3.train.data.sam3_image_dataset import Image as SAMImage

        # SAM3's backbone only accepts a 1008x1008 input: its RoPE positional
        # encoding is built once for that grid and is never rebuilt, so any other
        # tile size raises an assertion (cf. upstream "SAM3 does not support
        # custom inference resolutions"). We resize every tile to 1008 before
        # inference, like the official predictor, while keeping the real tile
        # size as original_size below. The postprocessor (use_original_sizes_mask)
        # then maps the predicted mask back to the tile, so the stitching stays
        # unchanged. This is what makes tile_size a free parameter again: a 1008
        # tile is a no-op resize, a smaller tile is upscaled (more detail per
        # object, more tiles), a larger one is downscaled (fewer, coarser tiles).
        pw, ph = tile_image.size
        model_image = tile_image.resize(
            (MODEL_INPUT_SIZE, MODEL_INPUT_SIZE), Image.BILINEAR
        )
        dp = Datapoint(
            find_queries=[],
            images=[
                SAMImage(
                    data=model_image,
                    objects=[],
                    size=[MODEL_INPUT_SIZE, MODEL_INPUT_SIZE],
                )
            ],
        )
        query_id_to_label = {}
        for label in labels:
            dp.find_queries.append(
                FindQueryLoaded(
                    query_text=label,
                    image_id=0,
                    object_ids_output=[],
                    is_exhaustive=True,
                    query_processing_order=0,
                    inference_metadata=InferenceMetadata(
                        coco_image_id=self._counter,
                        original_image_id=self._counter,
                        original_category_id=1,
                        original_size=[pw, ph],
                        object_id=0,
                        frame_index=0,
                    ),
                )
            )
            query_id_to_label[self._counter] = label
            self._counter += 1
        return self.transform(dp), query_id_to_label

    def infer(self, image, labels):
        """image: PIL.Image. Returns (polygons, width, height) where
        polygons is a list of (label, points, score)."""
        from sam3.model.utils.misc import copy_data_to_device
        from sam3.train.data.collator import collate_fn_api as collate

        from PIL import Image

        t_start = time.time()
        image = image.convert("RGB")
        original_w, original_h = image.size

        # optional downsampling: shrink the image before tiling to cut the
        # number of tiles (and inference time). Polygons are emitted as
        # percentages of the image size, so they map back onto the
        # full-resolution image without any rescaling. We keep the original
        # dimensions to report them to Label Studio.
        if self.downsample and self.downsample < 1.0:
            new_w = int(original_w * self.downsample)
            new_h = int(original_h * self.downsample)
            image = image.resize((new_w, new_h), Image.BILINEAR)
            log.info(
                "Downsampling %dx%d -> %dx%d (factor %.2f)",
                original_w, original_h, new_w, new_h, self.downsample,
            )

        img_w, img_h = image.size

        # 1. split the image into tiles
        tiles = extract_tiles(image, self.tile_size, self.tile_stride)
        log.info("Image %dx%d -> %d tiles", img_w, img_h, len(tiles))

        # 2. wrap each tile into a Datapoint (image + labels)
        tile_data = []
        for tile_image, coords in tiles:
            dp, qmap = self._make_datapoint(tile_image, labels)
            tile_data.append((dp, coords, qmap))

        # 3. batched inference -> list of (mask, coords, score, label)
        detections = []
        for i in range(0, len(tile_data), self.batch_size):
            batch = tile_data[i : i + self.batch_size]
            dps = [x[0] for x in batch]
            coords_list = [x[1] for x in batch]
            qmaps = [x[2] for x in batch]

            b = collate(dps, dict_key="dummy")["dummy"]
            b = copy_data_to_device(b, torch.device(self.device), non_blocking=True)

            with torch.inference_mode():
                with torch.autocast(
                    device_type="cuda" if "cuda" in self.device else "cpu",
                    dtype=torch.bfloat16,
                ):
                    output = self.model(b)

            results = self.postprocessor.process_results(output, b.find_metadatas)

            for coords, qmap in zip(coords_list, qmaps):
                for qid, label in qmap.items():
                    if qid not in results:
                        continue
                    for mask, score in zip(
                        results[qid].get("masks", []), results[qid].get("scores", [])
                    ):
                        s = float(score.float().cpu().numpy())
                        if s >= CONF_THRESHOLD:
                            m = (mask.float().cpu().numpy().squeeze() > 0.5).astype(
                                np.uint8
                            )
                            detections.append((m, coords, s, label))

        # 4. group by label then stitch the tiles back together
        label_groups = {}
        for mask, coords, score, label in detections:
            g = label_groups.setdefault(
                label, {"masks": [], "coords": [], "scores": []}
            )
            g["masks"].append(mask)
            g["coords"].append(coords)
            g["scores"].append(score)

        # 5. convert each merged mask into a polygon
        polygons = []
        for label, g in label_groups.items():
            for mask, score in merge_masks(
                g["masks"], g["coords"], img_w, img_h, g["scores"]
            ):
                points = mask_to_polygon(mask, img_w, img_h)
                if points:
                    polygons.append((label, points, float(score)))

        per_label = {}
        for lbl, _, _ in polygons:
            per_label[lbl] = per_label.get(lbl, 0) + 1
        scores = [s for _, _, s in polygons]
        if scores:
            score_stats = "score mean=%.3f min=%.3f max=%.3f" % (
                sum(scores) / len(scores), min(scores), max(scores),
            )
        else:
            score_stats = "score n/a"
        log.info(
            "%d polygons over %d tiles in %.1fs %s %s",
            len(polygons), len(tiles), time.time() - t_start, per_label or "{}", score_stats,
        )
        return polygons, original_w, original_h
