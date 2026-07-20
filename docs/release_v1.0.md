# Checklist release 1.0 — jeudi 16.07 (tests) / vendredi 17.07 (finalisation)

## Préalable (dès que possible)

- [x] `git push` des commits en attente (refactor jobCore + durcissement API) pour déclencher le build des 4 images. *(15.07, Tests + Build verts sur e50a0e8)*
- [x] VPN actif, puis rollout de l'API : `kubectl -n dani rollout restart deployment/sam3-api`. *(16.07 ; contexte kubectl `iict-rad`, le contexte `default` sur 10.0.0.20 ne passe pas par le VPN)*
- [x] **Redémarrer aussi le head Ray et le segment** après un build : `kubectl -n dani delete pod -l ray.io/node-type=head` + `rollout restart deployment/sam3-segment`. Leçon du 16.07 : le head tournait sur l'ancienne image, sans les nouveaux helpers jobCore → le premier batch a échoué en `AttributeError` au dépickling de l'actor. À refaire vendredi après le build 1.0.

## Jeudi — tests de bout en bout

### Local (sans cluster)

- [x] Suite unitaire : `.venv/bin/pytest tests/unit` → **183 passed, 0 xfail** (16.07).

### Console web (`/ui`)

- [ ] La page tient sans refresh (polling toutes les 4–10 s, pas de gel).
- [ ] Liens **Dashboard** (Grafana) et **Bucket S3** (console MinIO :9090) visibles et fonctionnels.
- [ ] `/status` répond vite (< 1 s, plus les ~27 s d'avant le fix S3).
- [ ] Un job en file d'attente GPU s'affiche **Pending**, un job qui tourne **Running**.
- [ ] Un batch qui échoue puis se relance repasse en **Running** (plus de badge Failed collé).
- [ ] Import Label Studio : un nom avec un slash est refusé avec le message explicite.

### API (curl ou Bruno)

- [x] `POST /jobs/batch` avec `labels: []`, `numWorkers: 0`, `tileSize: -512`, `downsample: 5.0`, `tileStride > tileSize`, `batchSize: 0` + solo `tileSize: 0` → **422 à chaque fois (7/7, 16.07)**.
- [x] `GET /config` renvoie les deux URLs (Grafana + console MinIO :9090).
- [x] `GET /health` → ok.
- [x] `GET /jobs/` en 0,14 s, `GET /jobs/<name>/status` en 0,39 s.

### Pipeline

- [x] Run **solo** sur une image (`sam3-solo-acbaa425`, Nyon ladybug) : Succeeded, 8 détections, `/result` renvoie les tâches Label Studio **avec score**.
- [x] Run **batch** court (`sam3-batch-4165cee7`, 40 images test-pipeline) : Succeeded, progression % visible dans les logs et `/status` (100 %, 40/40), 40 parquet + `params.json` + `dataset_info.txt` écrits, 176 s wall (2,8 s/image côté worker), 523 détections.
- [x] Reprise sur échec vérifiée en réel : le batch `sam3-batch-f947abff` a échoué 4× sur le head obsolète, puis son 5e pod (retry du Job k8s) a réussi après le redémarrage du head → statut final Succeeded, l'API le reflète correctement.
- [x] Import Label Studio d'un run : 40 tâches, **score présent sur chaque pré-annotation**, dimensions originales correctes (8000×4000).
- [x] CLI : `nearai jobs`, `nearai status <job>` ok ; `nearai import` renvoie un 404 explicite quand aucun parquet n'existe sous le chemin conventionnel. *(le --watch et un import CLI sur une vraie acquisition restent à faire à l'occasion)*
- [x] `POST /segment/down` (0/0), `POST /segment/up` (1/1), une segmentation interactive par clic → polygone « road » renvoyé.

## Vendredi — versions finales 1.0

- [x] GitHub Actions : tests → build chaînés (16.07) : `tests.yml` est réutilisable (`workflow_call`) et `build-images.yml` l'appelle dans un job `test` dont `prepare` dépend ; en bonus un input `tag` au dispatch pour pousser un tag de release (défaut `staging`).
- [x] Vérifier que le workflow tests passe vert sur le push du refactor. *(vert sur e50a0e8)*
- [x] Tagger les 4 images en `1.0` (16.07, copie de manifest ghcr : les digests `1.0` sont exactement ceux testés le matin) et manifests kustomize bumpés (`newTag: "1.0"` + les env SOLO_IMAGE/BATCH_IMAGE de l'API).
- [ ] Rollout final **API + head Ray + segment** (cf. leçon du 16.07) + re-smoke rapide (console, un solo, un batch court).
- [ ] Tag git `v1.0`.
- [ ] Passe sécurité : aucun secret ni clé age dans le repo, chiffres confidentiels absents (déjà vérifié le 15.07, revérifier après les derniers commits).
