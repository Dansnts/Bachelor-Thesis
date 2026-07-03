# Ray Déploiement distribué sur K8s

## Architecture

Un cluster Ray manuel (sans KubeRay) se compose de :

| Pod | Rôle |
|---|---|
| `ray-head` | Coordinateur reçoit les jobs, distribue aux workers, expose le dashboard |
| `ray-worker` (x3) | Exécutants reçoivent et traitent les tâches `@ray.remote` |
| `wordcount` (job) | Client se connecte au head, soumet le job, affiche les résultats |

Le head n'exécute pas de tâches. Il orchestre uniquement.

---

## Protocoles de connexion

| Protocole | Port | Usage |
|---|---|---|
| GCS `host:6379` | 6379 | Connexion worker → head (interne au cluster) |
| Ray Client `ray://host:10001` | 10001 | Connexion client externe → head |
| Dashboard | 8265 | Interface web (read-only) |

**Important :** un pod client doit utiliser `ray://host:10001` (Ray Client). Utiliser `address="host:6379"` transforme le pod en worker et crashe (`Failed to connect to raylet socket`).

---

## Pièges rencontrés

### ray.init() tombe en mode local silencieusement

Si `ray://host:10001` échoue, Ray démarre un cluster local sans erreur. Symptôme : `Started a local Ray instance` dans les logs au lieu de `Connected to Ray cluster`.

Causes possibles :
- `--ray-client-server-port=10001` absent de la commande du head
- Head pas encore redémarré après ajout du flag (restartPolicy: Never → delete + apply manuel)
- Image pas rebuildée/pushée avant le delete/apply

### --ray-client-server-port=10001 obligatoire

Sans ce flag, le port client n'est pas ouvert sur le head. À ajouter dans la commande :

```
ray start --head --port=6379 --ray-client-server-port=10001 --dashboard-host=0.0.0.0 --block
```

### restartPolicy: Never

Le pod head ne redémarre pas automatiquement. Après chaque modification du YAML il faut :

```bash
kubectl delete pod ray-head -n dani --context=iict-rad
kubectl apply -f deploy/rayTemp/head.yaml --context=iict-rad
```

### Toujours rebuild + push avant delete/apply

`imagePullPolicy: Always` pull depuis le registry. Si l'image n'a pas été pushée, l'ancien code tourne.

```bash
docker build -t ray-wordcount tests/RAY/
docker tag ray-wordcount ghcr.io/nearai-interreg/ray-wordcount:latest
docker push ghcr.io/nearai-interreg/ray-wordcount:latest
```

### KubeRay non autorisé

`rayclusters.ray.io` est forbidden pour l'user `u-siwlwl3xcy`. Workaround : déploiement manuel head + workers. Mail envoyé à l'admin pour obtenir les droits.

---

## Structure des fichiers

```
deploy/rayTemp/
├── services.yaml       # ClusterIP (GCS, client, dashboard) + Ingress
├── head.yaml           # Pod head
├── worker.yaml         # Deployment 3 workers avec GPU
└── job-wordcount.yaml  # Pod client (one-shot)
```

## Déploiement

```bash
# 1. Tout déployer
kubectl apply -f deploy/rayTemp/ --context=iict-rad

# 2. Lancer un job
kubectl apply -f deploy/rayTemp/job-wordcount.yaml --context=iict-rad

# 3. Voir les logs
kubectl logs -f wordcount -n dani --context=iict-rad

# 4. Dashboard
# http://ray-dashboard.iict-rad.iict-heig-vd.in
```

## API Ray points clés

```python
# Connexion depuis un pod client
ray.init("ray://ray-head-svc:10001")

# Déclarer une fonction distante (tourne sur un worker)
@ray.remote
def ma_fonction(args):
    ...

# Lancer en parallèle (non-bloquant)
futures = [ma_fonction.remote(arg) for arg in args]

# Récupérer les résultats
results = ray.get(futures)
```

`@ray.remote` déclare la fonction comme exécutable sur un worker.
`.remote()` la soumet au cluster et retourne une référence immédiatement.
`ray.get()` attend et récupère les résultats.
