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
| 4 | 8h | Dockerfile SAM3 + build image,Push registry,Pod K8s avec GPU,Premiers tests inférence SAM3 sur cluster | HuggingFace account + accès weights SAM3 requis |
| 5 | 8h | Prototype Ray distribué (head + workers),Parallélisation de tâches,Intégration Ray + SAM3 | |
| 6 | 8h | Client S3 boto3,Connexion MinIO,Pipeline S3 -> Ray -> SAM3,Tests upload/download | |
| 7 | 8h | Scénario batch : Ray Data sur 2000 images,Stockage résultats en Parquet sur S3,Validation format | |
| **8** | **8h** | Scénario inférence à la demande,Dockerisation complète,Finalisation cahier des charges | **JALON : Remise cahier des charges (09 avril)** |
| 9 | 8h | Observabilité : Prometheus + Grafana sur K8s,Métriques GPU/mémoire/latence,Dashboards | |
| 10 | 8h | Rancher : configuration cluster,Gestion namespaces,Monitoring via Rancher UI | |
| 11 | 8h | Label Studio : intégration API,Export annotations,Tests validation humaine | |
| 12 | 8h | K8s manifests complets (Jobs Ray, Deployments, PVC),Tests intégration E2E | |
| 13 | 8h | Tests pipeline complet (2 scénarios),Corrections bugs,Préparation rapport intermédiaire | |
| **14** | **8h** | Remise rapport intermédiaire,Feedback superviseurs | **JALON : Remise rapport intermédiaire (20 mai avant 15h00)** |
| 15 | 8h | Intégration Label Studio,Export annotations,Ajustements post-feedback | |
| 16 | 8h | Optimisations performance (batch size, parallelism),Benchmarks downsampling | |
| 17 | 8h | Documentation déploiement,Validation pipeline sur cluster HEIG,Préparation sprint final | |
| **18** | **63h** | Déploiement production sur cluster HEIG,Configuration GPU,Premiers runs à grande échelle | **JALON : TB à plein temps (15 juin)** |
| 19 | 63h | Tests GPU cluster,Benchmarks E2E (scalabilité, précision, ressources),Tuning | |
| 20 | 63h | Rédaction rapport : Introduction, contexte, architecture, choix techniques | |
| 21 | 63h | Rédaction rapport : Implémentation, résultats, benchmarks, conclusions | |
| **22** | **62h** | Finalisation rapport,Résumé publiable,Relecture,Soumission GAPS | **JALON : Remise rapport final (23 juillet avant 11h00)** |
| | **450h** | | |

---

## Jalons principaux

| Date | Jalon | État attendu du pipeline |
|------|-------|--------------------------|
| **09 avril 2026** | Remise cahier des charges | SAM3 sur cluster GPU, Ray + S3 fonctionnels, scénarios batch et on-demand prototypés |
| **20 mai 2026** | Remise rapport intermédiaire | Pipeline E2E complet (MinIO + Ray + SAM3 + Parquet S3 + Observabilité + Docker + K8s) |
| **23 juillet 2026** | Remise rapport final | Pipeline déployé sur cluster HEIG K8s avec GPU |
| **Août–Sept 2026** | Soutenance | Démo live du pipeline |
