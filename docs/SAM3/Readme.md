# Docker basique pour SAM3

## Prérequis

- Python 3.12
- PyTorch 2.7
- GPU compatible CUDA 12.6
- Compte GitHub avec accès à ghcr.io/nearai-interreg
- Compte HuggingFace avec accès au modèle SAM3 (gated model)

---

## Image Docker

### Choix de la base

Image de base : `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04`

Ubuntu est préféré à Alpine car les drivers NVIDIA et les dépendances système (python3.12-venv, etc.) sont stables et officiellement supportés. Alpine poserait des problèmes de compatibilité avec les libs CUDA.

Un virtualenv Python est créé dans `/opt/venv` pour éviter les conflits avec pip Debian (qui bloque les installs globales depuis Ubuntu 24.04).

SAM3 est installé en mode non-éditable (`pip install ".[notebooks,train,dev]"` sans `-e`)  le mode éditable causait une erreur `NoneType` dans `pkg_resources` car `__file__` n'était pas résolu correctement.

### Build & Push

```bash
cd tests/

# Build
docker build -t ghcr.io/nearai-interreg/sam3-test:latest .

# Login au registry GitHub
echo $GH_TOKEN | docker login ghcr.io -u <github-username> --password-stdin

# Push
docker push ghcr.io/nearai-interreg/sam3-test:latest
```

---

## Déploiement sur K8s

### 1. Créer les secrets (une seule fois)

**Secret HuggingFace**  pour télécharger les poids SAM3 :

```bash
kubectl create secret generic hf-secret \
  --from-literal=HF_TOKEN=<ton_token_hf> \
  -n dani
```

**Secret GitHub Container Registry**  pour puller l'image privée :

```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<GH_TOKEN> \
  -n dani
```

### 2. Appliquer le pod

```bash
kubectl apply -f deploy/k8s/pod-sam3-test.yaml
```

### 3. Voir les logs

```bash
kubectl logs -f sam3-test -n dani
```

### 4. Nettoyer

```bash
kubectl delete pod sam3-test -n dani
```

> PS : Je recommande d'utiliser K9s pour manager les pods

---

## Anatomie du pod YAML

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sam3-test
  namespace: dani          # namespace attribué sur le cluster HEIG-VD
spec:
  restartPolicy: Never     # le pod s'arrête sans redémarrer après la fin du script
  runtimeClassName: nvidia # OBLIGATOIRE pour que le container accède aux drivers NVIDIA
  imagePullSecrets:
    - name: ghcr-secret    # secret Docker pour puller l'image depuis ghcr.io
  containers:
    - name: sam3-test
      image: ghcr.io/nearai-interreg/sam3-test:latest
      imagePullPolicy: Always  # force le pull à chaque déploiement (pas de cache stale)
      resources:
        limits:
          nvidia.com/gpu: '1'  # réserve 1 GPU sur le noeud  obligatoire pour CUDA
        requests:
          nvidia.com/gpu: '1'
      env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-secret  # lit HF_TOKEN depuis le secret K8s (jamais en clair dans le YAML)
              key: HF_TOKEN
```

### Points clés pour fonctionnement le fichier .yaml

| Élément | Rôle |
|---|---|
| `namespace: dani` | Espace de noms attribué sur le cluster HEIG-VD |
| `restartPolicy: Never` | Pod de test one-shot, ne redémarre pas |
| `runtimeClassName: nvidia` | Active le runtime NVIDIA  sans ça le GPU n'est pas visible dans le container |
| `nvidia.com/gpu: '1'` | Demande 1 GPU au scheduler K8s (plugin device NVIDIA) |
| `imagePullSecrets` | Credentials pour accéder au registry privé ghcr.io |
| `secretKeyRef` | Injecte le token HF depuis un secret K8s, pas depuis le YAML |

---

## Problèmes rencontrés

### Classes inexistantes

| Import tenté | Résultat |
|---|---|
| `sam3.sam3_image_predictor.SAM3ImagePredictor` | Module introuvable |
| `SAM3InteractiveImagePredictor` | Crash : `Sam3Image` n'a pas d'attribut `image_size` |

### CPU non supporté

SAM3 hardcode `device="cuda"` dans `PositionEmbeddingSine` --> Le modèle crashe au chargement sans GPU.

### runtimeClassName: nvidia obligatoire

Sans ce champ, le pod se schedule sur un noeud GPU mais le driver n'est pas transmis au container.

### Mode éditable interdit

`pip install -e .` casse la résolution du tokenizer BPE (`TypeError: NoneType`). Utiliser `pip install ".[notebooks,train,dev]"` sans `-e`. Contrairement a ce qui est dit dans le repo de SAM3.

### Bonne classe

`Sam3Processor` dans `sam3.model.sam3_image_processor`  pas les classes SAM1/SAM2.

---

## API SAM3  résultat de l'exploration

Le package SAM3 n'expose pas de `SAM3ImagePredictor` au top-level. Le bon workflow est :

```python
from sam3.model_builder import build_sam3_image_model
from sam3.model.sam3_image_processor import Sam3Processor

model = build_sam3_image_model(device=device, load_from_HF=True, eval_mode=True)
processor = Sam3Processor(model)

state = processor.set_image(image_array)
# state contient : original_height, original_width, backbone_out

result = processor.add_geometric_prompt(box=[x1, y1, x2, y2], label=True, state=state)
# result contient : masks, scores, boxes, masks_logits, geometric_prompt, backbone_out
```

### Paramètres de `add_geometric_prompt`

| Paramètre | Type | Description |
|---|---|---|
| `box` | `List[int]` | Boîte englobante `[x1, y1, x2, y2]` en pixels |
| `label` | `bool` | `True` = inclure la zone, `False` = l'exclure |
| `state` | `Dict` | État retourné par `set_image` |

### Contenu du résultat

| Clé | Description |
|---|---|
| `masks` | Masques binaires segmentés |
| `scores` | Score de confiance pour chaque masque |
| `boxes` | Boîtes englobantes des masques |
| `masks_logits` | Logits bruts avant seuillage |

---

## Script de test (test_sam3.py)

Le script effectue dans l'ordre :

1. Lecture de `HF_TOKEN` depuis l'environnement et login HuggingFace
2. Détection GPU (`torch.cuda.is_available()`)
3. Chargement du modèle SAM3 tiny depuis HuggingFace (`load_from_HF=True`)
4. Création d'une image synthétique rouge 800x400 px
5. `set_image` → obtention du state (features extraites par le backbone)
6. `add_geometric_prompt` avec une boîte englobante centrale
7. Affichage des clés du résultat (masks, scores, boxes)

## Source
[repo de SAM3](https://github.com/facebookresearch/sam3)