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

== Hardening

L'API tourne sous un utilisateur non privilégié. Le Dockerfile crée `appuser` (uid 1000) et bascule dessus via `USER appuser`, et le Deployment durcit la contrainte côté Kubernetes avec `runAsNonRoot: true` et `runAsUser: 1000`.

Le serveur écoute sur le port 8000, supérieur à 1024, donc liable sans privilège root. Les `pip install` restent exécutés en root car ils appartiennent à l'étape de build, avant le `USER appuser`.

Les images solo et segment restent en root. Elles écrivent le cache des poids HuggingFace dans `/root/.cache` et accèdent au GPU, deux opérations qui se compliquent sous un utilisateur restreint sans réel gain de sécurité pour des Jobs éphémères.

== Gestion des secrets

Quatre Secrets Kubernetes portent les credentials de la stack : `minio-secret` (clés d'accès S3), `hf-secret` (token HuggingFace, requis pour télécharger les 3,3 Go de poids SAM3), `ghcr-secret` (authentification `dockerconfigjson` pour tirer les images du registre privé) et `grafana-secret` (compte administrateur du dashboard).

Ces secrets posent un dilemme classique : les versionner en clair dans le dépôt est exclu, mais les garder hors du dépôt rend le déploiement non reproductible, car chaque nouvelle machine devrait les recréer à la main.

Le choix retenu est de les versionner *chiffrés* avec SOPS et age. La règle `encrypted_regex` de `.sops.yaml` ne chiffre que les valeurs sous `data`/`stringData` : le reste du manifeste (kind, metadata, clés) reste lisible, ce qui garde des diffs Git propres. On voit *quel* secret a changé sans jamais voir sa valeur. Un secret chiffré ressemble à ceci, sûr à versionner :

```yaml
stringData:
    access_key: ENC[AES256_GCM,data:DjC2SqT5...,type:str]
    secret_key: ENC[AES256_GCM,data:qduNJEEj...,type:str]
```

*AGE* est préféré à GPG pour sa simplicité : une seule paire de clés moderne, sans trousseau à administrer. La clé privée vit hors du dépôt (`~/.config/sops/age/keys.txt`). Seule la clé publique de chiffrement est commitée dans `.sops.yaml`. L'édition passe par `sops <fichier>`, qui déchiffre dans l'éditeur et rechiffre à la sauvegarde.

Au déploiement, `deploy.sh` applique d'abord chaque secret en le déchiffrant à la volée vers `kubectl`, sans jamais écrire la valeur en clair sur le disque, puis applique le reste de la stack :

```sh
sops -d deploy/secrets/minio-secret.enc.yaml | kubectl apply -f -
```

Les secrets sont volontairement exclus de la kustomization racine (décrite dans la section sur les manifestes Kubernetes) : un `kubectl apply -k deploy/` seul ne peut ni échouer sur un secret chiffré ni en publier un par accident. À la consommation, les pods reçoivent les valeurs par `secretKeyRef`, dans les workers Ray mais pas dans le head, qui n'exécute aucune tâche GPU, et `ghcr-secret` sert d'`imagePullSecret`. Côté API, la référence se déclare dans le `V1Job` construit dynamiquement. Le `kubelet` la résout au démarrage du pod :

```python
from kubernetes import client

env = [
    client.V1EnvVar(
        name="AWS_ACCESS_KEY",
        value_from=client.V1EnvVarSource(
            secret_key_ref=client.V1SecretKeySelector(
                name="minio-secret",
                key="access_key",
            )
        ),
    )
]
```

== Pipeline Python

Le fichier `sam3_minio_pipeline.py` est le point d'entrée unique. Il supporte deux modes via l'argument `--local` :

- *Mode local* (`--local`) : avec `ray.init()`, Ray s'initialise sur la machine locale. Le pod doit disposer d'un GPU. Utilisé pour les tests sur un Job K8s à GPU unique.
- *Mode cluster* (défaut) : avec `ray.init("ray://ray-cluster-head-svc:10001")`, le driver se connecte au RayCluster via le protocole Ray Client et distribue les tâches aux workers distants.

L'Actor `SAM3Actor` est décoré avec `@ray.remote(num_gpus=1)`. Ray crée une instance d'Actor par GPU disponible dans le cluster et refuse d'en créer davantage si les ressources sont épuisées. Le modèle est chargé une seule fois dans `__init__` via HuggingFace Hub et réutilisé sur toutes les requêtes.

Un bug subtil a été identifié lors des tests en mode local : l'utilisation de `.options(num_gpus=0)` pour modifier l'allocation au moment de la création écrasait silencieusement la déclaration du décorateur et forçait `CUDA_VISIBLE_DEVICES=""`#footnote[Ray positionne `CUDA_VISIBLE_DEVICES` à une liste vide quand `num_gpus=0` est passé via `.options()`. Ce comportement est silencieux : aucune exception n'est levée, CUDA disparaît simplement.], rendant CUDA invisible au processus. L'erreur résultante était :

```
RuntimeError: No CUDA GPUs are available
```

La correction consiste à supprimer l'appel `.options()` et laisser le décorateur gérer l'allocation dans les deux modes.


Les coordonnées GPS proviennent en premier lieu du fichier de trajectoire de l'acquisition (cf. chapitre architecture). En secours, elles sont extraites de l'EXIF de l'image au moment du téléchargement, via la bibliothèque `exif`. Le format EXIF stocke les coordonnées en degrés/minutes/secondes (DMS) avec une référence cardinale. La conversion en degrés décimaux suit :

$ d_"decimal" = d + m/60 + s/3600 $

La référence cardinale (N/S, E/O) détermine le signe du résultat. Les images sans aucune source GPS (ni trajectoire ni EXIF) stockent `null` dans les colonnes `latitude` et `longitude` du Parquet. Les erreurs de parsing EXIF sont silencieusement ignorées pour ne pas interrompre le traitement de l'image.



Le driver récupère la liste des clés S3 du préfixe d'entrée et la divise en batches de taille `--batch_size` (défaut : 4 images). Chaque batch est soumis à un worker disponible via `.process.remote(batch)`. Le driver attend tous les futurs avec `ray.get(futures)` avant de passer au batch suivant.

Ce schéma simple évite la surcharge d'un scheduling dynamique complexe. Le nombre de workers actifs est borné par le nombre de GPUs disponibles dans le cluster.


L'argument `--resume` filtre les images dont un fichier Parquet existe déjà à la destination. Avant de distribuer le travail, le driver appelle `list_objects_v2` sur le préfixe de sortie et construit un ensemble des clés déjà traitées. Ce mécanisme permet de reprendre un run interrompu sans retraiter les images déjà écrites.


À la fin de chaque exécution, la pipeline affiche un résumé sur stdout :

```
Done: 40 images, 2230 detections - 111.0s/image (total 4440s)
```

Ce résumé est capté par Alloy et transmis à Loki, permettant de vérifier le débit sans interroger les fichiers Parquet.

== Gestion des logs

Deux sources de pollution des logs ont été identifiées et neutralisées, sans quoi un run de production noierait les messages utiles.

La première est la progression. Journaliser une ligne par image produirait 14'207 lignes pour le run Vevey, illisible dans Loki. Le driver ne logge donc `Progress: X %` que lorsque le pourcentage entier change, soit au plus 100 lignes par run quelle que soit la taille du dataset. La comparaison se fait sur une variable `last_percent` réévaluée à chaque image complétée.

La seconde est le certificat auto-signé de MinIO. Les clients S3 se connectent avec `verify=False`, ce qui pousse `urllib3` à émettre un `InsecureRequestWarning` à _chaque_ requête HTTP. Avec plusieurs milliers de `GET`/`PUT` par run (téléchargement des images, écriture des Parquet), ce warning se répète à l'infini. Il est désactivé une fois pour toutes via `urllib3.disable_warnings(InsecureRequestWarning)` dans chaque fabrique de client S3 (driver, workers, API, segmentation).

== Manifestes Kubernetes

Trois manifestes couvrent les scénarios de déploiement.

Le fichier `deploy/ray/rayCluster.yaml` déclare le cluster Ray permanent avec 1 head (2 CPU, 4 Gi) et jusqu'à 3 workers GPU (1 GPU, 8 CPU, 32 Gi). Le scheduling des workers est restreint aux deux nœuds GPU retenus, avec une préférence pour les L40S (poids 100) sur les A40 (poids 50) :

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
              - iict-suchet
              - iict-k8s-node4-rad
```
#linebreak()
Les credentials MinIO (`minio-secret`) et le token HuggingFace (`hf-secret`) sont injectés via `secretKeyRef` dans le spec worker, pas dans le head, qui n'exécute aucune tâche GPU :

```yaml
env:
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: minio-secret
        key: access-key
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-secret
        key: token
```
#linebreak()
Le lancement d'un run batch ne passe pas par un manifeste statique : l'API construit le Job Kubernetes à la volée (`build_job` assemble un `V1Job` soumis via `create_namespaced_job`). Le pod ainsi créé est un simple driver sans GPU qui se connecte au RayCluster et orchestre le traitement d'un préfixe S3, puis se termine dès que l'ensemble des images est traité. Le champ `ttlSecondsAfterFinished: 3600`#footnote[Sans ce champ, les Jobs terminés restent indéfiniment dans etcd et leurs pods en état `Completed` occupent des slots sur les nœuds. Après plusieurs runs, le cluster se retrouve saturé de pods zombies.] supprime le Job automatiquement après une heure.

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

Pour faire les tests, le fichier `tests/RAY/job-sam3-ray-test.yaml` est utilisé pour valider la pipeline sans cluster Ray (`--local --num_workers 1`). Il monte le PVC HuggingFace à `/root/.cache/huggingface` et un volume `emptyDir` de 16 Gi en mémoire sur `/dev/shm` pour accélérer le partage de tenseurs entre les processus PyTorch.#footnote[Sans `medium: Memory`, `/dev/shm` est limité à 64 MB par défaut dans un conteneur Docker : PyTorch échoue immédiatement au premier transfert de tenseur entre processus avec `Bus error`.] `hostIPC: true`#footnote[Sans `hostIPC: true`, les segments de mémoire partagée POSIX créés par PyTorch ne sont pas visibles entre processus dans le pod : l'inférence multi-GPU s'arrête avec `RuntimeError: unable to open shared memory object`.] est activé pour permettre la communication inter-processus via la mémoire partagée du nœud. Ce réglage élargit la surface d'isolation du pod en partageant l'espace de noms IPC du nœud hôte, un compromis de sécurité déconseillé sur un cluster mutualisé. Il reste circonscrit à ce manifeste de test local : le RayCluster de production ne le déclare pas, chaque Actor y tournant dans son propre pod sans ce besoin de mémoire partagée inter-processus. Ce fichier n'est référencé par aucune `kustomization.yaml`, il ne peut donc pas être appliqué par erreur via `kubectl apply -k deploy/`, seul un appel manuel et explicite (`kubectl apply -f tests/RAY/job-sam3-ray-test.yaml`) le déploie.

Pour le cache des poids HuggingFace, `tests/RAY/pvc-hf-cache.yaml` crée un PVC Longhorn de 10 Gi en mode `ReadWriteOnce`, monté sur le pod worker à `/root/.cache/huggingface`. Le PVC de production, partagé entre deux nœuds, est lui en `ReadWriteMany` (cf. chapitre architecture). Le volume reste lié entre les redéploiements, évitant le re-téléchargement des 3,3 Go du modèle SAM3 à chaque run.

Les manifestes sont organisés avec Kustomize (*kustomization.yaml*), intégré nativement à `kubectl`. Chaque composant (Ray, API, segmentation, observabilité) possède son dossier `manifests/` avec une `kustomization.yaml` qui liste ses ressources. Une kustomization racine (`deploy/kustomization.yaml`) les agrège, si bien que la stack complète se déploie en une commande : `kubectl apply -k deploy/`#footnote[Le drapeau `-k` est requis : `kubectl apply -f deploy/` ignorerait les fichiers `kustomization.yaml` et appliquerait les manifestes sans la composition (namespace, tags d'images).].

Cette organisation apporte trois choses. D'abord, le `namespace: dani` est fixé une seule fois à la racine : aucun manifeste individuel ne le mentionne, ce qui les rend réutilisables tels quels dans un autre namespace. Ensuite, le bloc `images:` de la racine centralise les tags des trois images internes (`sam3-api`, `sam3-segment`, `ray-sam3`) : changer de version se fait en éditant une ligne (`newTag`) au lieu de chercher la référence d'image dans chaque Deployment. C'est aussi le point de jonction avec la CI, qui pousse précisément ces tags. Enfin, les secrets chiffrés restent hors de la composition, appliqués séparément par `deploy.sh` (cf. section précédente).

Helm a été écarté : la stack n'a besoin d'aucun templating (pas de multi-environnements, pas de valeurs à substituer), et des manifestes YAML bruts restent lisibles et diffables directement, sans passer par un moteur de rendu pour savoir ce qui sera appliqué.

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

#pagebreak()
L'interface XML du projet, à laquelle ces noms doivent correspondre, déclare les classes annotables :

```xml
<View>
  <Image name="image" value="$image"/>
  <PolygonLabels name="label" toName="image">
    <Label value="sign" background="#FF0000"/>
    <Label value="road_marking" background="#FFFF00"/>
    <!-- <Label value="value" background="#XXXXXX"/>  Add new pre-annotation -->
  </PolygonLabels>
</View>
```

Cette conversion et l'appel à l'API REST Label Studio sont automatisés par l'endpoint `POST /import/{acquisition_id}`, qui lit les Parquet depuis MinIO et pousse le résultat (cf. @architecture).


== API

Les parties communes entre `Solo` et `Batch` sont regroupées dans une librairie *jobCore* séparée en 4 fichiers.

*postprocess.py* : Recolle les masques produits tuile par tuile sur l'image entière (`merge_masks`), sépare les objets en composantes connexes, puis convertit chaque masque en polygone au format Label Studio (`mask_to_polygon`).

Un masque de segmentation est une image en noir et blanc de la même taille que l'image analysée : un pixel blanc appartient à l'objet détecté, un pixel noir au fond. SAM3 produit ce masque sous forme de 0 et de 1. Les bibliothèques d'images comme PIL (Python Imaging Library) et OpenCV travaillent, elles, sur des pixels allant de 0 à 255. Le code convertit donc le masque en blanc pur (255) le temps de ces traitements, puis revient aux 0 et 1 à la fin. À chaque étape, le masque reste strictement noir ou blanc, jamais gris.

*s3.py* : Fabrique l'unique client S3 `boto3` du processus, partagé par l'API, les jobs et la CLI, pour la lecture/écriture sur le bucket.

*tiling.py* : Découpe l'image panoramique en tuiles carrées de taille fixe avec recouvrement (tile_stride), pour que SAM3 traite des morceaux assez petits et qu'un objet à cheval sur une bordure reste entier dans au moins une tuile. Complète les bords avec du noir pour garder des tuiles carrées.

*worker.py* : La classe Sam3Model charge le modèle SAM3 une seule fois, puis détecte sur une image les concepts décrits par des labels texte. Elle découpe l'image en tuiles (tiling.py), lance l'inférence par batch sur GPU, recolle et vectorise les résultats (postprocess.py), et renvoie la liste des polygones (label, points, score). Indépendante de Ray et des I/O : Solo et Batch l'enveloppent chacun dans leur propre acteur Ray.

Le job *solo* traite une seule image. L'API crée un Job Kubernetes qui lance un pod à GPU unique tournant l'image `ghcr.io/nearai-interreg/sam3-solo:staging`. Le pod appelle `ray.init()` localement sans cluster Ray et instancie un `SoloWorker` (acteur `@ray.remote(num_gpus=1)`) qui charge SAM3 une fois et infère sur l'image transmise avec les paramètres de tuilage définis. Le résultat est toujours imprimé sur stdout au format JSON Label Studio. Si le pod reçoit l'argument `--result_key`, il l'écrit en plus sur le bucket S3 à la clé `results/<job>.json`, ce que fait systématiquement l'API. Cette clé est ensuite relue par l'endpoint `/jobs/{name}/result`.

Le job *batch* traite un préfixe S3 entier, ou une liste explicite d'URLs `s3://` (`s3Uris`). L'API crée un Job Kubernetes qui lance un pod *sans GPU* tournant l'image `ghcr.io/nearai-interreg/ray-sam3:staging`, la même que celle des workers du RayCluster. Ce pod n'est qu'un driver, c'est-à-dire qu'il se connecte au RayCluster permanent (`ray://ray-cluster-head-svc:10001`), liste les images du préfixe d'entrée et les distribue sur `num_workers` acteurs GPU. Chaque worker écrit ses résultats en Parquet à l'URI de sortie. On transmet donc le bucket et le préfixe des images source, le préfixe de sortie des fichiers Parquet, les labels et le nombre de workers.

La fonction `build_job` assemble un `V1Job` du SDK Python Kubernetes à partir des paramètres de la requête : un `V1Container` (image, commande, arguments, variables d'environnement, ressources) dans un `V1PodSpec`, lui-même dans le template du `V1Job`. Les paramètres variables (GPU ou non, nom de la variable de clé d'accès) sont passés en arguments pour mutualiser le code entre solo et batch.

Les secrets ne sont jamais inscrits dans l'image : les credentials MinIO (`minio-secret`) et le token HuggingFace (`hf-secret`) sont injectés à l'exécution via `secretKeyRef`, et `S3_ENDPOINT_URL` via une variable simple. Le pod tire l'image depuis le registre privé grâce à `imagePullSecrets: ghcr-secret`. Les Jobs à GPU déclarent `runtimeClassName: nvidia` et la ressource `nvidia.com/gpu`. Chaque Job utilise `restartPolicy: Never` et `ttlSecondsAfterFinished: 3600` pour disparaître une heure après sa fin.

`submit_solo` passe `--result_key results/<job>.json` au Job. Le solo, en fin de traitement, dépose son JSON à cette clé sur S3. L'endpoint `get_result` relit ensuite l'objet avec `boto3` (les credentials MinIO côté API proviennent du même `minio-secret`). Le résultat est ainsi durable et indépendant du TTL des Jobs : le pod peut être supprimé, le JSON reste lisible.

Deux frictions du client Python ont demandé un contournement.

La première : `read_namespaced_pod_log` renvoie le `repr()` d'un objet `bytes` (la chaîne littérale `b'...'`) sur `kubernetes-client` 36.x au lieu du texte décodé.

Exemple de sortie :
```text
b'Done: 40 images, 2230 detections\n'
```

Le contournement passe `_preload_content=False` puis décode manuellement via `.data.decode("utf-8")`.

Ensuite, `jobs/status` est une sous-ressource RBAC distincte de `jobs`. Appeler `read_namespaced_job_status` exige une permission séparée et échoue en `403` sans elle. La solution est de lire la ressource `jobs` complète avec `read_namespaced_job`, déjà autorisée, et d'en extraire le champ statut. On évite ainsi de créer un deuxième droit d'accès uniquement pour lire une information qu'on pouvait déjà trouver ailleurs.


Pour la *segmentation à la volée*, un pod indépendant tourne et exploite une grande partie des librairies *jobCore*. La requête transmise à l'endpoint `/segment` porte la clé S3 de l'image et les points à segmenter, chacun avec son label :

```json
{
  "url": "data/acquisitions/20241003-Nyon/01_images/S003/20241003-Nyon_S003_ladybug5plus_000001.jpg",
  "items": [
    { "point": [4637, 2675], "label": "manhole" },
    { "point": [1200, 800],  "label": "road_marking" }
  ]
}
```

L'unique différence avec les autres modes est que nous exploitons la fonctionnalité de SAM3 pour la segmentation sur une zone spécifique :

```python
x, y = item.point
preds = model.predict(
    source=image, points=[[x, y]], labels=[1], verbose=False
)
```

On récupère les prédictions et on peut ainsi vérifier si un objet est présent ou non aux coordonnées entrées, afin de retourner le résultat étiqueté. Contrairement aux jobs solo et batch, le service de segmentation n'écrit aucun fichier : le résultat est renvoyé directement dans la réponse HTTP de l'endpoint `/segment`.

La mise en veille et la reprise du pod se font simplement via un autre appel de la librairie K8s en exploitant le principe de replicas :

```python
apps_v1.patch_namespaced_deployment_scale(
    name=SEGMENT_DEPLOYMENT,
    namespace=NAMESPACE,
    body={"spec": {"replicas": replicas}},
)
```

#linebreak()

`/segment/up` appelle la fonction avec la valeur *1* en paramètre, tandis que `/segment/down` passe la valeur *0*.

Finalement, le service ne dispose que d'un GPU. Comme une seule inférence peut tourner à la fois, un `threading.Lock` met les appels en file et les traite l'un après l'autre. En pratique l'usage est séquentiel, un annotateur, une image à la fois, donc la file ne bloque jamais.


Contrairement aux modes batch et solo, qui pilotent SAM3 via la librairie *jobCore* (tuilage, détection par concept, post-traitement), le service interactif s'appuie sur le wrapper `SAM` de la librairie *Ultralytics*. Celui-ci expose l'inférence par prompt visuel en un seul appel, sans la pipeline de tuilage inutile pour une prédiction ponctuelle.

Au démarrage du pod, les poids sont téléchargés depuis HuggingFace puis chargés une seule fois :

```python
from ultralytics import SAM
weights = hf_hub_download(repo_id="facebook/sam3", filename="sam3.pt")
model = SAM(weights)
```

Le fichier `sam3.pt` est le conteneur PyTorch des poids du modèle (3,3 Go). `SAM(weights)` reconstruit le réseau et le charge en VRAM. L'objet reste chaud pour toute la session, évitant de repayer le chargement à chaque requête.

Le masque renvoyé par `predict` est ensuite reconverti en polygone par `mask_to_polygon`, seule fonction de *jobCore* réutilisée par le service :

```python
mask = preds[0].masks.data[0].cpu().numpy()
points = mask_to_polygon(mask, w, h)
```

Si SAM3 ne trouve aucun objet sous le point, `masks` est vide et le service renvoie `found: false` pour cet item. Le label fourni n'oriente pas la détection : il étiquette simplement le masque retourné.

== Console web

La console tient dans un unique fichier `index.html` autonome : HTML, CSS et JavaScript inlinés, aucune dépendance externe (ni CDN, ni framework), donc aucune requête sortante. La page fonctionne ainsi telle quelle sur un cluster sans accès Internet. Côté serveur, l'intégration se réduit à une route `FileResponse` sur `/ui` et une ligne `COPY` dans le Dockerfile de l'API.

Le JavaScript n'utilise que `fetch` sur les endpoints REST, avec trois cadences de sondage : la liste des jobs toutes les 4 secondes, la santé de l'API et l'état du service interactif toutes les 10 secondes. Pour chaque batch actif, la console lit `/jobs/{name}/status` et en dérive le pourcentage, le temps écoulé et une estimation du temps restant (`écoulé / traitées × restantes`). Le fichier de statut d'un run terminé étant figé (`done: true`), sa réponse est mise en cache côté client et n'est plus re-sondée.

La progression s'affiche comme une grille de 72 tuiles qui se remplissent. C'est un clin d'œil à la grille de 72 × 72 patches du backbone ViT de SAM3 (cf. @resultats). Le formulaire de lancement expose les deux modes d'entrée du batch, préfixe S3 ou liste d'URLs `s3://` complètes, qui alimentent respectivement `s3Uri` et `s3Uris` de `POST /jobs/batch`. Les erreurs de validation de l'API remontent telles quelles à l'utilisateur : le champ `detail` d'une réponse 422 (par exemple le rejet d'une URL `https://`) est affiché en notification, sans traduction ni masquage.

L'endpoint `GET /segment/status` ajouté pour la console lit le `Deployment` du service de segmentation via le SDK Kubernetes (permission `get` sur `deployments`, déjà couverte par le Role existant) et retourne `{replicas, ready}`. La page en déduit trois états : *endormi* (`replicas == 0`), *démarrage* (`replicas > ready`, fenêtre de chargement du modèle en VRAM) et *prêt* (`ready ≥ 1`).

La console renvoie vers la documentation OpenAPI (cf. @tab-api-endpoints) par un lien vers `/docs`. Côté code, nommer cette documentation se réduit aux métadonnées du constructeur, `FastAPI(title="NearAI API", version="1.0", ...)`. Seule dépendance à connaître : l'interface Swagger charge son JavaScript depuis un CDN, c'est donc le navigateur de l'utilisateur, et non le cluster, qui doit disposer d'un accès Internet.

#figure(
  image("../images/webUi.png", width: 100%),
  caption: [
    La console en plus de lancer des tâches permet de voir l'avancée de batchs.
  ],
) <fig-webui>

== Observabilité

Chaque composant écrit ses logs sur la sortie standard (stdout), où Alloy les récupère pour les transmettre à Loki. Deux dispositifs garantissent que ces logs sont à la fois exploitables et complets.

L'API utilise un logger `nearapi` au format logfmt (`clé=valeur`), directement requêtable dans Loki. Un middleware enveloppe chaque requête et journalise une ligne par appel :

```
level=INFO logger=nearapi request method=POST path=/jobs/batch status=200 duration_ms=45.6
```

Le niveau s'adapte au résultat : INFO pour un succès, WARNING pour une réponse ≥ 400, et une trace complète via `log.exception` (status 500) pour toute exception non gérée. S'y ajoutent des logs métier par endpoint (`batch_submit`, `job_created`, `segment_scaled`) et le report des erreurs de l'API Kubernetes. Chaque appel laisse donc une trace horodatée, avec son issue et sa durée.

Les acteurs posaient un piège : `logging.basicConfig()` n'a aucun effet si le logger racine possède déjà des handlers. Or Ray en installe dans ses processus worker. Les `log.info` des acteurs étaient donc silencieusement filtrés, seuls les `warnings.warn` remontaient. La correction attache explicitement un handler au logger `jobCore` :

```python
logger = logging.getLogger("jobCore")
logger.setLevel(logging.INFO)
if not logger.handlers:
    h = logging.StreamHandler()
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    logger.addHandler(h)
    logger.propagate = False
```

Comme la classe `Sam3Model` s'exécute aussi bien dans l'acteur batch que dans l'acteur solo, cette configuration unique couvre les deux modes. Les enregistrements écrits sur stderr sont capturés par Ray, renvoyés au driver et collectés par Alloy.

Une fois les acteurs visibles, chaque worker journalise de quoi reconstruire un run depuis Loki sans relire les fichiers Parquet : au chargement, les paramètres (`tile`, `stride`, `downsample`) et le temps de chargement du modèle, puis par image, le downsampling appliqué, le nombre de tuiles, le nombre de polygones par label, le temps d'inférence et le nœud GPU de l'acteur. Cela permet notamment de distinguer L40S et A40 dans un run mixte.

Enfin, chaque pod porte un label `app` (`sam3-api`, `sam3-batch`, `sam3-solo`, `ray-worker`) qu'Alloy propage en label Loki. Les logs se filtrent ainsi par composant.

== Stack Observabilité

La stack est assemblée par Kustomize, un dossier par composant (`deploy/observability/manifests/`). Chacun se résume à un `Deployment` à un réplica dans le namespace `dani`, accompagné d'un Service, d'une ConfigMap et, selon le cas, d'un PVC et d'un Ingress.

*Prometheus* lit sa configuration depuis une ConfigMap, un `scrape_interval` de 15 s et une rétention TSDB de 7 jours (`--storage.tsdb.retention.time=7d`). Son PVC ne se montait pas sur tous les nœuds : il est donc épinglé sur `iict-suchet` via `nodeSelector`, avec un `fsGroup: 65534` pour que le volume soit accessible en écriture.

*Loki* est le composant le plus travaillé. Il est _stateless_ : tout l'état part sur MinIO, dans un bucket dédié `nearai-logs`, avec une rétention de 720 h (30 jours) purgée par le compactor (`retention_enabled`, `retention_delete_delay: 2h`). Les credentials MinIO ne figurent pas en clair dans la ConfigMap car ils sont injectés à l'exécution grâce au drapeau `-config.expand-env=true`. Un piège rencontré : les flush échouaient en `400` parce que Loki contactait l'endpoint MinIO en HTTP alors qu'il écoute en HTTPS (certificat TLS). Le passage en HTTPS a rétabli l'écriture.

*Alloy* remplace Promtail, passé en fin de vie. Là où Promtail tournait en DaemonSet et ouvrait un watcher `inotify` par fichier de log, Alloy est un `Deployment` unique qui lit les logs directement via l'API Kubernetes (`loki.source.kubernetes`), sans monter le système de fichiers du nœud. Il dispose pour cela d'un ServiceAccount avec un *Role* et un *RoleBinding* limités à la lecture des pods. Son bloc `discovery.relabel` attache les labels `namespace`, `pod`, `container` et `app` à chaque ligne avant de la pousser vers `loki-svc:3100` :

```yaml
discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app"]
    target_label  = "app"
  }
}
```


*DCGM Exporter* n'est pas déployé par ce travail : le GPU Operator NVIDIA l'installe automatiquement en DaemonSet, un pod par nœud GPU, exposant les métriques sur le port 9400. Quatre métriques sont retenues : utilisation, VRAM occupée, puissance et température.

Le point d'implémentation tient au scraping. Prometheus interroge DCGM via `dns_sd_configs` sur le Service _headless_, qui résout l'adresse IP de chaque pod du DaemonSet individuellement. Le label `hostname` de chaque nœud est ainsi préservé. Un ClusterIP classique aurait renvoyé une seule IP en round-robin et fait perdre cette distinction, rendant impossible la séparation L40S / A40 dans Grafana.


Le dashboard *Grafana* tourne en `Deployment` à 1 réplica, avec ses deux sources de données (Prometheus `:9090` et Loki `:3100`) provisionnées par ConfigMap, et il est exposé via un Ingress. Comme Prometheus, son PVC butait sur un volume Longhorn fantôme sur `iict-k8s-node4-rad` : il est donc épinglé sur `iict-suchet` avec `nodeSelector`, `fsGroup: 472` et `runAsUser: 472`.

Le dashboard suit les GPUs via les quatre métriques DCGM (utilisation, VRAM, puissance, température), avec une variable `hostname_filter` qui filtre les panels par nœud (`{Hostname=~".*${hostname_filter}.*"}`) ainsi que la liste des logs en live (latence de 3-4 secondes).
