# Cahier des charges :Travail de Bachelor

**Auteur :** Dani Tiago Faria dos Santos
**Superviseur :** Prof. Bertil Chapuis (HEIG-VD)
**Institut :** IICT - Institut des Technologies de l'information et de la Communication
**Orientation :** Réseaux et systèmes
**Date :** 27 février 2026

---

## Résumé

Ce travail conçoit et déploie un pipeline d'annotation automatique d'images géospatiales sur le cluster Kubernetes de la HEIG-VD, en utilisant le modèle SAM3. Le pipeline expose des métriques d'observabilité pour surveiller l'utilisation des ressources et guider l'optimisation.

---

## 1. Introduction

### 1.1 Contexte

La HEIG-VD dispose d'un cluster Kubernetes équipé de GPUs. Dans le cadre de projets d'analyse d'images géospatiales, ce cluster doit supporter un pipeline d'annotation automatique capable de traiter de grands volumes d'images haute résolution.

Les images sont stockées sur un serveur MinIO (NAS Synology, protocole S3) et les annotations sont gérées via Label Studio. Le modèle SAM3 assure la segmentation automatique.

### 1.2 Problématique

Le traitement de grands volumes d'images haute résolution représente un défi en termes de performance et de scalabilité. Les principales contraintes sont :

- les images haute résolution dépassent la capacité mémoire d'un seul nœud ;
- SAM3 requiert un GPU pour fonctionner à une vitesse acceptable ;
- les résultats de segmentation doivent être persistés et accessibles pour traitement ultérieur ;
- le pipeline doit être scalable sur le cluster existant ;
- le pipeline doit exposer des métriques pour surveiller l'utilisation du matériel et des modèles.

### 1.3 Périmètre du travail

Ce document définit le périmètre, les objectifs, les exigences et l'architecture du pipeline. Il constitue la référence entre l'étudiant et le superviseur.

---

## 2. Objectifs

### 2.1 Objectif principal

Concevoir, implémenter et déployer un pipeline distribué d'annotation automatique d'images géospatiales, exploitant les GPUs du cluster Kubernetes de la HEIG-VD. Le pipeline expose des métriques d'observabilité pour surveiller et optimiser l'utilisation de l'infrastructure.

### 2.2 Objectifs secondaires

1. **Stockage objet**
   Utiliser MinIO comme solution de stockage S3, déjà en place dans l'infrastructure existante.

2. **Traitement distribué des images**
   Mettre en place un pipeline Ray capable de distribuer le traitement des images sur plusieurs GPUs en parallèle.

3. **Observabilité du pipeline**
   Mettre en place des outils de monitoring pour suivre l'utilisation des ressources (GPU, mémoire, temps d'inférence) et la progression des traitements.

4. **Persistance des résultats**
   Stocker les annotations et métadonnées produites par SAM3 en fichiers Parquet sur le bucket S3.

5. **Intégration avec Label Studio**
   Exporter ou synchroniser les annotations produites automatiquement vers Label Studio pour permettre la validation humaine.

6. **Déploiement sur Kubernetes**
   Packager et déployer l'ensemble du pipeline sous forme de ressources Kubernetes (Pods, Jobs, ou Deployments).

### 2.3 Hors périmètre

- le réentraînement ou la modification du modèle SAM3 ;
- le développement d'une interface utilisateur de visualisation ;
- la gestion de la sécurité et des accès au cluster (supposée existante) ;
- l'intégration de ZARR (format de chunking N-dimensionnel) :jugé redondant pour ce TB, à évaluer en perspective future si des optimisations mémoire supplémentaires sont nécessaires.

---

## 3. Exigences

### 3.1 Exigences fonctionnelles

| Description | Priorité |
|-------------|----------|
| Le système doit pouvoir lire des images au format PNG et TIFF depuis un stockage S3. | Haute |
| Le système doit exécuter le modèle SAM3 sur les images ingérées. | Haute |
| Le système doit stocker les annotations en fichiers Parquet sur le bucket S3. | Haute |
| Le système doit distribuer le traitement sur plusieurs workers Ray. | Haute |
| Le système doit permettre d'exporter les annotations vers Label Studio. | Moyenne |
| Le système doit fournir un rapport de traitement (nombre d'images, durée, erreurs). | Moyenne |
| Le système doit exposer des métriques d'observabilité (GPU, mémoire, latence, throughput). | Haute |
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

Le pipeline est composé de ... :

### 4.2 Flux de traitement

Le flux de traitement d'une image suit les étapes suivantes :

1. A
2. B
3. C

### 4.3 Composants

| Composant | Technologie | Rôle |
|-----------|-------------|------|
| Stockage objet | MinIO | Stockage des images sources et résultats |
| Processing | Ray | Orchestration du traitement parallèle sur GPU |
| Modèle IA | SAM3 | Segmentation automatique des images |
| Stockage résultats | Parquet sur S3 | Persistance des annotations et métadonnées |
| Orchestration | Kubernetes | Déploiement, scaling, gestion des Pods |
| Management cluster | Rancher | Administration et monitoring du cluster Kubernetes |
| Observabilité | À définir (ex: Prometheus/Grafana) | Monitoring GPU, mémoire, latence |
| Annotation | Label Studio | Validation humaine des annotations |

---

## 5. Technologies retenues

### 5.1 Traitement distribué : Ray

Ray distribue des workflows Python sur GPU. Contrairement à Spark, conçu pour les données structurées, Ray est optimisé pour l'inférence de modèles, ce qui en fait le choix naturel pour ce pipeline.

### 5.2 Observabilité : à définir

Le pipeline expose des métriques en temps réel : utilisation GPU, mémoire, latence d'inférence et progression du batch. Prometheus et Grafana sont les candidats naturels dans un environnement Kubernetes ; le choix sera justifié dans le rapport.

### 5.3 Stockage objet : MinIO

MinIO est la solution de stockage objet retenue. Compatible S3, il est déjà déployé sur l'infrastructure de la HEIG-VD et partagé par d'autres projets du département.

### 5.4 Persistance des résultats : Parquet sur S3

Les annotations et métadonnées produites par SAM3 sont stockées en fichiers Parquet sur le bucket S3. Ce format columaire est nativement supporté par Ray Data, évite l'overhead d'une base de données et s'intègre directement dans le pipeline batch.

### 5.5 Orchestration :Kubernetes

Le pipeline est déployé sur le cluster Kubernetes de la HEIG-VD sous forme de manifestes (Jobs Ray, Deployments). Rancher assure l'administration et le monitoring du cluster.

### 5.6 Modèle :SAM3

SAM3 (Segment Anything Model v3) est utilisé en inférence uniquement.

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
3. **Code source** : Repository Git (Ray, SAM3, MinIO, Parquet, K8s, observabilité)
4. **Rapport de Bachelor** : 23 juillet 2026
5. **Résumé publiable** : 23 juillet 2026
6. **Présentation orale** : août/septembre 2026

### 6.3 Risques et mitigations

| Risque | Impact | Mitigation |
|--------|--------|-----------|
| SAM3 inférence trop lente sur GPU | Critique | Optimisation ONNX, quantisation, réduction résolution |
| Cluster K8s HEIG indisponible avant juin | Critique | Développement local avec Minikube |
| Images trop volumineuses pour la mémoire | Moyen | Downsampling contrôlé avant inférence |
| Fichiers Parquet trop volumineux sur S3 | Faible | Partitionnement par batch, compression Snappy |

---

## Glossaire

| Terme | Définition |
|-------|------------|
| **Kubernetes** | Système d'orchestration de conteneurs open-source |
| **Ray** | Framework Python de calcul distribué, optimisé pour les workloads GPU et IA |
| **Observabilité** | Capacité à mesurer et surveiller l'état interne d'un système via des métriques, logs et traces |
| **SAM3** | Segment Anything Model v3 : modèle de segmentation d'images de Meta AI |
| **MinIO** | Serveur de stockage objet haute performance compatible S3 |
| **Parquet** | Format de fichier columaire optimisé pour le stockage et la lecture de données analytiques |
| **Rancher** | Plateforme open-source de gestion de clusters Kubernetes |
| **Label Studio** | Plateforme open-source d'annotation de données pour le machine learning |
| **Pod** | Unité de déploiement atomique dans Kubernetes |
| **S3** | Simple Storage Service : protocole de stockage objet d'Amazon |
| **GPU** | Graphics Processing Unit |
