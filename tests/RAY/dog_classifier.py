import os
import ray
import torch
from torchvision.models import efficientnet_b0, EfficientNet_B0_Weights
from datasets import load_dataset
from huggingface_hub import login
from PIL import Image

hf_token = os.environ.get("HF_TOKEN")
if not hf_token:
    raise RuntimeError("HF_TOKEN non défini.")
login(token=hf_token)
print("[OK] Authentification HuggingFace réussie")

ray.init("ray://ray-head-svc:10001")
print(f"[INFO] Nodes dans le cluster : {len(ray.nodes())}")

# -- Actor : le modèle est chargé UNE SEULE FOIS par worker
@ray.remote(num_gpus=1)
class Classifier:
    def __init__(self):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.weights = EfficientNet_B0_Weights.IMAGENET1K_V1
        self.model = efficientnet_b0(weights=self.weights).to(self.device)
        self.model.eval()
        self.transform = self.weights.transforms()
        self.labels = self.weights.meta["categories"]
        print(f"[OK] Modèle chargé sur {self.device}")

    def classify(self, image: Image.Image) -> dict:
        with torch.no_grad():
            tensor = self.transform(image).unsqueeze(0).to(self.device)
            output = self.model(tensor)
            probs = torch.softmax(output, dim=1)
            top3 = torch.topk(probs, 3)
        return [
            {"label": self.labels[idx], "score": round(probs[0][idx].item(), 4)}
            for idx in top3.indices[0]
        ]

# -- Dataset
print("Chargement du dataset...")
dataset = load_dataset("amaye15/stanford-dogs", split="test[:5000]")
images = [item["pixel_values"].convert("RGB") for item in dataset]
print(f"[OK] {len(images)} images chargées")

# -- 1 actor par worker (3 workers GPU)
classifiers = [Classifier.remote() for _ in range(3)]

# -- Distribution par batches de 100 pour éviter de saturer le client Ray
BATCH_SIZE = 100
all_results = []

print(f"Lancement de la classification distribuée ({len(images)} images, batches de {BATCH_SIZE})...")
for batch_start in range(0, len(images), BATCH_SIZE):
    batch = images[batch_start:batch_start + BATCH_SIZE]
    futures = [
        classifiers[i % len(classifiers)].classify.remote(img)
        for i, img in enumerate(batch)
    ]
    all_results.extend(ray.get(futures))
    print(f"  [{batch_start + len(batch)}/{len(images)}] traités")

# -- Affichage top 10
print("\nTop 10 premières images :")
for i, preds in enumerate(all_results[:10]):
    top = preds[0]
    print(f"  Image {i+1:02d} : {top['label']:<40} ({top['score']:.2%})")

print(f"\n[SUCCES] {len(all_results)} images classifiées.")
ray.shutdown()
