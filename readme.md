# Pipeline distribuée d'annotation automatique d'images géospatiales

Travail de Bachelor HEIG-VD (filière ISC, orientation ISC-RS) — projet NearAI, IICT.

Des véhicules équipés de caméras panoramiques produisent un corpus visé de 300'000 images
équirectangulaires haute définition. Ce dépôt contient la pipeline qui détoure et étiquette
automatiquement les objets de la voirie (panneaux, marquages au sol, bouches d'égout) sur ce
corpus, à l'aide du modèle de segmentation **SAM3** (Meta) distribué sur les GPUs du cluster
Kubernetes de la HEIG-VD via **Ray**.

Le rapport complet (architecture, choix techniques, benchmarks, analyse des coûts) est dans
[`docs/report`](docs/report), compilé en PDF à [`docs/report/tb_rapport.pdf`](docs/report/tb_rapport.pdf).
Ce README documente uniquement la structure du dépôt et comment faire tourner le code.

## Architecture en bref

Chaque image est découpée en tuiles avec recouvrement, inférée par SAM3 en mode *prompt*
(une requête par label du vocabulaire), puis les masques sont vectorisés en polygones
géoréférencés et écrits en Parquet sur MinIO (S3). Deux modes de traitement :

- **Batch** : un `RayCluster` (KubeRay) distribue l'inférence sur les GPUs disponibles pour un
  préfixe S3 entier.
- **Solo / interactif** : un job ou un service dédié traite une image (ou un point) à la demande,
  pour la démonstration et l'intégration avec NearLabel.

Une API REST (FastAPI) pilote l'ensemble, sert une console web (`/ui`) et importe les
pré-annotations dans Label Studio / NearLabel. Prometheus, Loki et Grafana observent le cluster,
les GPUs (DCGM) et les logs applicatifs. Détails complets : chapitres Architecture et
Implémentation du rapport.

## Structure du dépôt

```
.
├── cli/                    # CLI `nearai` (push, batch, solo, status, result, jobs, import, segment)
├── deploy/
│   ├── api/                 # API FastAPI (console web /ui, endpoints REST) + manifestes K8s
│   ├── jobs/
│   │   ├── jobCore/          # Librairie partagée par batch/solo (S3, tuilage, worker SAM3, post-traitement)
│   │   ├── batch/             # Driver Ray (Job K8s CPU) : distribue un préfixe S3 sur les workers GPU
│   │   └── solo/               # Job GPU unique : traite une image
│   ├── segment/              # Service de segmentation interactive (Ultralytics, scale-to-zero)
│   ├── ray/                  # Manifestes du RayCluster (KubeRay)
│   ├── observability/        # Prometheus, Loki, Alloy, Grafana (dashboards provisionnés en GitOps)
│   ├── secrets/               # Secrets K8s chiffrés (SOPS + age), voir deploy/secrets/README.md
│   ├── kustomization.yaml    # Point d'entrée unique : `kubectl apply -k deploy/`
│   └── deploy.sh              # Déchiffre les secrets puis applique la stack
├── tests/
│   └── unit/                  # Suite pytest offline (Ray/Torch stubbés, K8s/S3 mockés)
├── docs/
│   ├── report/                 # Rapport de TB (Typst) : chapitres, bibliographie, glossaire, affiche
│   ├── journal.md               # Journal de travail hebdomadaire
│   └── ...                       # Diagrammes, notes, documents administratifs HEIG-VD
└── .github/workflows/        # CI : tests unitaires (gate) puis build/push des 4 images vers ghcr.io
```

## Démarrage rapide

Prérequis : `kubectl` configuré sur le cluster cible, [`sops`](https://github.com/getsops/sops) et
[`age`](https://github.com/FiloSottile/age) avec la clé privée du projet (voir
[`deploy/secrets/README.md`](deploy/secrets/README.md)).

```sh
# Déploie tout : secrets SOPS puis le reste de la stack (RayCluster, API, segment, observabilité)
./deploy/deploy.sh
```

Les images sont construites et publiées sur `ghcr.io/nearai-interreg/*` par la CI
(`.github/workflows/build-images.yml`), déclenchée après que la suite de tests unitaires passe.
Le tag déployé se change dans [`deploy/kustomization.yaml`](deploy/kustomization.yaml).

### CLI

```sh
pip install -r cli/requirements.txt
python cli/nearai.py --help
```

`push` envoie des images locales sur le bucket, `batch`/`solo` lancent un traitement,
`status`/`jobs` suivent la progression, `result`/`import` récupèrent ou poussent les résultats
vers Label Studio, `segment` réveille ou endort le service interactif.

### Console web et API

Une fois l'API déployée, la console de pilotage est servie sur `/ui` (par l'API elle-même, pas
de déploiement séparé), et la documentation OpenAPI interactive sur `/docs`.

## Tests

```sh
uv venv .venv
uv pip install --python .venv/bin/python -r tests/unit/requirements-test.txt
.venv/bin/python -m pytest tests/unit -q
```

Suite entièrement offline (aucun GPU, cluster ou service S3 requis), voir
[`tests/unit/README.md`](tests/unit/README.md).

## Auteur

Dani Tiago Faria dos Santos — HEIG-VD, filière ISC.
Superviseur et répondant industriel : Prof. Bertil Chapuis (IICT).
