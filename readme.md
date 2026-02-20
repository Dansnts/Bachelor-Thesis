# Pipeline Distribué d'Annotation d'Images Panoramiques par IA

## Contexte :

L'annotation automatique d'objets dans de vastes collections d'images panoramiques haute définition est une tâche complexe nécessitant une puissance de calcul importante. Ce projet vise à concevoir et implémenter un pipeline de traitement distribué, exploitant le modèle d'IA SAM3 (Segment Anything Model 3), pour générer des annotations vectorielles de haute qualité sur 300 000 images. Le déploiement s'effectuera sur le cluster Kubernetes de l'école en utilisant le framework Ray pour orchestrer les calculs.

## Objectif :

Développer une plateforme robuste et optimisée capable d'ingérer des images HD (ex : 8000x4000 pixels), d'exécuter à grande échelle un modèle de segmentation avancé (SAM3), et de stocker les annotations géométriques résultantes dans une base de données géospatiale, tout en étudiant les compromis performance/qualité via des techniques de réduction de résolution (downsampling).

## Travail attendu :

L’étudiant devra :
* Déployer et configurer un environnement de calcul distribué avec Ray sur Kubernetes pour orchestrer les traitements.
* Intégrer le modèle SAM3 au sein de tâches Ray et concevoir un pipeline efficace pour l'annotation par lots.
* Mettre en place un stockage objet compatible S3 pour les images sources, les images intermédiaires (downsamplées) et les masques bruts.
* Implémenter une stratégie de prétraitement incluant un downsampling contrôlé et analyser son impact sur la qualité des annotations générées et les performances du système.
* Développer un module de post-traitement pour convertir les sorties de SAM3 (masques) en géométries vectorielles (polygones) propres.
* Concevoir et peupler un schéma de base de données PostgreSQL/PostGIS adapté au stockage et à l'interrogation spatiale des annotations et de leurs métadonnées.
* Évaluer l'ensemble du pipeline en termes de scalabilité, de précision et d'efficacité des ressources.

## Livrables :

* Pipeline de traitement distribué complet et fonctionnel, de l'ingestion S3 à l'écriture dans la base de données.
* Base de données PostGIS contenant un jeu d'annotations de démonstration géoréférencées.
* Étude comparative documentée sur les stratégies de downsampling (qualité vs. performance).
* Scripts de déploiement, de monitoring et de validation des résultats.
* Rapport final détaillant l'architecture, les choix techniques, l'analyse des performances et les recommandations pour un passage à l'échelle supérieure.

## Compétences développées :

Traitement distribué (Ray), inférence de modèles d'IA à grande échelle, optimisation de pipelines de données, gestion de bases de données géospatiales (PostGIS), stockage cloud (S3), orchestration conteneurisée (Kubernetes), analyse de compromis performance/précision.

---
## Journal
[Journal](/docs/journal.md)


## Cahier des charges
[Cahier des charges](/docs/specifications.md)

## Notes
[Notes](/docs/notes.md)

--- 
## Calendrier
![Calendrier](/docs/planning.png)
