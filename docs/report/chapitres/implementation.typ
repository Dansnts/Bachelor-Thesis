#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#import "@preview/fletcher:0.5.7" as fletcher: diagram, edge, node
#show: codly-init.with()


= Implémentation <implementation>

== Image Docker

La pipeline s'exécute dans une image Docker basée sur `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04`, publiée sur GitHub Container Registry (`ghcr.io/nearai-interreg/ray-sam3:latest`). Les couches principales sont installées dans cet ordre pour maximiser le cache Docker :

+ Python 3.12 dans un venv isolé (`/opt/venv`), évitant les conflits avec les paquets système.
+ PyTorch 2.7.0 compilé pour CUDA 12.6 (index `download.pytorch.org/whl/cu126`).
+ SAM3 cloné depuis le dépôt Meta (`github.com/facebookresearch/sam3`) et installé avec ses extras `notebooks,train,dev`.
+ Ray 2.54.0 avec les extras `data,train,serve,default` et les dépendances pipeline : `exif`, `Pillow`, `opencv-python-headless`, `numpy>=1.26,<2`, `boto3`, `scipy`, `pyarrow`.

== Pipeline Python

Le fichier `sam3_minio_pipeline.py` est le point d'entrée unique. Il supporte deux modes via l'argument `--local` :

- *Mode local* (`--local`) : `ray.init()` Ray s'initialise sur la machine locale. Le pod doit disposer d'un GPU. Utilisé pour les tests sur un Job K8s à GPU unique.
- *Mode cluster* (défaut) : `ray.init("ray://ray-cluster-head-svc:10001")` le driver se connecte au RayCluster via le protocole Ray Client et distribue les tâches aux workers distants.

L'Actor `SAM3Actor` est décoré avec `@ray.remote(num_gpus=1)`. Ray crée une instance d'Actor par GPU disponible dans le cluster et refuse d'en créer davantage si les ressources sont épuisées. Le modèle est chargé une seule fois dans `__init__` via HuggingFace Hub et réutilisé sur toutes les requêtes.

Un bug subtil a été identifié lors des tests en mode local : l'utilisation de `.options(num_gpus=0)` pour modifier l'allocation au moment de la création écrasait silencieusement la déclaration du décorateur et forçait `CUDA_VISIBLE_DEVICES=""`#footnote[Ray positionne `CUDA_VISIBLE_DEVICES` à une liste vide quand `num_gpus=0` est passé via `.options()`. Ce comportement est silencieux — aucune exception n'est levée, CUDA disparaît simplement.], rendant CUDA invisible au processus. L'erreur résultante était :

```
RuntimeError: No CUDA GPUs are available
```

La correction consiste à supprimer l'appel `.options()` et laisser le décorateur gérer l'allocation dans les deux modes.


Les coordonnées GPS sont extraites de l'EXIF de chaque image au moment du téléchargement, via la bibliothèque `exif`. Le format EXIF stocke les coordonnées en degrés/minutes/secondes (DMS) avec une référence cardinale. La conversion en degrés décimaux suit :

$ d_"decimal" = d + m/60 + s/3600 $

La référence cardinale (N/S, E/O) détermine le signe du résultat. Les images sans EXIF GPS stockent `null` dans les colonnes `latitude` et `longitude` du Parquet. Les erreurs de parsing EXIF sont silencieusement ignorées pour ne pas interrompre le traitement de l'image.



Le driver récupère la liste des clés S3 du préfixe d'entrée et la divise en batches de taille `--batch_size` (défaut : 4 images). Chaque batch est soumis à un worker disponible via `.process.remote(batch)`. Le driver attend tous les futurs avec `ray.get(futures)` avant de passer au batch suivant.

Ce schéma simple évite la surcharge d'un scheduling dynamique complexe. Le nombre de workers actifs est borné par le nombre de GPUs disponibles dans le cluster.


L'argument `--resume` filtre les images dont un fichier Parquet existe déjà à la destination. Avant de distribuer le travail, le driver appelle `list_objects_v2` sur le préfixe de sortie et construit un ensemble des clés déjà traitées. Ce mécanisme permet de reprendre un run interrompu sans retraiter les images déjà traitées.


À la fin de chaque exécution, la pipeline affiche un résumé sur stdout :

```
Done: 40 images, 2230 detections — 111.0s/image (total 4440s)
```

Ce résumé est capté par Alloy et transmis à Loki, permettant de vérifier le débit sans interroger les fichiers Parquet.

== Manifestes Kubernetes

Trois manifestes couvrent les scénarios de déploiement.

Le fichier `deploy/ray/rayCluster.yaml` : déclare le cluster Ray permanent avec 1 head (2 CPU, 4 Gi) et jusqu'à 3 workers GPU (1 GPU, 8 CPU, 32 Gi). Le `nodeAffinity` préfère les L40S (poids 100) aux A40 (poids 50). Les credentials MinIO (`minio-secret`) et le token HuggingFace (`hf-secret`) sont injectés via `secretKeyRef` dans le spec worker, pas dans le head, qui n'exécute aucune tâche GPU.

Pour lancer le job, le fichier `deploy/ray/job-sam3-driver.yaml` fait que un HEAD sans GPU se connecte au RayCluster et orchestre le traitement d'un préfixe S3. Il se termine dès que l'ensemble des images est traité. `ttlSecondsAfterFinished: 3600`#footnote[Sans ce champ, les Jobs terminés restent indéfiniment dans etcd et leurs pods en état `Completed` occupent des slots sur les nœuds. Après plusieurs runs, le cluster se retrouve saturé de pods zombies.] supprime le Job automatiquement après une heure.

Arguments typiques :

```yaml
args:
  - --s3_uri
  - s3://nearai/data/acquisitions/Samples/01_images/
  - --s3_output_uri
  - s3://nearai/dani/predictions/
  - --labels
  - sign,road_marking
  - --batch_size
  - "4"
  - --num_workers
  - "3"
```

Pour faire les tests le fichier `tests/RAY/job-sam3-ray-test.yaml` est utilisé pour valider la pipeline sans cluster Ray (`--local --num_workers 1`). Il monte le PVC HuggingFace à `/root/.cache/huggingface` et un volume `emptyDir` de 16 Gi en mémoire sur `/dev/shm` pour accélérer le partage de tenseurs entre les processus PyTorch.#footnote[Sans `medium: Memory`, `/dev/shm` est limité à 64 MB par défaut dans un conteneur Docker — PyTorch échoue immédiatement au premier transfert de tenseur entre processus avec `Bus error`.] `hostIPC: true`#footnote[Sans `hostIPC: true`, les segments de mémoire partagée POSIX créés par PyTorch ne sont pas visibles entre processus dans le pod — l'inférence multi-GPU s'arrête avec `RuntimeError: unable to open shared memory object`.] est activé pour permettre la communication inter-processus via la mémoire partagée du nœud.

Pour le cache des poids HuggingFace, `tests/RAY/pvc-hf-cache.yaml` crée un PVC Longhorn de 10 Gi en mode `ReadWriteOnce`. Monté sur le pod worker à `/root/.cache/huggingface`. Le volume reste lié entre les redéploiements, évitant le re-téléchargement des 3,3 GB du modèle SAM3 à chaque run.

== Cache Modèle

=== Tuilage 1008 × 769

=== Tuilage 512 × 512

=== Tuilage 1024 × 1024

== Conversion vers Label Studio

Les fichiers Parquet produits par la pipeline sont convertis en JSON Label Studio pour l'import de pré-annotations. Le format attendu par Label Studio est :

```json
[{
  "data": {
    "image": "s3://nearai/data/acquisitions/.../image.jpg"
  },
  "predictions": [{
    "model_version": "SAM3",
    "result": [{
      "type": "polygonlabels",
      "from_name": "label",
      "to_name": "image",
      "original_width": 8192,
      "original_height": 4096,
      "value": {
        "closed": true,
        "polygonlabels": ["sign"],
        "points": [[42.05, 40.72], ...]
      }
    }]
  }]
}]
```

Deux contraintes sont critiques :
- Le tableau de tâches doit être encapsulé dans un objet racine de type liste (pas un objet seul).
- `from_name` doit correspondre exactement au `name` du tag `<PolygonLabels>` dans l'interface XML du projet Label Studio. Toute divergence provoque un import silencieusement invalide (polygones gris).

La prochaine étape est d'automatiser cette conversion et l'appel à l'API REST Label Studio directement depuis la pipeline, conformément à la section 6.4 du cahier des charges.

== API


