/*
|              ██
| ████▄ ▄███▄ ▀██▀▀ ▄█▀█▄
| ██ ██ ██ ██  ██   ██▄█▀
| ██ ██ ▀███▀  ██   ▀█▄▄▄
|
| Ce fichier est basé sur du code précédemment écrit par @DACC4 et @samuelroland.
| Dépot original: https://github.com/DACC4/HEIG-VD-typst-template-for-TB
|
*/

#let config = (
  global: (
    confidential: false,
    text_lang: "fr",
  ),
  information: (
    title: "Pipeline distribuée d'annotation automatique d'images géospatiales",
    subtitle: "Accélération de l'IA par segmentation des ressources GPU",
    academic_years: "2025-26",
    departement: (
      court: "TIC",
      long: "Technologies de l'information et de la communication (TIC)",
    ),
    filiere: (
      court: "ISC",
      long: "Informatique et systèmes de communication (ISC)",
    ),
    orientation: (
      court: "ISC-RS",
      long: "Réseaux et systèmes (ISC-RS)",
    ),
    author: (
      name: "Dani Tiago Faria dos Santos",
      feminine_form: false,
    ),
    supervisor: (
      name: "Prof. Bertil Chapuis",
      feminine_form: false,
    ),
    industry_contact: (
      name: "Prof. Bertil Chapuis",
      address: [
        Route de Cheseaux 1 \
        1400 Yverdon-les-Bains
      ],
      industry_name: "HEIG-VD — Institut IICT",
    ),
    resume_publiable: [
      Ce travail conçoit et déploie une pipeline distribuée d'annotation automatique
      d'images panoramiques pour le projet européen NearAI. La pipeline exploite SAM3, un modèle
      de segmentation zero-shot, sans fine-tuning ni modification, pour détecter les
      éléments routiers ciblés par un vocabulaire de labels texte. Ray distribue le
      calcul sur les GPUs du cluster Kubernetes de la HEIG-VD : chaque panorama est
      découpé en tuiles, traitées en parallèle par des workers GPU. Les images sont
      lues depuis le stockage S3 sur MinIO, les coordonnées GPS des détections
      proviennent des fichiers de trajectoire de l'acquisition, et les résultats sont
      écrits au format Parquet sur le même bucket, puis exploités par Label Studio et
      par NearLabel pour la validation humaine.


      Le run de production sur le dataset Vevey valide la pipeline à l'échelle :
      14'207 images traitées en 10 h 23 sur trois GPUs L40S, un speed-up de 2,99×
      qui confirme le parallélisme quasi parfait de l'inférence par tuiles. Face à
      l'annotation manuelle, l'assistance réduit le temps de validation de 47 %,
      pour un coût de pré-annotation de seulement environ 22 CHF par ville de cette
      taille.


      Une couche d'observabilité basée sur Prometheus, Loki et Grafana surveille
      l'état du cluster, ses performances et ses goulots d'étranglement en production.
      La gestion chiffrée des secrets et une pipeline CI/CD, qui exécute les tests
      avant de construire et publier les images Docker, assurent la sécurité de la
      configuration et la fiabilité des déploiements.
    ],
  ),
  bibliography: (
    content: read("bibliography.yaml", encoding: none),
    style: "ieee",
  ),
)
