# Analyse du stockage objet

**Auteur :** Dani Tiago Faria dos Santos
**Date :** mars 2026

---

## Contexte

Le projet repose sur un serveur MinIO exploité par l'IICT sur un NAS Synology SA3200D.
La version en production est `RELEASE.2025-04-08T15-41-24Z`.
La capacité utilisée est de 45 TB sur 80 TB disponibles, avec une bande passante réseau de 1 Gb/s.

Le changement de licence de MinIO vers AGPL v3 a conduit l'IICT à évaluer des alternatives.
L'administration confirme qu'une solution de remplacement tournera en parallèle de MinIO le temps de la transition. MinIO ne sera pas arrêté avant l'été 2026.

---

## Critères d'évaluation

| Critère | Description |
|---------|-------------|
| Licence | Compatibilité avec un usage institutionnel |
| Maturité | Stabilité en production, taille de la communauté |
| Compatibilité S3 | Support du protocole S3 sans adaptation du code |
| Migration | Complexité du passage depuis MinIO |
| Performance | Débit sur les workloads image |

---

## Alternatives évaluées

### CEPH

CEPH est une solution de stockage distribué mature sous licence LGPL.
Elle supporte les modes bloc, fichier et objet (S3).
Sa principale force est la résilience et la scalabilité horizontale.
Son principal frein est la complexité d'administration : un cluster CEPH nécessite une expertise dédiée et une infrastructure spécifique.
Cette option est pertinente uniquement si l'IICT dispose déjà d'un cluster CEPH opérationnel.

### RustFS

RustFS est une alternative S3-only écrite en Rust sous licence Apache 2.0.
Elle cible explicitement la migration depuis MinIO et expose une API compatible.
Le projet est jeune (moins d'un an au moment de cette analyse) mais affiche une adoption rapide.
L'absence d'historique en production représente un risque pour un déploiement institutionnel.

---

## Décision

MinIO est conservé pour la durée du TB.

Le pipeline ne dépend de MinIO qu'à travers le protocole S3.
Changer de solution de stockage revient à modifier uniquement la configuration de l'endpoint.
Cette abstraction rend la migration transparente pour le code du pipeline.

---

## Glossaire

| Terme | Définition |
|-------|------------|
| **MinIO** | Serveur de stockage objet compatible S3, sous licence AGPL v3 |
| **CEPH** | Système de stockage distribué open-source, licencié LGPL |
| **RustFS** | Alternative S3-only à MinIO, licenciée Apache 2.0 |
| **S3** | Protocole de stockage objet défini par Amazon Web Services |
| **AGPL** | Licence open-source qui impose la publication du code source en cas de déploiement réseau |
