# API NearAI — Guide d'utilisation

Annotation automatique et interactive d'images via SAM3, sur le cluster `iict-rad`.

Un seul point d'entrée : **`http://sam3-api.iict-rad.iict-heig-vd.in`**

L'API expose deux familles de fonctions :
- **Annotation** par **labels texte**, via des Jobs Kubernetes (asynchrone) ;
- **Segmentation interactive** par **points** (synchrone) — l'API relaie vers un service GPU interne (`sam3-segment`, non exposé publiquement).

> **Prérequis**
> - Être connecté au **VPN HEIG-VD** (sinon les hosts ne résolvent pas).
> - Les URLs sont en **HTTP** (pas HTTPS).
> - Le champ `url` / `imageUri` est une **clé S3** dans le bucket `nearai`
>   (ex. `data/acquisitions/.../image.jpg`), **pas** un lien de la console MinIO.

---

## 1. Annotation par labels (`sam3-api`)

On décrit **ce qu'on cherche** par du texte (« sign », « road_marking »…) et SAM3 trouve **toutes les instances** du concept dans l'image. Le traitement est **asynchrone** : on soumet un job, on suit son état, puis on récupère le résultat.

### Workflow

```
POST /jobs/solo   →  { "job_name": "sam3-solo-xxxx", "status": "submitted" }
GET  /jobs/{name} →  suivre l'état jusqu'à "Succeeded"
GET  /jobs/{name}/result  →  le JSON Label Studio
```

### 1.1 Soumettre une image — `POST /jobs/solo`

**Body :**

| Champ | Type | Description |
|-------|------|-------------|
| `imageUri` | string | clé S3 de l'image |
| `s3Bucket` | string | bucket (`nearai`) |
| `labels` | string[] | concepts à détecter |
| `tileSize` | int | taille des tuiles (défaut 1008) |
| `tileStride` | int | décalage entre tuiles (défaut 768) |

```bash
curl -X POST http://sam3-api.iict-rad.iict-heig-vd.in/jobs/solo \
  -H "Content-Type: application/json" \
  -d '{
    "imageUri": "data/acquisitions/Samples/01_images/20251210-NeoCapture-bis_S001_Trimblemx50_000001.jpg",
    "s3Bucket": "nearai",
    "labels": ["sign", "road_marking"],
    "tileSize": 1008,
    "tileStride": 768
  }'
```

**Réponse :**
```json
{ "job_name": "sam3-solo-6534d073", "status": "submitted" }
```

### 1.2 Suivre l'état — `GET /jobs/{name}`

```bash
curl http://sam3-api.iict-rad.iict-heig-vd.in/jobs/sam3-solo-6534d073
```
```json
{ "job_name": "sam3-solo-6534d073", "status": "Active" }
```
États possibles : `Pending`, `Active`, `Succeeded`, `Failed`.

### 1.3 Récupérer le résultat — `GET /jobs/{name}/result`

```bash
curl http://sam3-api.iict-rad.iict-heig-vd.in/jobs/sam3-solo-6534d073/result
```

Renvoie le JSON **prêt à importer dans Label Studio** (les polygones détectés) :
```json
[{
  "data": { "image": "data/acquisitions/.../image.jpg" },
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

> Le résultat est stocké sur S3 (`results/<job_name>.json`) → récupérable même après la fin du job.

### 1.4 À venir

- `POST /jobs/batch` — annotation d'un lot complet (préfixe S3) via le RayCluster.
- `POST /import/{acquisition_id}` — import automatique des résultats dans Label Studio.

---

## 2. Segmentation interactive

On fournit **où** se trouve l'objet (un ou plusieurs **points**) et son **label**. SAM3 détoure l'objet sous chaque point. Le label n'est **pas deviné** : il sert à étiqueter le résultat (SAM détoure, vous nommez).

C'est **synchrone et rapide** (l'API relaie vers le service GPU interne, dont le modèle reste chargé en permanence).

### `POST /segment`

**Body :**

| Champ | Type | Description |
|-------|------|-------------|
| `url` | string | clé S3 de l'image |
| `items` | objet[] | liste d'objets à détourer |
| `items[].point` | int[] | coordonnée `[x, y]` en pixels |
| `items[].label` | string | label attribué au contour |

```bash
curl -X POST http://sam3-api.iict-rad.iict-heig-vd.in/segment \
  -H "Content-Type: application/json" \
  -d '{
    "url": "data/acquisitions/20241003-Nyon/01_images/S003/20241003-Nyon_S003_ladybug5plus_000001.jpg",
    "items": [
      { "point": [4637, 2675], "label": "sign" },
      { "point": [1200, 800],  "label": "road_marking" }
    ]
  }'
```

**Réponse :**
```json
{ "results": [
  { "label": "sign",         "points": [[x%, y%], ...], "found": true },
  { "label": "road_marking", "points": [],              "found": false }
] }
```

- `points` : polygone en **pourcentage** des dimensions de l'image (format Label Studio).
- `found: false` : aucun objet détecté sous ce point (le lot continue quand même).

---

## Notes & limites

- **`labels` vs `point`** : l'API d'annotation cherche **par concept** (trouve toutes les instances). Le service interactif détoure **un objet précis** sous un point (il ne le classe pas).
- **TTL des jobs** : un job terminé est supprimé après **1 h** ; son statut (`GET /jobs/{name}`) renvoie alors 404, mais le **résultat reste sur S3**.
- **Aucune authentification** pour le moment : ne pas exposer hors du réseau HEIG-VD.
- **Clé S3 ≠ URL console** : utiliser le chemin de l'objet (`data/.../image.jpg`), pas le lien de téléchargement de la console MinIO.
