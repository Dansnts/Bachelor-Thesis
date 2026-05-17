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
      Ce travail porte sur la conception et le déploiement d'une pipeline distribuée
      d'annotation automatique d'images géospatiales. La pipeline exploite SAM3 pour
      la segmentation et Ray pour distribuer le traitement sur les GPUs du cluster
      Kubernetes de la HEIG-VD. Les images sont lues depuis le service S3 sur MinIO, découpées en
      patches et traitées en parallèle par des workers Ray. Les métadonnées GPS extraites
      de l'EXIF sont associées aux polygones produits, stockés au format Parquet sur S3.
      Une couche d'observabilité basée sur Prometheus, Loki et Grafana permet de surveiller
      l'état du cluster, ses performances et d'identifier les incidents.

      #v(0.8em)
      #block(
        fill: rgb("#FFFBEB"),
        stroke: (left: 3pt + rgb("#F59E0B")),
        inset: (x: 10pt, y: 8pt),
        radius: 3pt,
        width: 100%,
      )[
        *Rapport intermédiaire* : Les images, diagrammes, tableaux et contenus sont incomplets et susceptibles d'être modifiés.
      ]
    ],
  ),
  bibliography: (
    content: read("bibliography.yaml", encoding: none),
    style: "ieee",
  ),
)
