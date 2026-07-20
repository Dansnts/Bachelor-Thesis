# Déploiement

Manifestes Kubernetes et code des composants applicatifs de la pipeline, tous déployés dans le
namespace `dani` du cluster HEIG-VD.

## Structure

| Dossier | Contenu |
| --- | --- |
| `ray/` | Manifestes du `RayCluster` (KubeRay) : head, workers GPU, cache PVC, dashboard, ingress |
| `api/` | API FastAPI (`python/main.py`) : console web `/ui`, endpoints REST, construit dynamiquement les Jobs K8s des runs batch/solo |
| `jobs/jobCore/` | Librairie partagée par `batch/` et `solo/` : client S3, tuilage, worker SAM3, post-traitement, export Label Studio |
| `jobs/batch/` | Driver Ray (Job K8s sans GPU) : distribue un préfixe S3 sur les workers du RayCluster |
| `jobs/solo/` | Job K8s à GPU unique : traite une image de bout en bout, sans passer par le RayCluster |
| `segment/` | Service de segmentation interactive (Ultralytics), scale-to-zero hors utilisation |
| `observability/` | Prometheus, Loki, Grafana Alloy, Grafana (dashboards provisionnés en GitOps) |
| `secrets/` | Secrets K8s chiffrés avec SOPS + age, voir [`secrets/README.md`](secrets/README.md) |

## Déployer

```sh
./deploy.sh
```

Déchiffre et applique les secrets SOPS, puis applique le reste de la stack via la
kustomization racine (`kubectl apply -k deploy/`). Les secrets sont volontairement exclus de
cette kustomization : `kubectl apply -k deploy/` seul ne peut ni échouer sur un secret chiffré
ni en publier un par erreur.

Le tag des images internes (`sam3-api`, `sam3-segment`, `ray-sam3`) se change une seule fois,
dans [`kustomization.yaml`](kustomization.yaml) (`images:`). Les variables `BATCH_IMAGE` et
`SOLO_IMAGE` du déploiement API doivent être bumpées séparément : le transformer `images` de
kustomize ne réécrit pas les chaînes dans les variables d'environnement.

Après un nouveau build d'image, redémarrer le head Ray et le service de segmentation pour
qu'ils repartent sur la nouvelle image (`kubectl apply -k deploy/` seul ne les recrée pas) :

```sh
kubectl -n dani delete pod -l ray.io/node-type=head
kubectl -n dani rollout restart deployment sam3-segment
```

## CI/CD

`.github/workflows/tests.yml` fait tourner la suite unitaire (`tests/unit`) sur chaque push et
pull request touchant le code Python. `build-images.yml` l'appelle comme workflow réutilisable
avant de construire et publier les 4 images sur `ghcr.io/nearai-interreg/*` : aucune image
n'est construite si la suite est rouge.
