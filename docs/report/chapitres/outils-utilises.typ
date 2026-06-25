#let col-blue = rgb("#2563EB")
#let tfill = (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white }
#let thead(..c) = table.header(..c.pos().map(x => text(fill: white)[*#x*]))

= Outils utilisés <outils>

Ce chapitre recense les outils, librairies et services qui composent le projet, regroupés par domaine. Les numéros de version ne sont indiqués que lorsqu'ils sont figés dans les images Docker ; un tiret signale une dépendance dont la version n'est pas contrainte.

== Langage et apprentissage automatique

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [Python], [3.12], [Langage de l'ensemble du code (pipeline, API, jobs)],
    [PyTorch], [2.7.0 (CUDA 12.6)], [Moteur d'inférence GPU sous-jacent à SAM3],
    [SAM3], [—], [Modèle de segmentation de Meta, détection des objets cibles],
    [Ultralytics], [—], [Wrapper haut niveau de SAM3 pour la segmentation interactive],
    [NumPy], [≥ 1.26, < 2], [Manipulation des tableaux (masques, tuiles)],
    [SciPy], [—], [Séparation des masques en composantes connexes],
    [Pillow], [—], [Lecture et redimensionnement des images],
    [OpenCV (headless)], [—], [Vectorisation des masques en polygones],
    [exif], [—], [Extraction des coordonnées GPS depuis l'EXIF],
  ),
  caption: [Langage et briques d'apprentissage automatique],
)

== Calcul distribué et orchestration

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [Ray], [2.54.0], [Distribution de l'inférence GPU (Actors, object store)],
    [KubeRay], [—], [Opérateur Kubernetes gérant le cycle de vie du RayCluster],
    [Kubernetes], [1.33.9], [Orchestrateur du cluster `iict-rad` (pods, jobs, services)],
    [Kustomize], [—], [Composition des manifestes par composant et bump du tag d'image],
    [Longhorn], [—], [Stockage répliqué (PVC) pour le cache du modèle SAM3],
    [NVIDIA GPU Operator], [—], [Drivers GPU, device plugin et DCGM sur chaque nœud],
  ),
  caption: [Calcul distribué et orchestration Kubernetes],
)

== API et formats de données

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [FastAPI], [—], [Framework de l'API REST exposant la pipeline],
    [Uvicorn], [—], [Serveur ASGI exécutant l'application FastAPI],
    [Pydantic], [—], [Validation et sérialisation des corps de requête],
    [kubernetes (client Python)], [—], [Création des Jobs et pilotage du cluster depuis l'API],
    [boto3], [—], [Client S3 pour la lecture/écriture sur MinIO],
    [PyArrow], [—], [Lecture et écriture des fichiers Parquet],
    [DuckDB], [—], [Inspection ad hoc des sorties Parquet],
    [python-dotenv], [—], [Chargement des variables d'environnement en local],
  ),
  caption: [API REST et manipulation des données],
)

== Stockage objet et annotation

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [MinIO], [—], [Stockage objet compatible S3 (images, Parquet, logs, modèles)],
    [Parquet], [—], [Format colonnaire des prédictions du job batch],
    [Label Studio / NearLabel], [—], [Plateforme d'annotation, import des pré-annotations SAM3],
  ),
  caption: [Stockage objet et annotation],
)

== Conteneurisation et versionnage

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [Docker], [base CUDA 12.6.3 / Ubuntu 24.04], [Construction des images de la pipeline, de l'API et des jobs],
    [GitHub Container Registry], [—], [Registre privé hébergeant les images `ghcr.io/nearai-interreg/*`],
    [Git], [—], [Contrôle de version du dépôt],
  ),
  caption: [Conteneurisation et registre d'images],
)

== Observabilité

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [Prometheus], [—], [Collecte des métriques GPU (DCGM) et Ray],
    [DCGM Exporter], [—], [Exposition des métriques GPU (utilisation, VRAM, puissance, température)],
    [Grafana Loki], [—], [Agrégation des logs, indexée par labels, stockée sur MinIO],
    [Grafana Alloy], [—], [Collecte des logs des pods (successeur de Promtail)],
    [Grafana], [—], [Dashboards corrélant métriques et logs],
  ),
  caption: [Stack d'observabilité],
)

== Gestion des secrets

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [SOPS], [—], [Chiffrement des valeurs sensibles des manifestes versionnés],
    [age], [—], [Backend de chiffrement asymétrique utilisé par SOPS],
  ),
  caption: [Gestion des secrets],
)

== Rédaction et tests

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: tfill,
    thead([Outil], [Version], [Rôle]),
    [Typst], [—], [Composition du présent rapport],
    [Zotero], [—], [Gestion de la bibliographie],
    [Bruno], [—], [Tests manuels des endpoints de l'API],
  ),
  caption: [Rédaction du rapport et tests],
)
