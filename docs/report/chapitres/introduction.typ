= Introduction <introduction>

== Contexte

L'Institut IICT de la HEIG-VD conduit le projet NearAI, dont l'objectif est de construire une base de données géospatiale d'éléments routiers à partir d'acquisitions mobiles. Les images sont capturées par un véhicule équipé d'un système Trimble MX50, qui produit des panoramas équirectangulaires de 8 192 x 4 096 pixels accompagnés de coordonnées GPS enregistrées dans l'EXIF. Le jeu de données cible dépasse 300 000 images.

Annoter manuellement ce volume n'est pas faisable, un annotateur humain habile et expérimenté consacrant trente secondes par image mettrait plus de 2 500 heures pour couvrir l'ensemble du corpus. L'annotation automatisée est la seule voie viable.

== Problème

Plusieures classes d'objets sont ciblées, comme par exemple, les panneaux de signalisation (`sign`) et les marquages au sol (`road_marking`). Pour chaque image, le pipeline doit produire un ensemble de polygones identifiant ces objets, avec, leur classe, leur score de confiance, leurs coordonnées GPS et leurs dimensions normalisées. Ces polygones transitent ensuite vers Label Studio (ou toute autre plateforme de traitement d'image comme celle dévelopée par mon collègue Valentin Ricard), où des annotateurs humains corrigent et valident les prédictions.

Le défi technique est double. D'abord, chaque image à 8 192 x 4 096 pixels dépasse la fenêtre d'entrée de tout modèle de segmentation courant. Il faut donc découper l'image en tuiles avant l'inférence. Ensuite, traiter 300 000 images en un délai raisonnable impose de distribuer le calcul sur plusieurs GPUs en parallèle.

== Objectifs

Ce travail conçoit et déploie un pipeline distribué couvrant les étapes suivantes :

+ Lecture des images depuis MinIO (stockage objet S3-compatible).
+ Découpage en tuiles 512 x 512 pixels et inférence SAM3 sur chaque tuile.
+ Extraction des polygones, normalisation des coordonnées et association des métadonnées GPS issues de l'EXIF.
+ Écriture des résultats au format Parquet sur MinIO.
+ Import des pré-annotations dans Label Studio pour validation humaine.

En plus de cela, une API servira de porte d'accès aux développeurs ou utilisteurs du service pour faciliter l'accès aux services.

Le pipeline s'exécute sur le cluster Kubernetes de la HEIG-VD via le framework Ray, qui distribue les tâches GPU sur les workers disponibles.

== Structure du rapport

Le @etat-de-lart (état de l'art) présente les technologies retenues et les alternatives écartées. Le @architecture décrit l'architecture globale et les choix de conception. Le @implementation détaille l'implémentation du pipeline et les problèmes rencontrés. Le @resultats présente les résultats obtenus. Le @conclusion (conclusionß) dresse le bilan et identifie les travaux futurs.
