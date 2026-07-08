= Introduction <introduction>

== Contexte

L'Institut IICT de la HEIG-VD conduit le projet NearAI, dont l'objectif est de construire une base de données géospatiale d'éléments routiers à partir d'acquisitions mobiles. Les images sont capturées par des véhicules équipé de systèmes différents comme par exemple un Trimble MX50 ou d'une goPro Max, qui produisent des panoramas équirectangulaires allant jusqu'à 8'192 x 4'096 pixels accompagnés de coordonnées GPS enregistrées dans l'EXIF. Le jeu de données cible actuel dépasse 300'000 images.

Annoter manuellement ce volume n'est pas faisable, un annotateur humain habile et expérimenté consacrant trente secondes par image mettrait plus de 2'500 heures pour couvrir l'ensemble du corpus. L'annotation automatisée est la seule voie viable.

== Problème

Plusieures classes d'objets sont ciblées, comme par exemple, les panneaux de signalisation (`sign`) ou encore les marquages au sol (`road_marking`). Pour chaque image, la pipeline doit produire un ensemble de polygones identifiant ces objets, avec, leur classe, leur score de confiance, leurs coordonnées GPS et leurs dimensions normalisées.

Ces polygones transitent ensuite vers une plateforme de traitement d'image, où, des annotateurs humains corrigent et valident les prédictions.

Chaque image à 8'192 x 4'096 pixels dépasse la fenêtre d'entrée de tout modèle de segmentation courant. Il faut donc découper l'image en tuiles avant l'inférence. Ensuite, traiter 300'000 images en un délai raisonnable impose de distribuer le calcul sur plusieurs GPUs en parallèle.

#pagebreak()
== Objectifs

=== Traitement des images
Ce travail conçoit et déploie une pipeline distribuée couvrant les étapes suivantes :

+ Lecture des images depuis le bucket S3.
+ Découpage en tuiles 504 x 504 pixels et inférence sur chaque tuile.
+ Extraction des polygones, normalisation des coordonnées et association des métadonnées GPS issues de l'EXIF.
+ Écriture des résultats au format Parquet sur le bucket.
+ Import des pré-annotations dans Label Studio et NearLabel pour validation humaine.

Tout sera exécuté sur le cluster Kubernetes de la HEIG-VD via le framework Ray, qui distribue les tâches GPU sur les workers disponibles.

=== Côté utilisateur

Une API servira de porte d'accès aux développeurs ou utilisteurs du service pour faciliter l'accès aux services batch ou on-demand.

=== Analyse de la pipeline

La pipeline sera analysable au niveau de ses performances et état via un dashboard alimenté de logs et métriques.
