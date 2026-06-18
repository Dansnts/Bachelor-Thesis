# Secrets (SOPS + age)

Les Secrets Kubernetes sont versionnés ici **chiffrés** avec [SOPS](https://github.com/getsops/sops) et [age](https://github.com/FiloSottile/age). Seules les valeurs sous `stringData` sont chiffrées (`encrypted_regex` dans `.sops.yaml`) ; le reste du manifeste reste lisible pour garder des diffs propres.

## Prérequis

```sh
brew install sops age
```

La clé privée age vit hors du dépôt, dans `~/.config/sops/age/keys.txt`. SOPS la trouve automatiquement, ou via `export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`. La clé publique (recipient) est dans `.sops.yaml`.

## Éditer un secret

```sh
sops deploy/secrets/hf-secret.enc.yaml
```

Ouvre le fichier déchiffré dans l'éditeur, le re-chiffre à la sauvegarde. C'est ainsi qu'on renseigne les vraies valeurs (ex. `HF_TOKEN`).

## Déployer

```sh
sops -d deploy/secrets/minio-secret.enc.yaml | kubectl apply -f -
```

## Secrets gérés

| Fichier | Secret | Clés | Type |
| --- | --- | --- | --- |
| `minio-secret.enc.yaml` | `minio-secret` | `access_key`, `secret_key` | Opaque |
| `hf-secret.enc.yaml` | `hf-secret` | `HF_TOKEN` | Opaque |
| `ghcr-secret.enc.yaml` | `ghcr-secret` | `.dockerconfigjson` | dockerconfigjson |

`ghcr-secret` (image pull) contient un blob JSON qu'il ne faut pas écrire à la main : on laisse `kubectl` le générer en clair, puis on le chiffre une fois.

```sh
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token> \
  -n dani --dry-run=client -o yaml > deploy/secrets/ghcr-secret.enc.yaml
sops -e -i deploy/secrets/ghcr-secret.enc.yaml
```

## Déployer tous les secrets

```sh
for f in deploy/secrets/*.enc.yaml; do sops -d "$f" | kubectl apply -f -; done
```
