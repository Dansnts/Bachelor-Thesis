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

#import "macros.typ": *
#import "config.typ": *
#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#show: codly-init.with()

/*
                  ▄▄
       ██         ██
▄█▀▀▀ ▀██▀▀ ██ ██ ██ ▄█▀█▄
▀███▄  ██   ██▄██ ██ ██▄█▀
▄▄▄█▀  ██    ▀██▀ ██ ▀█▄▄▄
              ██
            ▀▀▀
*/

#set heading(numbering: none)

// Format level 1 headings
#show heading.where(
  level: 1,
): it => [
  #pagebreak(weak: true, to: none)
  #v(2.5em)
  #it
  \
]

#show outline.entry.where(
  level: 1,
): it => {
  if it.element.func() != heading {
    // Keep default style if not a heading.
    return it
  }

  v(20pt, weak: true)
  strong(it)
}

#let confidential_text = [
  #if config.global.confidential {
    [Confidentiel]
  }
]

// Set global page layout
#set page(
  paper: "a4",
  numbering: "1",
  header: context {
    if (not is-first-page(page)) and (not is-title-page(page)) {
      columns(2, [
        #align(left)[#smallcaps([#currentH()])]
        #colbreak()
        #align(right)[#config.information.author.name]
      ])
      hr()
    }
  },
  footer: context {
    if not is-first-page(page) {
      hr()
      columns(2, [
        #align(left)[#smallcaps(confidential_text)]
        #colbreak()
        #align(right)[#counter(page).display()]
      ])
    }
  },
  margin: (
    top: 150pt,
    bottom: 80pt,
    x: 1in,
  ),
)

// LaTeX look and feel :)
#set text(font: "New Computer Modern")
#show heading: set block(above: 1.4em, below: 1em)
#show heading.where(level: 1): set text(size: 25pt)
#set table.cell(breakable: false)
#show figure: set block(breakable: true)
#show link: underline
#set footnote.entry(gap: 0.3em, clearance: 0.5em, indent: 0.5em)

#show raw.where(block: true): block.with(
  fill: luma(240),
  inset: 10pt,
  radius: 4pt,
)

#set text(lang: config.global.text_lang)


/*
                             ▄▄
                             ██          ██   ▀▀  ██
████▄  ▀▀█▄ ▄████ ▄█▀█▄   ▄████ ▄█▀█▄   ▀██▀▀ ██ ▀██▀▀ ████▄ ▄█▀█▄
██ ██ ▄█▀██ ██ ██ ██▄█▀   ██ ██ ██▄█▀    ██   ██  ██   ██ ▀▀ ██▄█▀
████▀ ▀█▄██ ▀████ ▀█▄▄▄   ▀████ ▀█▄▄▄    ██   ██▄ ██   ██    ▀█▄▄▄
██             ██
▀▀           ▀▀▀
*/

#set par(leading: 0.55em, spacing: 1.2em, justify: true)
#image("images/HEIG-VD_logotype-baseline_rouge-cmjn.pdf", width: 6cm)
#v(10%)
#align(center, [#text(size: 14pt, [*Travail de Bachelor*])])
#v(4%)
#align(center, [#text(size: 24pt, [*#config.information.title*])])
#v(1%)
#align(center, [#text(size: 16pt, [#config.information.subtitle])])
#v(4%)
#if config.global.confidential {
  align(center, [#text(size: 14pt, [*Confidentiel*])])
} else {
  v(14pt)
}
#v(8%)

#align(left, [
  #block(
    width: 100%,
    [
      #table(
        stroke: none,
        columns: (35%, 65%),
        [*#if config.information.author.feminine_form { "Étudiante" } else { "Étudiant" }*],
        [*#config.information.author.name*],

        [], [],
        [*#if config.information.supervisor.feminine_form { "Superviseure" } else { "Superviseur" }*],
        [#config.information.supervisor.name],

        [], [],
        [*Département*], [#config.information.departement.long],
        [*Filière*], [#config.information.filiere.long],
        [*Orientation*], [#config.information.orientation.long],
        [], [],
        [*Entreprise mandante*],
        [
          #config.information.industry_contact.name \
          #config.information.industry_contact.industry_name \
          #config.information.industry_contact.address
        ],

        [], [],
        [*Année académique*], [#config.information.academic_years],
      )
    ],
  )
])
#place(bottom + right, [
  Yverdon-les-Bains, le #datetime.today().display("[day].[month].[year]")
])
#pagebreak(weak: true)

// Page blanche
#page(header: none, footer: none)[]

#outline(title: "Table des matières", depth: 2, indent: 15pt)
#pagebreak(weak: true)

/*
                  ▄▄                           ▄▄
             ██   ██                 ██   ▀▀  ██  ▀▀               ██   ▀▀
 ▀▀█▄ ██ ██ ▀██▀▀ ████▄ ▄█▀█▄ ████▄ ▀██▀▀ ██ ▀██▀ ██  ▄████  ▀▀█▄ ▀██▀▀ ██  ▄███▄ ████▄
▄█▀██ ██ ██  ██   ██ ██ ██▄█▀ ██ ██  ██   ██  ██  ██  ██    ▄█▀██  ██   ██  ██ ██ ██ ██
▀█▄██ ▀██▀█  ██   ██ ██ ▀█▄▄▄ ██ ██  ██   ██▄ ██  ██▄ ▀████ ▀█▄██  ██   ██▄ ▀███▀ ██ ██
*/

= Authentification

Par la présente, j’atteste avoir réalisé ce travail et n’avoir utilisé aucune autre source que celles expressément mentionnées.
#v(20%)

#table(
  stroke: none,
  columns: (60%, 40%),
  [], [#config.information.author.name],
)

#align(left + bottom, [
  Yverdon-les-Bains, le #datetime.today().display("[day].[month].[year]")
])
#pagebreak(weak: true)

/*
               ▄                 ▄▄          ▄▄
              ▀                  ██          ██
████▄ ████▄ ▄█▀█▄ ███▄███▄  ▀▀█▄ ████▄ ██ ██ ██ ▄█▀█▄
██ ██ ██ ▀▀ ██▄█▀ ██ ██ ██ ▄█▀██ ██ ██ ██ ██ ██ ██▄█▀
████▀ ██    ▀█▄▄▄ ██ ██ ██ ▀█▄██ ████▀ ▀██▀█ ██ ▀█▄▄▄
██
▀▀
*/

= Préambule

Ce travail de Bachelor (ci-après TB) est réalisé en fin de cursus d'études, en vue de l'obtention du titre de Bachelor of Science HES-SO en Ingénierie.

#v(4%)

En tant que travail académique, son contenu, sans préjuger de sa valeur, n'engage ni la responsabilité de l'auteur, ni celles du jury du travail de Bachelor et de l'Ecole.

#v(4%)

Toute utilisation, même partielle, de ce TB doit être faite dans le respect du droit d'auteur.

#v(10%)

#table(
  stroke: none,
  columns: (60%, 40%),
  [], [HEIG-VD],
  [], [Le Chef de département #config.information.departement.court],
)

#align(bottom + left, [
  Yverdon-les-Bains, le #datetime.today().display("[day].[month].[year]")
])
#pagebreak(weak: true)

#include "chapitres/cahier-des-charges.typ"
#pagebreak(weak: true)

/*
         ▄                          ▄
        ▀                          ▀
████▄ ▄█▀█▄ ▄█▀▀▀ ██ ██ ███▄███▄ ▄█▀█▄
██ ▀▀ ██▄█▀ ▀███▄ ██ ██ ██ ██ ██ ██▄█▀
██    ▀█▄▄▄ ▄▄▄█▀ ▀██▀█ ██ ██ ██ ▀█▄▄▄
*/

= Résumé

#align(left)[*Travail de Bachelor #config.information.academic_years*]
#align(left)[*Titre:*  #config.information.title]
#align(left)[*Sous-titre:*  #config.information.subtitle]

#v(5%)

#config.information.resume_publiable

#v(5%)

#align(bottom + left, [
  #block(
    width: 100%,
    [
      #table(
        stroke: none,
        columns: (35%, 65%),
        [*#if config.information.author.feminine_form { "Étudiante" } else { "Étudiant" }*],
        [*#config.information.author.name*],

        [], [],
        [*#if config.information.supervisor.feminine_form { "Superviseure" } else { "Superviseur" }*],
        [#config.information.supervisor.name],

        [], [],
        [*Entreprise mandante*], [#config.information.industry_contact.industry_name],
      )
    ],
  )
])
#pagebreak(weak: true)

/*
            ▄▄                         ▄▄                     ▄▄
            ██    ▀▀                   ██                     ██
▄████  ▀▀█▄ ████▄ ██  ▄█▀█▄ ████▄   ▄████ ▄█▀█▄ ▄█▀▀▀   ▄████ ████▄  ▀▀█▄ ████▄ ▄████ ▄█▀█▄ ▄█▀▀▀
██    ▄█▀██ ██ ██ ██  ██▄█▀ ██ ▀▀   ██ ██ ██▄█▀ ▀███▄   ██    ██ ██ ▄█▀██ ██ ▀▀ ██ ██ ██▄█▀ ▀███▄
▀████ ▀█▄██ ██ ██ ██▄ ▀█▄▄▄ ██      ▀████ ▀█▄▄▄ ▄▄▄█▀   ▀████ ██ ██ ▀█▄██ ██    ▀████ ▀█▄▄▄ ▄▄▄█▀
                                                                                   ██
                                                                                 ▀▀▀
*/

= Remerciements

Je remercie le Prof. Bertil Chapuis, mon superviseur et répondant industriel, ainsi que Rémy Marquis, pour leur suivi tout au long du semestre, leurs retours techniques précis et leur disponibilité à chaque fois que le projet a exigé une décision d'architecture.

Je remercie également Valentin Ricard, avec qui j'ai partagé le projet NearAI le temps de ce travail de Bachelor. Nos échanges réguliers, sur l'intégration entre nos deux applications comme sur des problèmes de détection plus ponctuels, ont amélioré la qualité du résultat final.

Une mention spéciale à Monsieur Jean-Claude Dispaux et à sa femme Nicole, pour tout le temps qu'ils m'ont consacré durant ma formation professionnelle, ainsi que pour leur investissement personnel.

Enfin, un grand remerciement à ma mère pour m'avoir soutenu durant toutes mes études et m'avoir motivé à les poursuivre.


#v(2%)


#pagebreak(weak: true)

/*
                                   ▄▄
                                   ██                                              ██
▄████ ▄███▄ ████▄ ████▄ ▄█▀▀▀   ▄████ ██ ██   ████▄  ▀▀█▄ ████▄ ████▄ ▄███▄ ████▄ ▀██▀▀
██    ██ ██ ██ ▀▀ ██ ██ ▀███▄   ██ ██ ██ ██   ██ ▀▀ ▄█▀██ ██ ██ ██ ██ ██ ██ ██ ▀▀  ██
▀████ ▀███▀ ██    ████▀ ▄▄▄█▀   ▀████ ▀██▀█   ██    ▀█▄██ ████▀ ████▀ ▀███▀ ██     ██
                  ██                                      ██    ██
                  ▀▀                                      ▀▀    ▀▀
*/


// Set numbering for content
#set heading(numbering: "1.1")

// Paragraph spacing for content chapters
#set par(leading: 0.65em, spacing: 1.2em, justify: true)

/*
| ------------------------------------
| INSEREZ VOS CHAPITRES CI-DESSOUS
| ------------------------------------
*/

#include "chapitres/introduction.typ"
#include "chapitres/planification.typ"
#include "chapitres/etat-de-lart.typ"
#include "chapitres/architecture.typ"
#include "chapitres/implementation.typ"
#include "chapitres/resultats.typ"
#include "chapitres/conclusion.typ"

// ------------------------------------

// Remove numbering after content
#set heading(numbering: none)

/*
▄▄        ▄▄    ▄▄                                   ▄▄
██    ▀▀  ██    ██ ▀▀                                ██    ▀▀
████▄ ██  ████▄ ██ ██  ▄███▄ ▄████ ████▄  ▀▀█▄ ████▄ ████▄ ██  ▄█▀█▄
██ ██ ██  ██ ██ ██ ██  ██ ██ ██ ██ ██ ▀▀ ▄█▀██ ██ ██ ██ ██ ██  ██▄█▀
████▀ ██▄ ████▀ ██ ██▄ ▀███▀ ▀████ ██    ▀█▄██ ████▀ ██ ██ ██▄ ▀█▄▄▄
                                ██             ██
                              ▀▀▀              ▀▀
*/

#if config.bibliography.content != none {
  bibliography(config.bibliography.content, style: config.bibliography.style, full: true)
}

/*
           ▄▄    ▄▄            ▄▄                 ▄▄
 ██        ██    ██            ██                ██  ▀▀
▀██▀▀ ▀▀█▄ ████▄ ██ ▄█▀█▄   ▄████ ▄█▀█▄ ▄█▀▀▀   ▀██▀ ██  ▄████ ██ ██ ████▄ ▄█▀█▄ ▄█▀▀▀
 ██  ▄█▀██ ██ ██ ██ ██▄█▀   ██ ██ ██▄█▀ ▀███▄    ██  ██  ██ ██ ██ ██ ██ ▀▀ ██▄█▀ ▀███▄
 ██  ▀█▄██ ████▀ ██ ▀█▄▄▄   ▀████ ▀█▄▄▄ ▄▄▄█▀    ██  ██▄ ▀████ ▀██▀█ ██    ▀█▄▄▄ ▄▄▄█▀
                                                            ██
                                                          ▀▀▀
*/

#context {
  let figures = query(figure.where(kind: image))
  if figures.len() != 0 {
    outline(title: "Table des figures", target: figure.where(kind: image))
  }
}

/*
▄▄                            ▄▄                          ▄▄    ▄▄
██ ▀▀         ██              ██                ██        ██    ██
██ ██  ▄█▀▀▀ ▀██▀▀ ▄█▀█▄   ▄████ ▄█▀█▄ ▄█▀▀▀   ▀██▀▀ ▀▀█▄ ████▄ ██ ▄█▀█▄  ▀▀█▄ ██ ██ ██ ██
██ ██  ▀███▄  ██   ██▄█▀   ██ ██ ██▄█▀ ▀███▄    ██  ▄█▀██ ██ ██ ██ ██▄█▀ ▄█▀██ ██ ██  ███
██ ██▄ ▄▄▄█▀  ██   ▀█▄▄▄   ▀████ ▀█▄▄▄ ▄▄▄█▀    ██  ▀█▄██ ████▀ ██ ▀█▄▄▄ ▀█▄██ ▀██▀█ ██ ██
*/

#context {
  let tables = query(figure.where(kind: table))
  if tables.len() != 0 {
    outline(title: "Liste des tableaux", target: figure.where(kind: table))
  }
}

/*
 ▀▀█▄ ████▄ ████▄ ▄█▀█▄ ██ ██ ▄█▀█▄ ▄█▀▀▀
▄█▀██ ██ ██ ██ ██ ██▄█▀  ███  ██▄█▀ ▀███▄
▀█▄██ ██ ██ ██ ██ ▀█▄▄▄ ██ ██ ▀█▄▄▄ ▄▄▄█▀
*/

#fullpage([= Annexes])
#counter(heading).update(0)
#set heading(numbering: "I.i")

/*
| ------------------------------------
| INSEREZ VOS ANNEXES CI-DESSOUS
| ------------------------------------
*/

= Glossaire

#figure(
  table(
    columns: (auto, 1fr),
    align: (left, left),
    table.header([*Terme*], [*Définition*]),
    [*Kubernetes*], [Système d'orchestration de conteneurs open-source],
    [*KubeRay*], [Opérateur Kubernetes pour déployer des clusters Ray],
    [*KEDA*],
    [Kubernetes Event-Driven Autoscaling : autoscaler qui ajuste le nombre de réplicas en fonction d'événements externes, et sait descendre jusqu'à zéro],

    [*Ray*], [Framework Python de calcul distribué, optimisé pour les workloads GPU],
    [*SAM3*], [Segment Anything Model v3 : modèle de segmentation d'images de Meta AI],
    [*ZARR*], [Format N-dimensionnel orienté chunking, évalué comme optimisation optionnelle],
    [*EXIF*], [Métadonnées embarquées dans les fichiers image, contenant notamment les coordonnées GPS],
    [*MinIO*], [Serveur de stockage objet compatible S3],
    [*Parquet*], [Format de stockage colonnaire optimisé pour les requêtes analytiques],
    [*Label Studio*], [Plateforme open-source d'annotation de données pour le machine learning],
    [*Pod*], [Unité de déploiement atomique dans Kubernetes],
    [*S3*], [Protocole de stockage objet défini par Amazon Web Services],
    [*GPU*], [Graphics Processing Unit],
    [*Actor*], [Abstraction Ray permettant de charger un modèle une fois et de le réutiliser sur plusieurs tâches],
    [*Prometheus*], [Système de collecte de métriques par scraping, modèle pull],
    [*DCGM Exporter*], [Exporteur NVIDIA exposant les métriques GPU vers Prometheus],
    [*Promtail*], [Agent de collecte de logs, tourne sur chaque node K8s],
    [*Loki*], [Agrégateur de logs compatible S3, intégré à Grafana],
    [*Grafana*], [Interface de visualisation des métriques et des logs],
    [*EOL*], [End of life, mise en terminaison d'un produit ou d'une solution],
    [*GCS*], [Global Control Service, Control Plane de Ray],
    [*Control Plane*],
    [Cerveau d'un système réseau ou distribué. Décide et contrôle la façon dont les données sont traitées par le data plane],

    [*Data Plane*], [Partie de l'infrastructure responsable de la transmission des données/paquets],
    [*DAG*],
    [Directed Acyclic Graph, définit un pipeline d'exécution où chaque étape dépend strictement de la réussite des précédentes. En éliminant les cycles, ce modèle permet d'identifier les tâches exécutables simultanément (parallélisation) et de reprendre le traitement à partir des points de défaillance.],

    [*PIL*],
    [Python Imaging Library, bibliothèque historique de traitement d'images permettant l'ouverture, la manipulation et la sauvegarde de nombreux formats graphiques],

    [*BLOB*],
    [Binary Large Object, fichier binaire non structuré (image JPEG, poids de modèle). Stocké dans un système de stockage objet (S3/MinIO) plutôt qu'en base de données],

    [*Alloy*],
    [Successeur de Promtail (Grafana Labs). Agent de collecte unifié pour logs, métriques et traces. Configuré via le langage River. Remplace le DaemonSet par un Deployment unique],

    [*River*],
    [Langage déclaratif de configuration d'Alloy, inspiré de HCL. Les composants sont connectés explicitement : la sortie d'un bloc devient l'entrée du suivant],

    [*ViT*],
    [Vision Transformer, architecture d'encodeur d'image basée sur l'attention, utilisée par SAM3 pour encoder les images en représentations latentes],

    [*SA-1B*],
    [Dataset d'entraînement de SAM, 1,1 milliard de masques sur 11 millions d'images. Confère à SAM3 une généralisation forte sur des domaines non vus],

    [*VRAM*], [Video RAM, mémoire dédiée d'un GPU. SAM3 ViT-H occupe ~3,8 Go de VRAM une fois chargé],
    [*OOM*],
    [Out of Memory, erreur de dépassement de mémoire. Survient si un modèle est rechargé à chaque tâche au lieu d'être maintenu dans un Actor],

    [*Data parallelism*],
    [Stratégie de parallélisation GPU où chaque GPU héberge une copie complète du modèle et traite une image indépendante. Le throughput scale linéairement avec le nombre de GPU],

    [*Model parallelism*],
    [Stratégie de parallélisation GPU où le modèle est fragmenté sur plusieurs GPU pour réduire la latence d'une seule inférence. Justifié uniquement quand le modèle ne tient pas sur un seul GPU],

    [*Tuile*],
    [Découpage d'une image panoramique en sous-images 504×504 px pour l'inférence SAM3, qui est limité à 1008x1008 px en entrée],

    [*Équirectangulaire*],
    [Projection cartographique des images panoramiques 360°. Produit une distorsion géométrique croissante vers le zénith et le nadir],

    [*RayCluster*],
    [CRD Kubernetes introduit par KubeRay (`ray.io/v1`). Déclare un nœud head et des groupes de workers. L'opérateur gère les pods correspondants],

    [*Head Node*],
    [Nœud Ray unique hébergeant le GCS, le scheduler et le dashboard. Point d'entrée du cluster via `ray.init()`],

    [*Task (Ray)*],
    [Unité de calcul sans état dans Ray (`@ray.remote` sur une fonction). Exécutée de façon asynchrone sur un worker disponible],

    [*DaemonSet*],
    [Ressource Kubernetes qui déploie exactement un pod par nœud du cluster. Utilisé par Promtail pour collecter les logs sur chaque machine],

    [*Deployment*],
    [Ressource Kubernetes gérant des pods réplicables avec rolling updates et rollback. Utilisé par Alloy en remplacement du DaemonSet],

    [*Headless Service*],
    [Service Kubernetes sans ClusterIP. La résolution DNS retourne les IPs de tous les pods ciblés, permettant à Prometheus de scraper chaque instance individuellement],

    [*NodeAffinity*],
    [Règle de scheduling Kubernetes contraignant ou préférant certains nœuds pour un pod, basée sur les labels des nœuds (ex. type de GPU)],

    [*TSDB*], [Time Series DataBase, format de stockage de Prometheus optimisé pour les métriques horodatées],
    [*PromQL*],
    [Langage de requête de Prometheus. Opère sur des vecteurs instantanés, de portée et scalaires pour agréger les métriques],

    [*LogQL*],
    [Langage de requête de Loki, fortement inspiré de PromQL. Filtre les logs par labels puis les transforme en métriques],

    [*Polling*],
    [Technique d'interrogation périodique d'un état externe jusqu'à ce qu'il change. Le client envoie des requêtes à intervalle fixe plutôt que d'attendre une notification push],

    [*Snappy*],
    [Algorithme de compression rapide utilisé par Parquet. Prioritise la vitesse de décompression sur le taux de compression],

    [*inotify*],
    [Mécanisme Linux de surveillance des modifications de fichiers. Consommé massivement par Promtail qui ouvre un watcher par fichier de log],

    [*Spark*],
    [Apache Spark, framework de calcul distribué dominant pour les workloads ETL sur données structurées. Conçu pour clusters homogènes CPU],

    [*RAPIDS*],
    [Bibliothèque NVIDIA ajoutant le support GPU à Spark. Non natif : ne gère pas le scheduling dynamique de tâches GPU hétérogènes],

    [*RDD*],
    [Resilient Distributed Dataset, API historique de Apache Spark. Collection immuable d'objets bruts distribués sur un cluster.],

    [*DataFrames*],
    [API moderne de Spark optimisée automatiquement par le moteur Catalyst. Abstraction de haut niveau organisant les données en tables avec des colonnes nommées et un schéma.],

    [*ETL*],
    [Extract Transform Load, pipeline d'extraction, transformation et chargement de données. Cas d'usage principal d'Apache Spark],

    [*SQL*],
    [Structured Language Query, langage standardisé utilisé pour communiquer avec les bases de données relationnelles],

    [*PVC*],
    [Persistant Volume Claim, contrat de location entre un pod et un noeud avec une capacité et des droits spécifiques],

    [*NFS*], [Network File System, protocole pour partage de système de fichier sur un réseau.],
    [*OpenCV*],
    [Bibliothèque open-source de vision par ordinateur. Utilisée ici pour vectoriser les masques en contours polygonaux (`findContours`)],

    [*Masque de segmentation*],
    [Image en noir et blanc de la taille de l'image analysée, où chaque pixel indique s'il appartient à l'objet détecté ou au fond],

    [*boto3*],
    [SDK Python officiel d'AWS, utilisé pour toutes les opérations S3 vers MinIO],

    [*FastAPI*],
    [Framework web Python. Sert l'API REST de la pipeline et génère automatiquement sa documentation OpenAPI],

    [*OpenAPI*],
    [Spécification standard décrivant une API REST (routes, paramètres, réponses). Générée par FastAPI par introspection du code],

    [*Swagger UI*],
    [Interface web interactive affichant la documentation OpenAPI (`/docs`), qui permet d'exécuter des requêtes depuis le navigateur],

    [*Ultralytics*],
    [Librairie Python unifiant l'usage de modèles de vision (YOLO, SAM). Utilisée par le service de segmentation interactive],

    [*SOPS*],
    [Outil de chiffrement de fichiers de configuration. Chiffre les valeurs d'un manifeste YAML en laissant sa structure lisible pour Git],

    [*age*],
    [Outil de chiffrement moderne à paire de clés unique, utilisé par SOPS pour chiffrer les Secrets versionnés],

    [*Kustomize*],
    [Outil de composition de manifestes Kubernetes intégré à `kubectl` (drapeau `-k`). Agrège les ressources et centralise le namespace et les tags d'images],

    [*Ingress*],
    [Ressource Kubernetes exposant un Service HTTP à l'extérieur du cluster via un nom de domaine],

    [*ServiceAccount*],
    [Identité Kubernetes attribuée à un pod pour appeler l'API du cluster avec des droits contrôlés],

    [*RBAC*],
    [Role-Based Access Control, modèle de permissions de Kubernetes. Un Role accorde des verbes précis sur des ressources, un RoleBinding le lie à un ServiceAccount],
  ),
  caption: [Glossaire],
)

#include "chapitres/outils-utilises.typ"

#set page(flipped: true)
#include "chapitres/journal-de-travail.typ"

// ------------------------------------
