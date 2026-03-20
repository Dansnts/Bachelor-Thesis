# Planification préliminaire — 450 heures

**Étudiant :** Dani Tiago Faria dos Santos
**Superviseur :** Prof. Bertil Chapuis (HEIG-VD)
**Période :** 16 février → 23 juillet 2026 (22 semaines)
**Budget total : 450 heures**

---

| Sem | Heures | Tâches | Commentaires |
|-----|:------:|--------|--------------|
| 1 | 8h | Setup poste de travail + Git + outils,Rencontres superviseurs,Analyse infra existante (cluster K8s, MinIO, Label Studio),Document de compréhension du sujet (1-2p),Liste bibliographique initiale (5-10 refs),Journal de travail démarré,Brouillon cahier des charges,Planification 450h | Semaine de démarrage : tous les livrables listés ci-contre sont attendus en fin de semaine |
| 2 | 8h | Setup env dev (Python, Git, Docker),Étude Ray et SAM3,Premiers tests Ray local | |
| 3 | 8h | Installation SAM3,Premiers tests d'inférence (CPU),Préparation dataset images de test | SAM3 est lourd, prévoir du temps pour le setup CUDA |
| 4 | 8h | Prototype Ray distribué (head + workers),Parallélisation de tâches,Benchmarks | |
| 5 | 8h | Intégration Ray + SAM3,Pipeline d'inférence distribué,Gestion erreurs et retry | |
| 6 | 8h | Étude format ZARR,Convertisseur PNG/TIFF -> ZARR,Tests lecture par tuiles | ZARR permet de ne charger que les chunks nécessaires en mémoire |
| 7 | 8h | Intégration ZARR + Ray,Optimisation chunk size,Benchmark consommation mémoire | |
| **8** | **8h** | MinIO setup local,Client boto3,Tests upload/download | **JALON : Remise cahier des charges (09 avril)** |
| 9 | 8h | Pipeline lecture images depuis MinIO,Stockage ZARR sur MinIO,Tests S3->ZARR->Ray->SAM3 | |
| 10 | 8h | Setup PostgreSQL + PostGIS,Schéma DB (geom GEOMETRY POLYGON 4326),Index GIST | |
| 11 | 8h | Intégration SAM3 -> PostGIS,Insertion polygones,Validation requêtes spatiales | |
| 12 | 8h | Dockerisation complète (SAM3, Ray workers, PostGIS),docker-compose,Tests intégration | |
| 13 | 8h | K8s manifests (Job, Deployment, Service, PVC),Tests locaux avec Minikube,Préparation rapport intermédiaire | |
| **14** | **8h** | Remise rapport intermédiaire,Feedback superviseurs | **JALON : Remise rapport intermédiaire (20 mai avant 15h00)** |
| 15 | 8h | Intégration Label Studio API,Export annotations JSON,Ajustements post-feedback | |
| 16 | 8h | Tests E2E pipeline complet (local),Corrections bugs,Optimisations performance | |
| 17 | 8h | Préparation déploiement HEIG,Documentation deployment,Tests Minikube finaux | |
| **18** | **63h** | Déploiement sur cluster HEIG K8s,Configuration GPU resources,Premiers runs sur cluster | **JALON : TB à plein temps (15 juin)** — sprint final, ~9h/jour |
| 19 | 63h | Tests GPU cluster,Benchmarks performance end-to-end,Tuning,Validation pipeline complet | |
| 20 | 63h | Rédaction rapport : Introduction, contexte, architecture, choix techniques | |
| 21 | 63h | Rédaction rapport : Implémentation, résultats, benchmarks, conclusions | |
| **22** | **62h** | Finalisation rapport,Résumé publiable,Relecture,Soumission GAPS | **JALON : Remise rapport final (23 juillet avant 11h00)** |
| | **450h** | | |

---

## Jalons principaux

| Date | Jalon | État attendu du pipeline |
|------|-------|--------------------------|
| **09 avril 2026** | Remise cahier des charges | SAM3 + Ray fonctionnels localement, ZARR intégré |
| **20 mai 2026** | Remise rapport intermédiaire | Pipeline E2E local complet (MinIO + Ray + ZARR + SAM3 + PostGIS + Docker) |
| **23 juillet 2026** | Remise rapport final | Pipeline déployé sur cluster HEIG K8s avec GPU |
| **Août–Sept 2026** | Soutenance | Démo live du pipeline |
