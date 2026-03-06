import os
import torch
import numpy as np
from huggingface_hub import login
from sam3.model_builder import build_sam3_image_model
from sam3.model.sam3_image_processor import Sam3Processor

# 1. Auth HuggingFace
hf_token = os.environ.get("HF_TOKEN")
if not hf_token:
    raise RuntimeError("HF_TOKEN non défini.")
login(token=hf_token)
print("[OK] Authentification HuggingFace réussie")

# 2. Device
device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"[OK] Device : {device}")

# 3. Chargement du modèle
print("Chargement du modèle SAM3 (tiny)...")
model = build_sam3_image_model(device=device, load_from_HF=True, eval_mode=True)
processor = Sam3Processor(model)
print("[OK] Modèle chargé")

# 4. Image synthétique rouge 800x400
image_array = np.zeros((400, 800, 3), dtype=np.uint8)
image_array[:, :, 0] = 200
print("[OK] Image de test créée : 800x400 px")

# 5. Set image -> retourne un state
state = processor.set_image(image_array)
print(f"[OK] Image définie")
if isinstance(state, dict):
    print(f"     State keys : {list(state.keys())}")

# 6. Prompt : boîte englobante [x1, y1, x2, y2]
box = [200, 100, 600, 300]
result = processor.add_geometric_prompt(box=box, label=True, state=state)
print(f"[OK] Prompt ajouté (box={box})")
print(f"     Type result : {type(result)}")
if isinstance(result, dict):
    print(f"     Keys result : {list(result.keys())}")
elif hasattr(result, '__len__'):
    print(f"     Len result : {len(result)}")

print("\n[SUCCES] SAM3 fonctionne correctement dans ce container.")
