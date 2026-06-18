#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#import "@preview/fletcher:0.5.7" as fletcher: diagram, edge, node
#show: codly-init.with()



= État de l'art <etat-de-lart>

== Segmentation d'images

SAM3 (Segment Anything Model 3) est le modèle de segmentation publié par Meta en 2024 @sam3. Il hérite de SAM2 et étend ses capacités aux images de haute résolution et à la vidéo. SAM3 adopte une architecture Vision Transformer comme encodeur d'image et un décodeur léger qui produit des masques binaires à partir de prompts géométriques (points, boîtes, polygones).

Le modèle fonctionne en mode _promptable_ et en mode _everything_.

En mode *prompt*, il attends simplement un message comme : "Un panneau octogonal avec le texte STOP à son centre", ou, simplement, "Un panneau".
Tandis que en mode *everything*, il segmente tous les objets détectables de l'image. Aucune supervision n'est fournie à l'inférence et SAM3 propose des masques candidats que la pipeline filtre par classe et score.

#linebreak()
#figure(
  image("../images/sam-3-overview.png", width: 90%),
  caption: [
    Exemple du mode prompt de SAM3. Source : https://docs.ultralytics.com/fr/models/sam-3/
  ],
) <sam3promtp>


#pagebreak()
SAM3 a été entraîné sur SA-1B, un corpus de 1,1 milliard de masques sur 11 millions d'images. Cette couverture lui confère une généralisation forte sur des domaines non vus à l'entraînement, dont les images routières équirectangulaires.

Ce modèle accepte des images jusqu'à 1'024 x 1'024 pixels. Une panoramique de 8'192 x 4'096 pixels doit donc être découpée avant l'inférence. Ce travail adopte des tuiles de 512 x 512 pixels, ce qui produit 128 tuiles par image à pleine résolution. Un downsampling à 50 % ramène ce nombre à 32 tuiles et réduit le temps d'inférence d'un facteur 4, au prix d'une perte de détail acceptable pour les classes cibles.

=== TO DO : EXPLICATION DU TUILAGE VIA UNE IMAGE

Les images équirectangulaires présentent une distorsion géométrique croissante vers le zénith et le nadir. Les objets cibles (panneaux, marquages) se concentrent dans la bande centrale de l'image, correspondant à ±30° d'élévation, là où la distorsion est minimale. La correction de projection n'est donc pas implémentée, elle apporterait un gain marginal pour un coût d'implémentation élevé. Le bas du panorama est en grande partie occulté par la carrosserie du véhicule. Ce choix est documenté comme limitation connue.

== Calcul distribué


Apache Spark est le framework de calcul distribué dominant pour les workloads analytiques sur données structurées. Son modèle d'exécution repose sur un DAG de transformations sur des RDDs ou DataFrames, optimisé pour les opérations SQL et les pipelines ETL à large échelle sur clusters homogènes.

Spark présente trois limitations structurelles pour l'inférence GPU :

*Héritage CPU* : Spark a été conçu dans l'écosystème Hadoop pour le traitement de données tabulaires. Le support GPU a été ajouté a posteriori via RAPIDS (NVIDIA). Il n'est pas natif : les workers Spark ne savent pas scheduler dynamiquement des tâches GPU hétérogènes.

*Clusters homogènes* : Spark optimise pour la localité des données sur des clusters uniformes. Le cluster iict-rad dispose de trois types de GPU (L40S, A40, L4) avec des performances très différentes. Ray gère nativement cette hétérogénéité via ses mécanismes de placement group et de priorité par ressource.

*Performance sur inférence ML* : Sur des benchmarks de classification d'images en batch, Ray Data atteint une vitesse 2x supérieure à Spark @anyscale-spark. Sur des workloads multimodaux (images, vidéo), l'écart est 10× par rapport à Spark @daft-benchmark.

Le signal industriel le plus fort est la migration d'Amazon en 2024 : leur équipe Business Data Technologies a migré 1,5 exaoctets de données Parquet de Spark vers Ray, réalisant une économie de plus de 120 millions de dollars par an avec une efficacité 82 % supérieure par GiB traité @amazon-ray. Cette migration a pris 4 ans et constitue la plus grande validation publique de Ray en production.


Ray est un framework Python open-source pour distribuer des workloads ML/IA sur des clusters hétérogènes CPU/GPU @ray.

Il expose deux primitives fondamentales :

- Une *Task* (`@ray.remote` sur une fonction) est une unité de calcul sans état, exécutée de façon asynchrone sur un worker disponible.
- Un *Actor* (`@ray.remote` sur une classe) est une unité de calcul avec état, maintenu en mémoire sur un worker assigné. L'Actor est LE patron adapté au chargement de modèles. Le modèle est chargé une fois dans `__init__`, puis réutilisé sur toutes les requêtes sans rechargement, évitant les erreurs OOM qui surviennent lorsqu'un modèle est rechargé à chaque tâche.

#linebreak()
#figure(
  ```python
  @ray.remote(num_gpus=1)
  class SAM3Worker:
      def __init__(self):
          self.model = load_sam3()   # chargé une fois

      def process(self, batch):
          return infer(self.model, batch)
  ```,
  caption: [L'Actor initialise le modèle, le preprocesseur et le postprocesseur une seule fois dans `__init__` ; `process()` les réutilise sur chaque image sans rechargement],
)
#linebreak()

Ray gère l'allocation des ressources (CPU, GPU, mémoire), la sérialisation des données entre driver et workers via son object store partagé et la récupération sur défaillance d'un worker.

Spark reste pertinent pour les pipelines ETL sur données structurées. Pour l'inférence GPU sur images non structurées à grande échelle sur un cluster hétérogène, Ray est le choix correct.

#pagebreak()
Deux stratégies de parallélisation GPU existent pour l'inférence de modèles :

- *Data parallelism* : chaque GPU héberge une copie complète du modèle et traite une image indépendante. Le throughput scale linéairement avec le nombre de GPU.
- *Model parallelism* : le modèle est fragmenté sur plusieurs GPU pour réduire la latence d'une seule inférence. Implique un overhead de communication inter-GPU à chaque couche.

Le model parallelism est justifié uniquement lorsque le modèle ne tient pas sur un seul GPU (LLMs de 70 milliards de paramètres et plus). SAM3 ViT-H occupe ~3,8 Go de VRAM une fois chargé et les GPU du cluster (L40S 48 Go, A40 48 Go, L4 24 Go) l'hébergent sans contrainte.
L'objectif de la pipeline est le throughput sur 300'000 images, pas la latence sur une image isolée. Avec $N$ workers en data parallelism, $N$ images sont traitées simultanément sans aucune synchronisation inter-GPU. Le modèle Ray Actor (un modèle chargé par GPU, $N$ workers indépendants) est la stratégie la plus correcte pour ce workload.

*KubeRay* est l'opérateur Kubernetes officiel pour Ray @kuberay. Il introduit la ressource `RayCluster`, qui déclare un nœud head et un ou plusieurs groupes de workers. L'opérateur crée et gère les pods correspondants, expose les ports GCS (:6379), dashboard (:8265), métriques (:8080) et client Ray (:10001) via des Services Kubernetes.

Le driver externe se connecte au cluster via `ray.init("ray://ray-cluster-head-svc:10001")`.
Les workers ne sont pas contactés directement car Ray dispatche les tâches via le Global Control Store (GCS) hébergé sur le head.

Une distinction importante sépare la terminologie Kubernetes de la terminologie Ray :

#figure(
  table(
    columns: (auto, auto, auto),
    [*Terme*], [*Sens Kubernetes*], [*Sens Ray*],
    [Head], [Pas d'équivalance directe], [Nœud unique hébergeant le GCS, le scheduler et le dashboard],
    [Worker], [Pod dans un Deployment], [Nœud Ray enregistré auprès du GCS, exécute les tâches],
    [Service], [ClusterIP stable pour la sélection de pods], [Expose GCS (6379), dashboard (8265), client (10001)],
  ),
  caption: [Terminologie Kubernetes vs Ray],
) <tab-k8s-ray-terms>

#pagebreak()
== Stockage objet

Les images panoramiques (JPEG, ~50 Mo chacune), les fichiers Parquet et les poids de modèles sont des *BLOBs*, des objets binaires nonstructurés que les bases de données relationnelles gèrent mal et que les systèmes de fichiers partagés (NFS) ne scalent pas.
Le stockage objet est conçu pour ce cas. Chaque BLOB est adressé par une clé unique, accessible via HTTP, sans limite de taille ni de volume total.

*S3* est le protocole standard pour ce type de stockage. `boto3`, PyArrow et Ray Data l'implémentent nativement, aucune couche d'abstraction supplémentaire n'est nécessaire. Enfin, remplacer la variable `S3_ENDPOINT_URL` suffit à changer de backend (MinIO, AWS S3, Ceph) sans modifier le code de la pipeline.

*MinIO* est un serveur de stockage objet compatible avec le protocole S3 @minio. La HEIG-VD l'exploite sur un NAS Synology SA3200D, installé via _Container Manager_ avec l'image officielle `minio/minio`. La pipeline accède à MinIO via `boto3` avec les variables d'environnement S3 standard (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT_URL`).

Des alternatives comme *RustFS* sous license Apache 2.0 et sorti il y'a moins d'un an ou *CEPH* qui lui est plus mature, sous license LGPL et gère du bloc/fichier/objet ont été évaluées. MinIO ferme son code source en 2025. La migration vers une alternative ajouterait du risque sans bénéfice immédiat. La configuration S3 est le seul point à modifier lors d'un changement de backend.

== Format de résultats

*Parquet* est un format binaire orienté colonnes conçu pour les workloads analytiques @parquet @parquet-query. Chaque fichier est découpé en _row groups_ eux-mêmes découpés en _column chunks_. Cette organisation permet de lire uniquement les colonnes nécessaires à une requête sans charger l'ensemble du fichier.

#figure(
  image("../images/parquetFormat.png", width: 90%),
  caption: [
    Parquet exploite une solution hybride pour obtenir de meilleur performances. Source : https://towardsdatascience.com/demystifying-the-parquet-file-format-13adb0206705/
  ],
) <parquetHybrid>
#linebreak()

L'image illustre la différence entre les trois approches.
+ Le stockage en lignes (row-based, comme CSV) lit toutes les colonnes pour accéder à une seule valeur.
+ Le stockage en colonnes pur (column-based) regroupe toutes les valeurs d'une même colonne mais complique l'accès à une ligne entière.
+ Parquet adopte une approche hybride, les données sont d'abord partitionnées en *row groups* (tranches horizontales de lignes), puis à l'intérieur de chaque row group les valeurs sont stockées colonne par colonne. Cette organisation permet de traiter plusieurs row groups en parallèle (un par worker Ray) tout en lisant uniquement les colonnes nécessaires à la requête.

Parquet stocke des statistiques min/max par column chunk. Un moteur de requête peut ainsi ignorer des row groups entiers si le prédicat tombe hors de leur plage. C'est le _predicate pushdown_, supporté nativement par PyArrow. Filtrer les polygones par zone GPS ou par seuil de score ne charge que les colonnes `latitude`, `longitude` et `score`, indépendamment du volume total.

*PostGIS* (extension PostgreSQL pour les données géospatiales) a été évalué comme alternative. Il offre des index spatiaux GIST et des requêtes géométriques natives (`ST_Within`, `ST_Intersects`). La décision est de le remplacer par Parquet sur S3. Les requêtes du projet ne nécessitent pas de jointures géospatiales complexes, et Parquet évite de maintenir une base de données.

*JSON* (JavaScript Object Notation) est le format accepté par LabelStudio pour importer les données géospatiales sur une images. Ce format va être utiliser uniquement pour le mode `on demand` et en legacy pour labelstudio afin de visualiser les résultats des runs.

#figure(
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
  ```,
  caption: [Exemple d'output JSON pour une image traitée et marquée sur LabelStudio],
)

== Annotation

*Label Studio* est une plateforme d'annotation open-source @labelstudio. Elle supporte les polygones (`polygonlabels`) sur images, le stockage S3 comme source d'images, et l'import de pré-annotations via son API REST. La pipeline produit des pré-annotations SAM3 que des annotateurs humains corrigent et valident dans Label Studio.
Il est configuré avec MinIO comme _cloud storage_ source.

Les URLs `s3://nearai/...` sont converties en URLs HTTP temporaires signées, ce qui évite d'exposer les credentials de stockage aux navigateurs clients.

XXXX Parler ici de NearLabel, le projet fait par mon collègue Valentin Ricard.

== Gestion des secrets

Trois secrets pilotent la pipeline : les credentials MinIO, le token HuggingFace et les identifiants du registre privé. Un Secret Kubernetes ne les protège pas en soi car son contenu n'est encodé qu'en base64, trivialement réversible. Le créer à la main (`kubectl create secret`) le laisse de plus hors du contrôle de version, sans trace de sa structure.


Pour versionner des secrets sans les exposer les logiques utilisée dans l'industrie sont :

*Sealed Secrets* @sealed-secrets chiffre un Secret avec la clé publique d'un contrôleur installé dans le cluster ; seul ce contrôleur peut le déchiffrer.

*External Secrets Operator* @external-secrets et *Vault* @vault vont plus loin, les secrets vivent dans un coffre externe et un opérateur les synchronise dans le cluster à la demande. Ces trois solutions partagent un prérequis rédhibitoire ici car elles imposent l'installation d'un composant à l'échelle du cluster (contrôleur ou opérateur), donc des droits d'administrateur hors de portée du namespace dans notre cas.

*SOPS* @sops chiffre directement les fichiers de manifeste, sans aucun composant côté cluster. Il délègue le chiffrement à un backend PGP, KMS cloud, ou *age* @age, un outil de chiffrement asymétrique moderne réduit à une paire de clés dans un fichier. SOPS ne chiffre que les valeurs (`encrypted_regex` sur `stringData`), laissant le reste du manifeste lisible pour des diffs Git propres. Le déchiffrement est manuel, au moment du déploiement.

SOPS combiné à age est retenu, il versionne les secrets chiffrés dans Git sans rien installer sur le cluster, ce qui convient à un accès limité à un seul namespace. Le compromis assumé est l'absence de synchronisation automatique acceptable pour trois secrets statiques, la complexitée du projet et le déplacement du problème vers la protection de la clé privée age, qui ne doit jamais être commitée.

== Observabilité

*Prometheus* collecte des métriques en temps réel et génère des alertes. Les données sont stockées au format TSDB et interrogées via PromQL, un langage de requête basé sur les vecteurs instantanés, de portée et scalaires.

Ses principaux composants sont:

- *Core Server* : Service principal de prometheus configurer via le fichier _prometheus.yaml_.
- *Exporters* : Agents qui collectent les métriques tel que Node Exporter, Database Exporter.
- *Alertmanager* : Pour la gestion d'alertes avec des fonctions de groupe ou d'inhibition.

*Grafana* visualise les métriques Prometheus et les logs Loki dans des dashboards interactifs. Il expose l'état du cluster, le throughput de la pipeline et l'utilisation GPU en temps réel.

*Elasticsearch* est la solution de référence pour l'agrégation et la recherche de logs. Il construit un index inversé sur le contenu intégral de chaque ligne de log, ce qui permet des recherches plein-texte arbitraires. Cette puissance a un coût : l'indexation consomme 3 à 5x plus de stockage que les logs bruts, et Elasticsearch requiert un minimum de trois nœuds pour fonctionner en haute disponibilité, avec une configuration mémoire JVM précise (heap généralement fixé à 50 % de la RAM disponible).

*Loki* est un système d'agrégation de journaux qui indexe uniquement les labels de métadonnées, et non le contenu des lignes. Cette approche réduit drastiquement le volume d'index. Loki stocke les logs compressés en chunks sur le bucket @loki-storage, ce qui le rend _stateless_ et compatible avec l'infrastructure existante sans nœud dédié supplémentaire.

Il stocke les données dans un format S3 et est composé de 2 types de stockages principaux _index_ et _chunks_.

- *Index* : Table des matières, mappe simplement les labels sur la position des chunks.
- *Chunks* : Blocs compressés de logs bruts selon un label et une plage horaire.

Les logs sont traités avec LogQL en les filtrant selon les labels pour les transformer ensuite en métriques.

#figure(
  ```LogQL
  {namespace="dani", pod=~"ray-worker.*"} |= "ERROR"
  ```,
  caption: [Sélectionne uniquement les logs "ERROR" du namespace dani sur les pods commençant par ray-worker],
)
#linebreak()

Pour notre pipeline, la recherche plein-texte est inutile car les requêtes se limitent à retrouver les logs d'un worker Ray identifié par son nom de pod et son namespace. Elasticsearch apporterait une infrastructure disproportionnée par rapport au besoin.

*Promtail* est un agent supplémentaire pour Loki. Il tourne en tant que _DaemonSet_ avec 1 instance par noeud et collecte toutes les métriques des pods sur ce dit noeud. Les pods sont découverts via le _service discovery_ de l'API K8s puis en lisant dans `/var/logs/pods/`.
Les workers Ray dans notre cas n'auront qu'a écrire dans leur _stdout/stderr_ et Promtail les récupères.

Malheureusement, Promtail a été mis en EOL. Il faut donc utiliser *Alloy* comme substitut.

*Grafana Alloy* est le successeur officiel de Promtail et de Grafana Agent, annoncé en maintenance-only en 2024 @alloy. Il unifie la collecte de logs, métriques, traces et profils dans un seul agent configurable.
Sa configuration utilise le langage River, un format déclaratif inspiré de HCL. Les composants sont connectés explicitement. C'est à dire que la sortie d'un bloc devient l'entrée du suivant, formant une pipeline de traitement.

#figure(
  ```alloy
  discovery.kubernetes "pods" { role = "pod" }

  loki.source.kubernetes "pods" {
    targets    = discovery.kubernetes.pods.targets
    forward_to = [loki.write.loki.receiver]
  }

  loki.write "loki" {
    endpoint { url = "http://loki-svc:3100/loki/api/v1/push" }
  }
  ```,
  caption: [Le composant `loki.source.kubernetes` lit les logs directement via l'API Kubernetes sans monter le système de fichiers du nœud],
)

#linebreak()


Alloy présente deux avantages sur Promtail : un seul pod `Deployment` remplace le `DaemonSet`, et les limites inotify du nœud ne sont pas sollicitées.#footnote[Promtail ouvre un watcher `inotify` par fichier de log. Sur un nœud dense en pods, la limite `fs.inotify.max_user_watches` est atteinte et Promtail cesse silencieusement de collecter les nouveaux logs sans erreur visible.] Là où Promtail ouvrait un watcher par fichier de log, Alloy interroge l'API Kubernetes à intervalles réguliers.

#pagebreak()
== Cycle de vie d'un log

Un log émis par un worker Ray parcourt quatre étapes avant d'être interrogeable dans Grafana.

+ *Émission* : le worker écrit sur stdout ou stderr. Kubernetes capture ce flux et l'écrit dans `/var/log/pods/` sur le nœud.
+ *Collecte* : Alloy lit les logs via l'API Kubernetes (`loki.source.kubernetes`), sans monter le filesystem du nœud. Il attache les labels de métadonnées extraits des pods : `namespace`, `pod`, `container`.
+ *Ingestion* : Alloy pousse les flux vers le Distributor de Loki via HTTP. Loki bufferise les entrées dans ses Ingesters en mémoire.
+ *Flush vers S3* : au bout d'un délai ou d'un seuil de volume, les Ingesters écrivent deux artefacts sur MinIO : l'*index* et les *chunks*. Loki devient _stateless_ : tout l'état réside dans le bucket.
#linebreak()
#figure(
  diagram(
    node-stroke: none,
    edge-stroke: 1.2pt + rgb("#94A3B8"),
    spacing: (2.5em, 1.8em),
    node(
      (0, 0),
      text(fill: white)[*Worker Ray*\ #text(size: 0.78em)[stdout/stderr]],
      corner-radius: 8pt,
      fill: rgb("#334155"),
      name: <worker>,
    ),
    node(
      (1, 0),
      text(fill: white)[*Alloy*\ #text(size: 0.78em)[K8s API]],
      corner-radius: 8pt,
      fill: rgb("#9333EA"),
      name: <alloy>,
    ),
    node(
      (2, 0),
      text(fill: white)[*Loki*\ #text(size: 0.78em)[Ingester]],
      corner-radius: 8pt,
      fill: rgb("#4F46E5"),
      name: <loki>,
    ),
    node(
      (3, 0),
      text(fill: white)[*MinIO*\ #text(size: 0.78em)[index + chunks]],
      corner-radius: 8pt,
      fill: rgb("#2563EB"),
      name: <minio>,
    ),
    node(
      (4, 0),
      text(fill: white)[*Grafana*\ #text(size: 0.78em)[LogQL]],
      corner-radius: 8pt,
      fill: rgb("#EA580C"),
      name: <grafana>,
    ),
    edge(<worker>, <alloy>, "->"),
    edge(<alloy>, <loki>, "->", [push]),
    edge(<loki>, <minio>, "->", [flush]),
    edge(<grafana>, <loki>, "->", [LogQL]),
  ),
  caption: [Cycle de vie d'un log : du worker Ray jusqu'à Grafana],
) <fig-log-lifecycle>

=== DCGM

*DCGM* (NVIDIA Data Center GPU Manager) est la bibliothèque officielle NVIDIA pour monitorer et gérer les GPUs en environnement datacenter @dcgm. Elle lit les métriques directement depuis le driver NVIDIA et les expose via deux interfaces : `dcgmi`, un CLI pour l'inspection manuelle, et *DCGM Exporter*, un endpoint HTTP Prometheus (:9400).

L'Exporter tourne en tant que DaemonSet. Donc, un pod par nœud GPU. Le GPU Operator l'installe automatiquement sur chaque nœud du cluster.

Les quatre métriques intérésantes sont :
#linebreak()

#figure(
  table(
    columns: (auto, auto, auto),
    [*Métrique*], [*Unité*], [*Description*],
    [`DCGM_FI_DEV_GPU_UTIL`], [%], [Taux d'utilisation du GPU],
    [`DCGM_FI_DEV_FB_USED`], [MB], [VRAM consommée],
    [`DCGM_FI_DEV_POWER_USAGE`], [W], [Consommation électrique],
    [`DCGM_FI_DEV_GPU_TEMP`], [°C], [Température du GPU],
  ),
  caption: [Métriques DCGM exposées à Prometheus],
) <tab-dcgm-metrics>

Un GPU à 0 % d'utilisation avec une VRAM occupée et une puissance supérieure à 17 W indique un worker Ray actif avec le modèle chargé en mémoire mais sans inférence en cours. Cette distinction est utile pour identifier les périodes d'attente entre deux batches d'images.

Prometheus scrape DCGM Exporter via un `headless service` qui résout en autant d'adresses IP que de pods actifs (un par nœud GPU). La configuration `dns_sd_configs` de Prometheus collecte chaque nœud individuellement, contrairement à un ClusterIP qui n'expose qu'un pod en round-robin.#footnote[Avec un ClusterIP, Prometheus aurait obtenu une seule IP tournante car le label `hostname` de chaque nœud GPU aurait été perdu, rendant impossible la distinction entre L40S et A40 dans Grafana.]
