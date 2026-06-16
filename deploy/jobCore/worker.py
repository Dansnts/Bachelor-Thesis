import logging
import os

import numpy as np
import torch

from jobCore.postprocess import mask_to_polygon, merge_masks
from jobCore.tiling import extract_tiles

CONF_THRESHOLD = 0.5
DEFAULT_TILE_SIZE = 1008
DEFAULT_TILE_STRIDE = 768
DEFAULT_BATCH_SIZE = 4

log = logging.getLogger(__name__)


class Sam3Model:
    """Charge SAM3 une fois et détecte des concepts (labels texte) sur une image.

    Indépendant de Ray et des entrées/sorties : on lui donne une image PIL et
    une liste de labels, il renvoie des polygones. Les modes solo et batch
    l'enveloppent chacun dans leur propre acteur Ray avec leur I/O.
    """

    def __init__(
        self,
        tile_size=DEFAULT_TILE_SIZE,
        tile_stride=DEFAULT_TILE_STRIDE,
        batch_size=DEFAULT_BATCH_SIZE,
    ):
        from huggingface_hub import login
        from sam3 import build_sam3_image_model
        from sam3.eval.postprocessors import PostProcessImage
        from sam3.train.transforms.basic_for_api import (
            ComposeAPI,
            NormalizeAPI,
            ToTensorAPI,
        )

        logging.basicConfig(level=logging.INFO)

        hf_token = os.getenv("HF_TOKEN")
        if hf_token:
            login(token=hf_token)

        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.tile_size = tile_size
        self.tile_stride = tile_stride
        self.batch_size = batch_size
        self._counter = 1

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
        log.info("Sam3Model prêt sur %s", self.device)

    def _make_datapoint(self, tile_image, labels):
        from sam3.train.data.sam3_image_dataset import (
            Datapoint,
            FindQueryLoaded,
            InferenceMetadata,
        )
        from sam3.train.data.sam3_image_dataset import Image as SAMImage

        pw, ph = tile_image.size
        dp = Datapoint(
            find_queries=[],
            images=[SAMImage(data=tile_image, objects=[], size=[ph, pw])],
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
        """image : PIL.Image. Renvoie (polygons, width, height) où
        polygons est une liste de (label, points, score)."""
        from sam3.model.utils.misc import copy_data_to_device
        from sam3.train.data.collator import collate_fn_api as collate

        image = image.convert("RGB")
        img_w, img_h = image.size

        # 1. découper l'image en tuiles
        tiles = extract_tiles(image, self.tile_size, self.tile_stride)

        # 2. emballer chaque tuile en Datapoint (image + labels)
        tile_data = []
        for tile_image, coords in tiles:
            dp, qmap = self._make_datapoint(tile_image, labels)
            tile_data.append((dp, coords, qmap))

        # 3. inférence batchée → liste de (mask, coords, score, label)
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

        # 4. regrouper par label puis recoller les tuiles
        label_groups = {}
        for mask, coords, score, label in detections:
            g = label_groups.setdefault(
                label, {"masks": [], "coords": [], "scores": []}
            )
            g["masks"].append(mask)
            g["coords"].append(coords)
            g["scores"].append(score)

        # 5. convertir chaque masque fusionné en polygone
        polygons = []
        for label, g in label_groups.items():
            for mask, score in merge_masks(
                g["masks"], g["coords"], img_w, img_h, g["scores"]
            ):
                points = mask_to_polygon(mask, img_w, img_h)
                if points:
                    polygons.append((label, points, float(score)))

        log.info("%d objets détectés sur %d tuiles", len(polygons), len(tiles))
        return polygons, img_w, img_h
