# Déployer sur un nouveau cluster (nouveaux secrets)

Ce guide s'adresse à qui reprend ce dépôt pour le déployer sur **sa propre
infrastructure**, pas sur le cluster `iict-rad` de la HEIG-VD. La clé age privée
utilisée pour ce TB n'est jamais versionnée et ne vous sera pas transmise : il
faut générer la vôtre et rechiffrer les secrets avec vos propres valeurs.

Pour éditer un secret déjà chiffré avec *votre* clé (une fois ce guide suivi une
première fois), voir [`README.md`](README.md).

## 1. Prérequis

```sh
brew install sops age
```

## 2. Générer votre paire de clés age

```sh
age-keygen -o ~/.config/sops/age/keys.txt
```

Affiche une ligne `Public key: age1...` : c'est votre clé publique (recipient).
Le fichier `~/.config/sops/age/keys.txt` contient la clé **privée**, il reste sur
votre machine, jamais dans le dépôt, jamais partagé. SOPS la trouve
automatiquement à cet emplacement (ou via `export SOPS_AGE_KEY_FILE=...` si vous
la rangez ailleurs).

## 3. Remplacer le recipient dans `.sops.yaml`

À la racine du dépôt, remplacez la clé publique existante par la vôtre :

```yaml
# .sops.yaml
creation_rules:
  - path_regex: deploy/secrets/.*\.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1votre_clé_publique_ici
```

Sans ça, SOPS continue de chiffrer pour l'ancien destinataire et vous ne pourrez
rien déchiffrer avec votre propre clé.

## 4. Adapter le namespace (si besoin)

Le namespace `dani` est fixé à deux endroits : `deploy/kustomization.yaml`
(`namespace: dani`) et `metadata.namespace` dans chaque fichier de
`deploy/secrets/`. Si vous déployez sur un autre namespace, changez les deux, ou
laissez `dani` si ça vous convient.

## 5. Créer vos secrets

Quatre secrets sont attendus. Partez d'un `stringData` en clair, remplissez vos
valeurs, puis chiffrez avec `sops -e -i`.

**`minio-secret.enc.yaml`** — vos credentials S3/MinIO :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  namespace: dani
type: Opaque
stringData:
  access_key: <votre access key>
  secret_key: <votre secret key>
```

**`hf-secret.enc.yaml`** — votre token HuggingFace (pour télécharger les poids SAM3) :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: hf-secret
  namespace: dani
type: Opaque
stringData:
  HF_TOKEN: <votre token HuggingFace>
```

**`grafana-secret.enc.yaml`** — mot de passe admin du dashboard :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: dani
type: Opaque
stringData:
  admin_password: <un mot de passe fort, généré aléatoirement>
```

Pour ces trois-là, écrivez le fichier en clair puis :

```sh
sops -e -i deploy/secrets/minio-secret.enc.yaml
sops -e -i deploy/secrets/hf-secret.enc.yaml
sops -e -i deploy/secrets/grafana-secret.enc.yaml
```

**`ghcr-secret.enc.yaml`** — accès à votre registre d'images (image pull secret),
ne s'écrit pas à la main, laissez `kubectl` générer le JSON `.dockerconfigjson` :

```sh
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io --docker-username=<votre_user> --docker-password=<votre_token> \
  -n dani --dry-run=client -o yaml > deploy/secrets/ghcr-secret.enc.yaml
sops -e -i deploy/secrets/ghcr-secret.enc.yaml
```

Si vous utilisez un autre registre que `ghcr.io`, adaptez `--docker-server` et,
côté manifestes, les références d'image dans `deploy/kustomization.yaml`.

## 6. Vérifier

```sh
sops -d deploy/secrets/minio-secret.enc.yaml
```

Doit afficher le YAML en clair avec vos vraies valeurs. Si SOPS refuse de
déchiffrer, la clé publique dans `.sops.yaml` ne correspond pas à votre clé
privée (retour à l'étape 3), ou le fichier a été chiffré avant votre changement
de recipient (re-chiffrez-le après avoir corrigé `.sops.yaml`).

## 7. Déployer

```sh
./deploy.sh
```

Déchiffre et applique les quatre secrets, puis le reste de la stack via la
kustomization racine. Voir [`../README.md`](../README.md) pour la suite
(tags d'image, redémarrage du head Ray après un nouveau build, etc.).

## Sécurité

- La clé privée age (`~/.config/sops/age/keys.txt`) ne doit **jamais** être
  commitée ni transmise par un canal non chiffré.
- Seules les valeurs sous `data`/`stringData` sont chiffrées (`encrypted_regex`
  dans `.sops.yaml`) : le reste du manifeste (kind, metadata, clés) reste
  lisible en clair dans Git, c'est voulu, ça garde des diffs propres.
- Si plusieurs personnes doivent déchiffrer, ajoutez leurs clés publiques dans
  `.sops.yaml` (`age:` accepte une liste séparée par des virgules), puis
  rechiffrez chaque secret existant (`sops updatekeys deploy/secrets/*.enc.yaml`).
