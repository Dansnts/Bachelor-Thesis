# Planification — 450 heures

**Étudiant :** Dani Tiago Faria dos Santos
**Superviseur :** Prof. Bertil Chapuis (HEIG-VD)
**Période :** 16 février --> 23 juillet 2026 (22 semaines)
**Budget total : 450 heures**

---

| Sem | Heures | Tâches | État |
|-----|:------:|--------|------|
| 1 | 8h | Setup poste de travail, Git, outils. Rencontres superviseurs. Analyse infra existante (K8s, MinIO, Label Studio). Brouillon cahier des charges. Planification 450h. | Terminé |
| 2 | 8h | Setup environnement dev (Python, Docker). Étude Ray et SAM3. Analyse stockage (MinIO, RustFS, CEPH). | Terminé |
| 3 | 8h | Dockerfile SAM3 (CUDA 12.6). Inférence GPU validée sur K8s. Rédaction spécifications. | Terminé |
| 4 | 8h | Cluster Ray manuel (head + 3 workers GPU). Wordcount MapReduce. Dog classifier 5000 images. Dashboard Ray via Ingress. | Terminé |
| **5** | **8h** | **Intégration Ray + SAM3. Pipeline d'inférence distribué. Extraction GPS EXIF.** | En cours |
| 6 | 8h | Client boto3. Lecture images JPEG depuis MinIO. Découpage en tuiles (PIL). Tests S3 --> tuiles --> Ray --> SAM3. | |
| 7 | 8h | Écriture résultats Parquet sur S3. Schéma : polygones + métadonnées GPS. Tests lecture analytique. | |
| **8** | **8h** | **Finalisation cahier des charges. Intégration Label Studio : connexion MinIO S3 + push pré-annotations via API.** | **JALON : Remise cahier des charges (09 avril)** |
| 9 | 8h | Stack observabilité : Prometheus, DCGM Exporter, Pushgateway, Promtail, Loki, Grafana. Déploiement K8s. | |
| 10 | 8h | Dashboards Grafana : métriques Ray, GPU, pipeline. Tests corrélation métriques/logs. | |
| 11 | 8h | Dockerisation complète du pipeline. Tests intégration E2E local. Gestion erreurs par image. | |
| 12 | 8h | Manifestes Kubernetes finaux (Jobs, Services, ConfigMaps). Rapport de traitement automatique. | |
| 13 | 8h | Tests E2E pipeline complet. Corrections bugs. Préparation rapport intermédiaire. | |
| **14** | **8h** | **Remise rapport intermédiaire. Feedback superviseurs.** | **JALON : Remise rapport intermédiaire (20 mai avant 15h00)** |
| 15 | 8h | Ajustements post-feedback. Optimisations performance. Benchmarks locaux. | |
| 16 | 8h | ZARR (optionnel) : évaluation sur images volumineuses. Documentation déploiement. | |
| 17 | 8h | Préparation déploiement cluster HEIG. Tests finaux en local. | |
| **18** | **63h** | Déploiement cluster HEIG K8s. Configuration GPU. Premiers runs sur cluster réel. | **JALON : TB à plein temps (15 juin)** |
| 19 | 63h | Tests GPU cluster. Benchmarks E2E. Tuning. Validation pipeline complet. | |
| 20 | 63h | Rédaction rapport : introduction, contexte, architecture, choix techniques. | |
| 21 | 63h | Rédaction rapport : implémentation, résultats, benchmarks, conclusions. | |
| **22** | **62h** | **Finalisation rapport. Résumé publiable. Relecture. Soumission GAPS.** | **JALON : Remise rapport final (23 juillet avant 11h00)** |
| | **450h** | | |

---

## Jalons principaux

| Date | Jalon | État attendu du pipeline |
|------|-------|--------------------------|
| **09 avril 2026** | Remise cahier des charges | Ray + SAM3 fonctionnels sur K8s. Pipeline S3 --> tuiles --> SAM3 --> Parquet opérationnel. |
| **20 mai 2026** | Remise rapport intermédiaire | Pipeline E2E complet : MinIO, Ray, SAM3, Parquet, GPS, Label Studio, observabilité. |
| **23 juillet 2026** | Remise rapport final | Pipeline déployé sur cluster HEIG K8s avec GPU. Rapport rédigé. |
| **Août–Sept 2026** | Soutenance | Démo live du pipeline. |
