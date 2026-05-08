#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#show: codly-init.with()



= État de l'art <etat-de-lart>

== Segmentation d'images

SAM3 (Segment Anything Model 3) est le modèle de segmentation publié par Meta en 2024 @sam3. Il hérite de SAM2 et étend ses capacités aux images de haute résolution et à la vidéo. SAM3 adopte une architecture Vision Transformer (ViT) comme encodeur d'image et un décodeur léger qui produit des masques binaires à partir de prompts géométriques (points, boîtes, polygones).

Le modèle fonctionne en mode _promptable_ et en mode _everything mode_.

En mode *prompt*, il attends simplement un message comme : "Un panneau octogonal avec le texte STOP à son centre", ou, simplement, "Un panneau".
Tandis que en mode *everything*, il segmente tous les objets détectables de l'image. Aucune supervision n'est fournie à l'inférence et SAM3 propose des masques candidats que le pipeline filtre par classe et score.

#figure(
  image("../images/sam-3-overview.png", width: 90%),
  caption: [
    Exemple du mode prompt de SAM3. Source : https://docs.ultralytics.com/fr/models/sam-3/
  ],
) <sam3promtp>

SAM3 a été entraîné sur SA-1B, un corpus de 1,1 milliard de masques sur 11 millions d'images. Cette couverture lui confère une généralisation forte sur des domaines non vus à l'entraînement, dont les images routières équirectangulaires.

Ce modèle accepte des images jusqu'à 1'024 x 1'024 pixels. Une panoramique de 8'192 x 4'096 pixels doit donc être découpée avant l'inférence. Ce travail adopte des tuiles de 512 x 512 pixels, ce qui produit 128 tuiles par image à pleine résolution. Un downsampling à 50 % ramène ce nombre à 32 tuiles et réduit le temps d'inférence d'un facteur 4, au prix d'une perte de détail acceptable pour les classes cibles.

_NB : SAM3 redimensionne automatiquement grandes les images sur une résolution autour de 1024 px, donc il n'y pas d'intêret d'aller au-delà._


Les images équirectangulaires présentent une distorsion géométrique croissante vers le zénith et le nadir. Les objets cibles (panneaux, marquages) se concentrent dans la bande centrale de l'image, correspondant à ±30° d'élévation, là où la distorsion est minimale. La correction de projection n'est donc pas implémentée, elle apporterait un gain marginal pour un coût d'implémentation élevé. Le bas du panorama est en grande partie occulté par la carrosserie du véhicule. Ce choix est documenté comme limitation connue.

== Calcul distribué


Apache Spark est le framework de calcul distribué dominant pour les workloads analytiques sur données structurées. Son modèle d'exécution repose sur un DAG de transformations sur des RDDs ou DataFrames, optimisé pour les opérations SQL et les pipelines ETL à large échelle sur clusters homogènes.

Spark présente trois limitations structurelles pour l'inférence GPU :

*Héritage CPU* : Spark a été conçu dans l'écosystème Hadoop pour le traitement de données tabulaires. Le support GPU a été ajouté a posteriori via RAPIDS (NVIDIA). Il n'est pas natif : les workers Spark ne savent pas scheduler dynamiquement des tâches GPU hétérogènes.

*Clusters homogènes* : Spark optimise pour la localité des données sur des clusters uniformes. Le cluster iict-rad dispose de trois types de GPU (L40S, A40, L4) avec des performances très différentes. Ray gère nativement cette hétérogénéité via ses mécanismes de placement group et de priorité par ressource.

*Performance sur inférence ML* : Sur des benchmarks de classification d'images en batch, Ray Data atteint une vitesse 2x supérieure à Spark @anyscale-spark. Sur des workloads multimodaux (images, vidéo), l'écart est 10× par rapport à Spark @daft-benchmark.

Le signal industriel le plus fort est la migration d'Amazon en 2024 : leur équipe Business Data Technologies a migré 1,5 exaoctets de données Parquet de Spark vers Ray, réalisant une économie de plus de 120 millions de dollars par an avec une efficacité 82 % supérieure par GiB traité @amazon-ray. Cette migration a pris 4 ans et constitue la plus grande validation publique de Ray en production.


Ray est un framework Python open-source pour distribuer des workloads ML/IA sur des clusters hétérogènes CPU/GPU @ray. Il expose deux primitives fondamentales.

- Une *Task* (`@ray.remote` sur une fonction) est une unité de calcul sans état, exécutée de façon asynchrone sur un worker disponible.
- Un *Actor* (`@ray.remote` sur une classe) est une unité de calcul avec état, maintenu en mémoire sur un worker assigné. L'Actor est LE patron adapté au chargement de modèles. Le modèle est chargé une fois dans `__init__`, puis réutilisé sur toutes les requêtes sans rechargement, évitant les erreurs de mémoire insuffisante (OOM) qui surviennent lorsqu'un modèle est rechargé à chaque tâche.

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

Concernant le choix entre ces deux technologies, Spark reste pertinent pour les pipelines ETL sur données structurées. Pour de l'inférence GPU sur images non structurées à grande échelle sur un cluster hétérogène, Ray est le choix correct.


Deux stratégies de parallélisation GPU existent pour l'inférence de modèles :

- *Data parallelism* : chaque GPU héberge une copie complète du modèle et traite une image indépendante. Le throughput scale linéairement avec le nombre de GPU.
- *Model parallelism* : le modèle est fragmenté sur plusieurs GPU pour réduire la latence d'une seule inférence. Implique un overhead de communication inter-GPU à chaque couche.

Le model parallelism est justifié uniquement lorsque le modèle ne tient pas sur un seul GPU (LLMs de 70 milliards de paramètres et plus). SAM3 ViT-H occupe 2,4 Go de VRAM et les GPU du cluster (L40S 48 Go, A40 48 Go, L4 24 Go) l'hébergent sans contrainte.
L'objectif du pipeline est le throughput sur 300 000 images, pas la latence sur une image isolée. Avec $N$ workers en data parallelism, $N$ images sont traitées simultanément sans aucune synchronisation inter-GPU. Le modèle Ray Actor (un modèle chargé par GPU, $N$ workers indépendants) est la stratégie optimale pour ce workload.

*KubeRay* est l'opérateur Kubernetes officiel pour Ray @kuberay. Il introduit la ressource `RayCluster` (CRD `ray.io/v1`), qui déclare un nœud head et un ou plusieurs groupes de workers. L'opérateur crée et gère les pods correspondants, expose les ports GCS (6379), dashboard (8265), métriques (8080) et client Ray (10001) via des Services Kubernetes.

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
*S3* est le protocole standard pour ce type de stockage. boto3, PyArrow et Ray Data l'implémentent nativement, aucune couche d'abstraction supplémentaire n'est nécessaire. Enfin, remplacer la variable S3_ENDPOINT_URL suffit à changer de backend (MinIO, AWS S3, Ceph) sans modifier le code du pipeline.

*MinIO* est un serveur de stockage objet compatible avec le protocole S3 @minio. La HEIG-VD l'exploite sur un NAS Synology SA3200D, installé via Container Manager avec l'image officielle `minio/minio`. Le pipeline accède à MinIO via `boto3` avec les variables d'environnement S3 standard (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT_URL`).

Des alternatives comme *RustFS* (Apache 2.0, moins d'un an) ou *CEPH* (mature, LGPL, bloc/fichier/objet) ont été évaluées. Malgré le fait que MinIO devient un produit fermé dès cette année, la décision est de conserver MinIO car la migration ajouterait du risque sans bénéfice immédiat, et la configuration S3 est le seul point à modifier si un changement de backend devient nécessaire.

== Format de résultats

*Parquet* est un format binaire orienté colonnes conçu pour les workloads analytiques @parquet. Chaque fichier est découpé en _row groups_ eux-mêmes découpés en _column chunks_. Cette organisation permet de lire uniquement les colonnes nécessaires à une requête sans charger l'ensemble du fichier.

#figure(
  image("../images/parquetFormat.png", width: 80%),
  caption: [
    Parquet exploite une solution hybride pour obtenir de meilleur performances. Source : https://towardsdatascience.com/demystifying-the-parquet-file-format-13adb0206705/
  ],
) <parquetHybrid>

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

*Label Studio* est une plateforme d'annotation open-source @labelstudio. Elle supporte les polygones (`polygonlabels`) sur images, le stockage S3 comme source d'images, et l'import de pré-annotations via son API REST. Le pipeline produit des pré-annotations SAM3 que des annotateurs humains corrigent et valident dans Label Studio.
Il est configuré avec MinIO comme _cloud storage_ source.

Les URLs `s3://nearai/...` sont converties en URLs HTTP temporaires signées, ce qui évite d'exposer les credentials de stockage aux navigateurs clients.

XXXX Parler ici de NearLabel, le projet fait par mon collègue Valentin Ricard.

== Observabilité

*Prometheus* permet de faire du monitoring et des alertes via la collection de métriques en temps réel. Les données sont sotckés sous format TSDB (Time Series DataBase). Une fois récoltées, les données peuvent être traités via PromQL, un language query extrêmment rapide se basant sur les vecteurs instanés, de portée et vecteurs scalaires.

Ses principaux composants sont:

- *Core Server* : Service principal de prometheus configurer via le fichier _prometheus.yaml_.
- *Exporters* : Agents qui collectent les métriques tel que Node Exporter, Database Exporter.
- *Alertmanager* : Pour la gestion d'alertes avec des fonctions de groupe ou d'inhibition.

*Grafana* est un outil permetant de créer et visualiser des dashboards via sa web UI. Couplé à Prometheus pour la récolte de données, des visuasation en temps réel peuvent être effectués pour monitorer le status des différants noeuds et composants de la pipeline.

*Loki est un système d'agrégation de journaux qui indexe uniquement les balises de métadonnées, et non le contenu complet des journaux. Cela le rend plus léger qu'Elasticsearch, ce qui est utile dans notre cas, car nous n'avons pas besoin d'une recherche en texte intégral, mais devons plutôt retrouver les journaux d'un pod de travail Ray spécifique à un moment précis.
*
Il stocke les données dans un format S3 et est composé de 2 types de stockages principaux _index_ et _chunks_.

- *Index* : Table des matières, mappe simplement les labels sur la position des chunks.
- *Chunks* : Blocs compressés de logs bruts selon un label et une plage horraire.

Cette chaine permet a Loki d'être purement _stateless_ car toutes les données sont stockées sur le service S3.
Les logs sont traités avec LogQL (language fortement inspiré de PromQL) en les filterant selon les labels pour les transformer ensuite en métriques.

#figure(
  ```LogQL
  {namespace="dani", pod=~"ray-worker.*"} |= "ERROR"
  ```,
  caption: [Selectionne uniquement les logs "ERROR" du namespace dani sur les pods commencant par ray-worker],
)

*Promtail* est un agent supplémentaire pour Loki. Il tourne en tant que _DeamonSet_ avec 1 instance par noeud et collecte toutes les métriques des pods sur ce dit noeud. Les pods sont découverts via le _service discovery_ de l'API K8s puis en lisant dans `/var/logs/pods/`.
Les workers Ray dans notre cas n'auront qu'a écrire dans leur _stdout/stderr_ et Promtail les récupères.

Malheureusement, Promatail a été mis en EOL. Il fait donc utiliser *Alloy* comme substitut.

Grafana Alloy est le successeur officiel de Promtail et de Grafana Agent, annoncé en maintenance-only en 2024 @alloy. Il unifie la collecte de logs, métriques, traces et profils dans un seul agent configurable.
Sa configuration utilise le langage River, un format déclaratif inspiré de HCL. Les composants sont connectés explicitement. C'est à dire que la sortie d'un bloc devient l'entrée du suivant, formant un pipeline de traitement.

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

Les avantages par rapport à Promtail sont que un seul pod `Deployment` suffit à la place d'un `DaemonSet` et les limites inotify du nœud ne sont pas sollicitées. Car si Promtail lisait chaque fichier de logs et _stdout/stderr_, Alloy lui va simplement scanner les sources a intervalles régulisers et donc ainsi ne consomme pas de ressource 'inotify'.

== Cycle vie d'un log
Fonctionnement en 3 étapes :
+ *Ingestion* : Les logs sont récoltés
+ *Mise en tampon* : Le tout est push sur Loki
+ *Flush vers S3* : Au bout d'un certain temps ou une certaine taille de fichier les logs sont envoyés sur le bucket s3.

=== DCGM
