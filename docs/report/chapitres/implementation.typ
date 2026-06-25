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

== Build multi-stage

L'image solo est construite en deux étapes. Le stage `builder` part de `nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04`, installe les outils de compilation (`python3.12-dev`, `git`, `wget`), crée un venv dans `/opt/venv` et y compile PyTorch, SAM3 et les dépendances. Le stage runtime ne récupère que le venv terminé via `COPY --from=builder /opt/venv /opt/venv` et laisse derrière lui les sources clonées, le cache `pip` et les en-têtes de développement.

Un piège est apparu lors de la première construction : le venv contient des liens symboliques vers le `python3.12` du système, absent d'une image vierge. Copier `/opt/venv` seul produit un venv cassé. La correction réinstalle `python3.12` (sans le paquet `-dev`) dans le stage runtime pour rétablir la cible des liens.

Le stage runtime conserve l'image `cuda-...-devel` plutôt qu'une variante `runtime` plus légère. PyTorch compile certains noyaux à la volée via Triton, qui invoque `ptxas` du toolkit CUDA. Une image `runtime` sans `ptxas` casse cette compilation au premier appel GPU. Le compromis échange quelques centaines de mégaoctets contre la garantie que la compilation JIT fonctionne en production.

== Conteneurs non-root

L'API tourne sous un utilisateur non privilégié. Le Dockerfile crée `appuser` (uid 1000) et bascule dessus via `USER appuser`, et le Deployment durcit la contrainte côté Kubernetes avec `runAsNonRoot: true` et `runAsUser: 1000`.

Le serveur écoute sur le port 8000, supérieur à 1024, donc liable sans privilège root. Les `pip install` restent exécutés en root car ils appartiennent à l'étape de build, avant le `USER appuser`.

Les images solo et segment restent en root. Elles écrivent le cache des poids HuggingFace dans `/root/.cache` et accèdent au GPU, deux opérations qui se compliquent sous un utilisateur restreint sans réel gain de sécurité pour des Jobs éphémères.

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

=== Maîtrise du volume de logs

Deux sources de pollution des logs ont été identifiées et neutralisées, sans quoi un run de production noierait les messages utiles.

La première est la progression. Journaliser une ligne par image produirait 21'819 lignes pour le run Vevey, illisible dans Loki. Le driver ne logge donc `Progress: X %` que lorsque le pourcentage entier change, soit au plus 100 lignes par run quelle que soit la taille du dataset. La comparaison se fait sur une variable `last_percent` réévaluée à chaque image complétée.

La seconde est le certificat auto-signé de MinIO. Les clients S3 se connectent avec `verify=False`, ce qui pousse `urllib3` à émettre un `InsecureRequestWarning` à _chaque_ requête HTTP. Avec plusieurs milliers de `GET`/`PUT` par run (téléchargement des images, écriture des Parquet), ce warning se répète à l'infini. Il est désactivé une fois pour toutes via `urllib3.disable_warnings(InsecureRequestWarning)` dans chaque fabrique de client S3 (driver, workers, API, segmentation).

== Manifestes Kubernetes

Trois manifestes couvrent les scénarios de déploiement.

Le fichier `deploy/ray/rayCluster.yaml` : déclare le cluster Ray permanent avec 1 head (2 CPU, 4 Gi) et jusqu'à 3 workers GPU (1 GPU, 8 CPU, 32 Gi). Le `nodeAffinity` préfère les L40S (poids 100) aux A40 (poids 50). Les credentials MinIO (`minio-secret`) et le token HuggingFace (`hf-secret`) sont injectés via `secretKeyRef` dans le spec worker, pas dans le head, qui n'exécute aucune tâche GPU.

Le lancement d'un run batch ne passe pas par un manifeste statique : l'API construit le Job Kubernetes à la volée (`build_job` assemble un `V1Job` soumis via `create_namespaced_job`). Le pod ainsi créé est un HEAD sans GPU qui se connecte au RayCluster et orchestre le traitement d'un préfixe S3, puis se termine dès que l'ensemble des images est traité. Le champ `ttlSecondsAfterFinished: 3600`#footnote[Sans ce champ, les Jobs terminés restent indéfiniment dans etcd et leurs pods en état `Completed` occupent des slots sur les nœuds. Après plusieurs runs, le cluster se retrouve saturé de pods zombies.] supprime le Job automatiquement après une heure.

L'API passe au driver des arguments de cette forme :

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

=== Kustomization.yaml

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

#pagebreak()
== API

Les parties communes entre `Solo` et `Batch` sont regroupées dans une libraire *jobCore* séparée en 4 fichiers.

*postprocess.py* : Recolle les masques produits tuile par tuile sur l'image entière (merge_masks), sépare les objets en composantes connexes, puis convertit chaque masque en polygone au format Label Studio (mask_to_polygon). PIL (Python Image Library) travaille avec un masque sur 8 bit (0 --> 255) la sortie attendue est binaire car un masque de segmentation répond, pour chaque pixel, à une question : ce pixel appartient-il à l'objet détecté (1 = oui) ou (0 = non) ?

*s3.py* : Ouvre une session s3 avec `boto3` pour être utilsée lors de la lecture/écriture sur le bucket.

*tiling.py* : Découpe l'image panoramique en tuiles carrées de taille fixe avec recouvrement (tile_stride), pour que SAM3 traite des morceaux assez petits et qu'un objet à cheval sur une bordure reste entier dans au moins une tuile. Complète les bords avec du noir pour garder des tuiles carrées.

*worker.py* : La classe Sam3Model charge le modèle SAM3 une seule fois, puis détecte sur une image les concepts décrits par des labels texte. Elle découpe l'image en tuiles (tling.py), lance l'inférence par batch sur GPU, recolle et vectorise les résultats (postprocess.py), et renvoie la liste des polygones (label, points, score). Indépendante de Ray et des I/O : Solo et Batch l'enveloppent chacun dans leur propre acteur Ray.

Le job *solo* traite une seule image. L'API crée un Job Kubernetes qui lance un pod à GPU unique tournant l'image `ghcr.io/nearai-interreg/sam3-solo:staging`. Le pod appelle `ray.init()` localement sans cluster Ray et instancie un `SoloWorker` (acteur `@ray.remote(num_gpus=1)`) qui charge SAM3 une fois et infère sur l'image transmise avec les paramètres de tuilage définis. Le résultat est toujours imprimé sur stdout au format JSON Label Studio. Si le pod reçoit l'argument `--result_key`, il l'écrit en plus sur le bucket S3 à la clé `results/<job>.json` — ce que fait systématiquement l'API. Cette clé est ensuite relue par l'endpoint `/jobs/{name}/result`.

Le job *batch* traite un préfixe S3 entier. L'API crée un Job Kubernetes qui lance un pod *sans GPU* tournant l'image `ghcr.io/nearai-interreg/ray-sam3:staging` la même que les workers du RayCluster. Ce pod n'est qu'un driver, càd  qu'il se connecte au RayCluster permanent (`ray://ray-cluster-head-svc:10001`), liste les images du préfixe d'entrée et les distribue sur `num_workers` acteurs GPU. Chaque worker écrit ses résultats en Parquet à l'URI de sortie. On transmet donc le bucket et le préfixe des images source, le préfixe de sortie des fichiers Parquet, les labels et le nombre de workers.

La fonction `buildJob` assemble un `V1Job` du SDK Python Kubernetes à partir des paramètres de la requête : un `V1Container` (image, commande, arguments, variables d'environnement, ressources) dans un `V1PodSpec`, lui-même dans le template du `V1Job`. Les paramètres variables (GPU ou non, nom de la variable de clé d'accès) sont passés en arguments pour mutualiser le code entre solo et batch.

Les secrets ne sont jamais inscrits dans l'image : les credentials MinIO (`minio-secret`) et le token HuggingFace (`hf-secret`) sont injectés à l'exécution via `secretKeyRef`, et `S3_ENDPOINT_URL` via une variable simple. Le pod tire l'image depuis le registre privé grâce à `imagePullSecrets: ghcr-secret`. Les Jobs à GPU déclarent `runtimeClassName: nvidia` et la ressource `nvidia.com/gpu`. Chaque Job utilise `restartPolicy: Never` et `ttlSecondsAfterFinished: 3600` pour disparaître une heure après sa fin.

`submitSolo` passe `--result_key results/<job>.json` au Job. Le solo, en fin de traitement, dépose son JSON à cette clé sur S3. L'endpoint `get_result` relit ensuite l'objet avec `boto3` (les credentials MinIO côté API proviennent du même `minio-secret`). Le résultat est ainsi durable et indépendant du TTL des Jobs et le pod peut être supprimé, le JSON reste lisible.

Deux frictions du client Python ont demandé un contournement.

La première, `read_namespaced_pod_log` renvoie le `repr()` d'un objet `bytes` (la chaîne littérale `b'...'`) sur `kubernetes-client` 36.x au lieu du texte décodé.

Exemple de output :
```text
b'Done: 40 images, 2230 detections\n'
```

Le contournement passe `_preload_content=False` puis décode manuellement via `.data.decode("utf-8")`.

Ensuite, `jobs/status` est une sous-ressource RBAC distincte de `jobs`. Appeler `read_namespaced_job_status` exige une permission séparée et échoue en `403` sans elle. La soution est de lire la ressource `jobs` complète avec `read_namespaced_job`, déjà autorisée, et on en extrait le champ statut. Ainsi on évite le fait de recréer un deuxième accès uniquement pour lire une information que on pouvait déja trouver ailleurs.


Pour la *segmentation à la volée*, un pod indépendant tourne et exploite une grande partie des librairies *jobCore*. L'unique différence est que nous expoitons la fonctionnalité de SAM3 pour la segmentation sur une zone spécifique :

```python
x, y = item.point
preds = model.predict(
    source=image, points=[[x, y]], labels=[1], verbose=False
)
```

On récupère les prédictions et ainsi nous pouvons vérifier si le label demandé aux cordonnées entrées est présent ou non afin de retourner le résultat. Contrairement aux jobs solo et batch, le service de segmentation n'écrit aucun fichier : le résultat est renvoyé directement dans la réponse HTTP de l'endpoint `/segment`.

La mise en veille et la reprise du pod se fait simplement via un autre appel de la librairie K8s en exploitant le principe de replicas :

```python
apps_v1.patch_namespaced_deployment_scale(
    name=SEGMENT_DEPLOYMENT,
    namespace=NAMESPACE,
    body={"spec": {"replicas": replicas}},
```

#linebreak()

`/segment/up` va faire un appel de la fonction avec la valeure *1* en paramètre, tandis que `/segment/down`, passe en paramètre *0*.

Finnalement, le service ne dispose que d'un GPU. Comme une seule inférence peut tourner à la fois, un `threading.Lock` met les appels en file et les traite l'un après l'autre. En pratique l'usage est séquentiel, un annotateur, une image à la fois, donc la file ne bloque jamais.

=== Ultralytics

Contrairement aux modes batch et solo, qui pilotent SAM3 via la librairie *jobCore* (tuilage, détection par concept, post-traitement), le service interactif s'appuie sur le wrapper `SAM` de la librairie Ultralytics. Celui-ci expose l'inférence par prompt visuel en un seul appel, sans le pipeline de tuilage inutile pour une prédiction ponctuelle.

Au démarrage du pod, les poids sont téléchargés depuis HuggingFace puis chargés une seule fois :

```python
from ultralytics import SAM
weights = hf_hub_download(repo_id="facebook/sam3", filename="sam3.pt")
model = SAM(weights)
```

Le fichier `sam3.pt` est le conteneur PyTorch des poids du modèle (3,3 GB). `SAM(weights)` reconstruit le réseau et le charge en VRAM ; l'objet reste chaud pour toute la session, évitant de repayer le chargement à chaque requête.

Le masque renvoyé par `predict` est ensuite reconverti en polygone par `mask_to_polygon`, seule fonction de *jobCore* réutilisée par le service :

```python
mask = preds[0].masks.data[0].cpu().numpy()
points = mask_to_polygon(mask, w, h)
```

Si SAM3 ne trouve aucun objet sous le point, `masks` est vide et le service renvoie `found: false` pour cet item. Le label fourni n'oriente pas la détection : il étiquette simplement le masque retourné.

== Observabilité

=== Déploiement de la stack (Prometheus, Loki, Alloy)

=== Métriques GPU (DCGM)

=== Dashboard Grafana
