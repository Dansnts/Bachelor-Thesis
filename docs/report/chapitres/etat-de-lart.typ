= État de l'art <etat-de-lart>

== Segmentation d'images 
=== SAM3

SAM3 (Segment Anything Model 3) est le modèle de segmentation publié par Meta en 2024 @sam3. Il hérite de SAM2 et étend ses capacités aux images de haute résolution et à la vidéo. SAM3 adopte une architecture Vision Transformer (ViT) comme encodeur d'image et un décodeur léger qui produit des masques binaires à partir de prompts géométriques (points, boîtes, polygones).

Le modèle fonctionne en mode _promptable_ et en mode _everything mode_. 

En mode *prompt*, il attends simplement un message comme : _Un panneau octogonal avec le texte STOP à son centre_. 

En mode *everything*, il segmente tous les objets détectables de l'image. Aucune supervision n'est fournie à l'inférence et SAM3 propose des masques candidats que le pipeline filtre par classe et score.

#figure(
  image("../images/sam-3-overview.png", width: 100%),
  caption: [
    Exemple du mode prompt de SAM3. Source : https://docs.ultralytics.com/fr/models/sam-3/
  ]
) <sam3promtp>

SAM3 a été entraîné sur SA-1B, un corpus de 1,1 milliard de masques sur 11 millions d'images. Cette couverture lui confère une généralisation forte sur des domaines non vus à l'entraînement, dont les images routières équirectangulaires.

=== Fenêtre d'entrée et stratégie de tuilage

SAM3 accepte des images jusqu'à 1'024 x 1'024 pixels. Une panoramique de 8'192 x 4'096 pixels doit donc être découpée avant l'inférence. Ce travail adopte des tuiles de 512 x 512 pixels, ce qui produit 128 tuiles par image à pleine résolution. Un downsampling à 50 % ramène ce nombre à 32 tuiles et réduit le temps d'inférence d'un facteur 4, au prix d'une perte de détail acceptable pour les classes cibles.

_NB : SAM3 redimensionne automatiquement grandes les images sur une résolution autour de 1024px, donc il n'y pas d'intêret d'aller au-delà._

=== Distorsion équirectangulaire

Les images équirectangulaires présentent une distorsion géométrique croissante vers le zénith et le nadir. Les objets cibles (panneaux, marquages) se concentrent dans la bande centrale de l'image, correspondant à ±30° d'élévation, là où la distorsion est minimale. La correction de projection n'est donc pas implémentée, elle apporterait un gain marginal pour un coût d'implémentation élevé. Le bas du panorama est en grande partie occulté par la carrosserie du véhicule. Ce choix est documenté comme limitation connue.

== Calcul distribué : Ray

Ray est un framework Python open-source pour distribuer des workloads ML/IA sur des clusters hétérogènes CPU/GPU @ray. Il expose deux primitives fondamentales.

Une `task` (`@ray.remote` sur une fonction) est une unité de calcul sans état, exécutée de façon asynchrone sur un worker disponible.

Un `Actor`(`@ray.remote` sur une classe) est une unité de calcul avec état, maintenu en mémoire sur un worker assigné. L'Actor est LE patron adapté au chargement de modèles. Le modèle est chargé une fois dans `__init__`, puis réutilisé sur toutes les requêtes sans rechargement, évitant les erreurs de mémoire insuffisante (OOM) qui surviennent lorsqu'un modèle est rechargé à chaque tâche.

```python
@ray.remote(num_gpus=1)
class SAM3Worker:
    def __init__(self):
        self.model = load_sam3()   # chargé une fois

    def process(self, batch):
        return infer(self.model, batch)
```

Ray gère l'allocation des ressources (CPU, GPU, mémoire), la sérialisation des données entre driver et workers via son object store partagé, et la récupération sur défaillance d'un worker.

=== KubeRay

KubeRay est l'opérateur Kubernetes officiel pour Ray @kuberay. Il introduit la ressource `RayCluster` (CRD `ray.io/v1`), qui déclare un nœud head et un ou plusieurs groupes de workers. L'opérateur crée et gère les pods correspondants, expose les ports GCS (6379), dashboard (8265), métriques (8080) et client Ray (10001) via des Services Kubernetes.

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
  caption: [Terminologie Kubernetes vs Ray]
) <tab-k8s-ray-terms>

#pagebreak()
== Stockage objet

=== MinIO

MinIO est un serveur de stockage objet compatible avec le protocole S3 @minio. La HEIG-VD l'exploite sur un NAS Synology SA3200D, installé via Container Manager avec l'image officielle `minio/minio`. Le pipeline accède à MinIO via `boto3` avec les variables d'environnement S3 standard (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT_URL`).

=== S3
S3 est un protocole, pas un produit. L'endpoint peut être remplacé sans modifier le code du pipeline. 

=== Alternatives
Des alternatives comme RustFS (Apache 2.0, moins d'un an) ou CEPH (mature, LGPL, bloc/fichier/objet) ont été évaluées. La décision est de conserver MinIO car la migration ajouterait du risque sans bénéfice immédiat, et la configuration S3 est le seul point à modifier si un changement de backend devient nécessaire.

== Format de résultats 

=== Parquet
Parquet est un format binaire orienté colonnes conçu pour les workloads analytiques @parquet. Chaque fichier est découpé en _row groups_ eux-mêmes découpés en _column chunks_. Cette organisation permet de lire uniquement les colonnes nécessaires à une requête sans charger l'ensemble du fichier.

#figure(
  image("../images/parquetFormat.png", width: 90%),
  caption: [
    Parquet exploite une solution hybride pour obtenir de meilleur performances. Source : https://towardsdatascience.com/demystifying-the-parquet-file-format-13adb0206705/
  ]
) <parquetHybrid>

Parquet stocke des statistiques min/max par column chunk. Un moteur de requête peut ainsi ignorer des row groups entiers si le prédicat tombe hors de leur plage. C'est le _predicate pushdown_, supporté nativement par PyArrow. Filtrer les polygones par zone GPS ou par seuil de score ne charge que les colonnes `latitude`, `longitude` et `score`, indépendamment du volume total.

=== PostGIS
PostGIS (extension PostgreSQL pour les données géospatiales) a été évalué comme alternative. Il offre des index spatiaux GIST et des requêtes géométriques natives (`ST_Within`, `ST_Intersects`). La décision est de le remplacer par Parquet sur S3. Les requêtes du projet ne nécessitent pas de jointures géospatiales complexes, et Parquet évite de maintenir une base de données.

#pagebreak()
=== JSON
JSON (JavaScript Object Notation) est le format accepté par labelstudio pour importer les données géospatiales sur une images. Ce format va être utiliser uniquement pour le mode `on demand` et en legacy pour labelstudio afin de visualiser les résultats des runs.

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

== Annotation 

=== Label Studio

Label Studio est une plateforme d'annotation open-source @labelstudio. Elle supporte les polygones (`polygonlabels`) sur images, le stockage S3 comme source d'images, et l'import de pré-annotations via son API REST. Le pipeline produit des pré-annotations SAM3 que des annotateurs humains corrigent et valident dans Label Studio.

Label Studio est configuré avec MinIO comme _cloud storage_ source. Les URLs `s3://nearai/...` sont converties en URLs HTTP temporaires signées, ce qui évite d'exposer les credentials de stockage aux navigateurs clients.

== Observabilité

=== Grafana
Gra

==== Loki

==== Promtail


=== Prometheus

=== DCGM
