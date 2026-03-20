# Cahier des charges : Travail de Bachelor

**Auteur :** Dani Tiago Faria dos Santos
**Superviseur :** Prof. Bertil Chapuis (HEIG-VD)
**Institut :** IICT - Institut des Technologies de l'information et de la Communication
**Orientation :** Réseaux et systèmes
**Date :** 27 février 2026

---

## Résumé

Ce travail de Bachelor porte sur la conception et le déploiement d'un pipeline
d'annotation automatique d'images géospatiales à l'aide du modèle SAM3, sur le cluster Kubernetes de la HEIG-VD.

TODO : compléter avec les objectifs spécifiques du projet, les méthodes utilisées, et les résultats attendus.

---

## 1. Introduction

### 1.1 Contexte

La HEIG-VD dispose d'un cluster Kubernetes équipé de GPUs permettant d'exécuter des charges de calcul intensif. Dans le cadre de projets liés à l'analyse d'images géospatiales (images satellitaires ou aériennes), il est nécessaire de disposer d'un pipeline automatisé d'annotation d'images capable de traiter de grands volumes de données efficacement.

Actuellement, les données d'images sont stockées sur un serveur MinIO compatible S3, et les annotations sont gérées via Label Studio. Le modèle SAM3 est utilisé pour la segmentation automatique.

### 1.2 Problématique

Le traitement de grands volumes d'images haute résolution représente un défi en termes de performance et de scalabilité. Les principales contraintes sont :

- les images sont volumineuses et ne peuvent pas être chargées entièrement en mémoire ;
- le modèle SAM3 doit être exécuté sur GPU pour des raisons de performance ;
- les résultats de segmentation sont des données géospatiales (polygones) qui doivent être stockées et requêtées efficacement ;
- la solution doit être scalable et déployable sur le cluster existant.

### 1.3 Périmètre du travail

Ce cahier des charges définit le périmètre, les objectifs, les exigences et l'architecture du pipeline à développer dans le cadre de ce travail de Bachelor. Il constitue le document de référence entre l'étudiant et le professeur responsable.

---

## 2. Objectifs

### 2.1 Objectif principal

Concevoir, implémenter et déployer un pipeline distribué d'annotation automatique d'images géospatiales par IA, capable d'exploiter les ressources GPU du cluster Kubernetes de la HEIG-VD.

### 2.2 Objectifs secondaires

1. **Évaluation du stockage objet**
   Analyser et évaluer les alternatives à MinIO (RustFS, CEPH) en termes de performance, de licence et d'intégration avec l'infrastructure existante.

2. **Traitement distribué des images**
   Mettre en place un pipeline Ray capable de distribuer le traitement des images sur plusieurs GPUs en parallèle.

3. **Optimisation du chargement des images**
   Intégrer ZARR pour la conversion et la lecture par tuiles des images, afin de réduire la consommation mémoire et d'améliorer les performances.

4. **Persistance des résultats géospatiaux**
   Stocker les polygones issus de la segmentation dans une base de données PostgreSQL avec l'extension PostGIS.

5. **Intégration avec Label Studio**
   Exporter ou synchroniser les annotations produites automatiquement vers Label Studio pour permettre la validation humaine.

6. **Déploiement sur Kubernetes**
   Packager et déployer l'ensemble du pipeline sous forme de ressources Kubernetes (Pods, Jobs, ou Deployments).

### 2.3 Hors périmètre

Les éléments suivants sont explicitement hors du périmètre de ce travail :

- le réentraînement ou la modification du modèle SAM3 ;
- le développement d'une interface utilisateur de visualisation ;
- la gestion de la sécurité et des accès au cluster (supposée existante).

---

## 3. Exigences

### 3.1 Exigences fonctionnelles

| Description | Priorité |
|-------------|----------|
| Le système doit pouvoir lire des images au format PNG et TIFF depuis un stockage S3. | Haute |
| Le système doit convertir les images en format ZARR pour un accès par tuiles. | Haute |
| Le système doit exécuter le modèle SAM3 sur chaque tuile d'image. | Haute |
| Le système doit stocker les polygones de segmentation dans PostgreSQL/PostGIS. | Haute |
| Le système doit distribuer le traitement sur plusieurs workers Ray. | Haute |
| Le système doit permettre d'exporter les annotations vers Label Studio. | Moyenne |
| Le système doit fournir un rapport de traitement (nombre d'images, durée, erreurs). | Moyenne |
| Le système doit gérer les erreurs de traitement par image sans interrompre le pipeline. | Haute |

### 3.2 Exigences non fonctionnelles

| Description | Priorité |
|-------------|----------|
| Le pipeline doit être déployable sur le cluster Kubernetes de la HEIG-VD. | Haute |
| Le système doit exploiter les GPUs disponibles sur le cluster. | Haute |
| Le traitement d'un lot d'images doit être scalable horizontalement. | Haute |
| Les composants doivent être conteneurisés (Docker). | Haute |
| Le code source doit être versionné sur Git et documenté. | Haute |
| La solution de stockage objet retenue doit être compatible avec le protocole S3. | Haute |
| Le système ne doit pas charger une image entière en mémoire vive. | Moyenne |

---

## 4. Architecture du système

### 4.1 Vue d'ensemble

Le pipeline devra être composée de :

### 4.2 Flux de traitement

Le flux de traitement d'une image suit les étapes suivantes :

1. A
2. B
3. C

### 4.3 Composants

| Composant | Technologie | Rôle |
|-----------|-------------|------|
| Stockage objet | MinIO | Stockage des images brutes et ZARR |
| Processing | Ray | Orchestration du traitement parallèle sur GPU |
| Modèle IA | SAM3 | Segmentation automatique des images |
| Base de données | PostgreSQL + PostGIS | Stockage des polygones géospatiaux |
| Orchestration | Kubernetes | Déploiement, scaling, gestion des Pods |
| Annotation | Label Studio | Validation humaine des annotations |

---

## 5. Technologies retenues

### 5.1 Traitement distribué : Ray

Ray est un framework Python de calcul distribué orienté charges GPU et workflows IA. Contrairement à Spark (orienté données structurées), Ray est nativement conçu pour distribuer des inférences de modèles sur GPU, ce qui en fait le choix naturel pour ce projet.

### 5.2 Format de données : ZARR

ZARR est un format de tableau N-dimensionnel orienté chunking. Il permet de lire une image par tuiles sans la charger entièrement en mémoire, ce qui est critique pour des images haute résolution. Il est complémentaire à Ray : chaque worker lit uniquement les tuiles qui lui sont assignées.

### 5.3 Stockage objet : à évaluer

Deux alternatives à MinIO sont à évaluer dans le cadre de ce TB :

- **RustFS** : alternative S3-only, licence Apache 2.0, migration simple depuis MinIO. Moins mature que MinIO mais potentiellement plus performant.
- **CEPH** : solution généraliste (bloc, fichier, objet), très mature, mais complexe à administrer. Pertinent si un cluster CEPH existe déjà.

La décision finale sera documentée dans le rapport.

### 5.4 Base de données : PostgreSQL + PostGIS

PostgreSQL avec l'extension PostGIS permet de stocker les polygones issus de la segmentation avec leurs coordonnées géospatiales. L'index spatial GIST permet des requêtes géographiques performantes.

Le schéma de base attendu :
- table `annotations` avec colonne `geom GEOMETRY(POLYGON, 4326)`
- index `GIST` sur la colonne géométrique

### 5.5 Orchestration : Kubernetes

Le cluster Kubernetes de la HEIG-VD est l'environnement cible de déploiement. Le pipeline sera packagé sous forme de manifestes Kubernetes (Jobs Ray, Deployments).

### 5.6 Modèle : SAM3

SAM3 (Segment Anything Model v3) est le modèle de segmentation retenu. Il sera utilisé en inférence uniquement (pas de réentraînement).

---

## 6. Planning et livrables

Voir `planification.md` pour la décomposition détaillée des 450 heures.

### 6.1 Jalons officiels HEIG

| Date | Jalon |
|------|-------|
| 16 février 2026 | Début du TB |
| **09 avril 2026** | **Remise cahier des charges** |
| **20 mai 2026 avant 15h00** | **Remise rapport intermédiaire** |
| 29 mai 2026 | Note rapport intermédiaire |
| 15 juin – 23 juillet 2026 | TB à plein temps |
| **23 juillet 2026 avant 11h00** | **Remise rapport final + résumé (GAPS)** |
| 24 août – 11 septembre 2026 | **Soutenance** |

### 6.2 Livrables

1. **Cahier des charges** : 09 avril 2026
2. **Rapport intermédiaire** : 20 mai 2026
3. **Code source** : Repository Git (Ray, SAM3, ZARR, MinIO, PostGIS, K8s)
4. **Rapport de Bachelor** : 23 juillet 2026
5. **Résumé publiable** : 23 juillet 2026
6. **Présentation orale** : août/septembre 2026

### 6.3 Risques et mitigations

| Risque | Impact | Mitigation |
|--------|--------|-----------|
| SAM3 inférence trop lente sur GPU | Critique | Optimisation ONNX, quantisation, réduction résolution |
| Cluster K8s HEIG indisponible avant juin | Critique | Développement local avec Minikube |
| Images trop volumineuses pour la mémoire | Moyen | Tuning ZARR chunk size, downsampling |
| PostGIS requêtes lentes sur gros volumes | Moyen | Index GIST, batch inserts |

---

## Glossaire

| Terme | Définition |
|-------|------------|
| **Kubernetes** | Système d'orchestration de conteneurs open-source |
| **Ray** | Framework Python de calcul distribué, optimisé pour les workloads GPU et IA |
| **ZARR** | Format N-dimensionnel orienté chunking pour la lecture partielle de grandes images |
| **SAM3** | Segment Anything Model v3 : modèle de segmentation d'images de Meta AI |
| **MinIO** | Serveur de stockage objet haute performance compatible S3 |
| **PostgreSQL** | Système de gestion de base de données relationnelle open-source |
| **PostGIS** | Extension PostgreSQL pour les types et fonctions géospatiales |
| **Label Studio** | Plateforme open-source d'annotation de données pour le machine learning |
| **Pod** | Unité de déploiement atomique dans Kubernetes |
| **S3** | Simple Storage Service : protocole de stockage objet d'Amazon |
| **GPU** | Graphics Processing Unit |
