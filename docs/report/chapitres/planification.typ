#import "@preview/gantty:0.5.1": gantt

= Planification <planification>

== Planification initiale <planification-initiale>

Le travail est budgété à *450 heures* réparties sur *22 semaines*, du 16 février au 23 juillet 2026. La charge suit deux régimes : environ *8 heures par semaine* pendant le semestre (semaines 1 à 17, TB mené en parallèle des cours), puis un régime *plein temps* (`~`63 heures par semaine) dès la semaine 18, à partir du 15 juin.

Dates clés administratives :

- 16.02.2026 : Démarrage du travail
- 20.02.2026 : Kick-off
- 16.03.2026 : Documents de confidentialité
- 09.04.2026 : Cahier des charges final
- 20.05.2026 : Rendu intermédiaire
- 15.06.2026 : Passage en plein temps
- 24.07.2026 : Rendu final du travail
- août-septembre : Défense du travail de Bachelor

=== Découpage prévisionnel

Le découpage prévisionnel par semaine, tel qu'établi en début de projet, est le suivant.

#figure(
  table(
    columns: (auto, auto, 1fr),
    align: (center, center, left),
    table.header([*Sem.*], [*Heures*], [*Objectifs prévus*]),
    [1],
    [8h],
    [Mise en place du poste (Git, Docker), rencontres superviseurs, analyse de l'infrastructure existante, document de compréhension du sujet, bibliographie initiale, brouillon du cahier des charges, planification 450h],

    [2], [8h], [Environnement de développement, étude de Ray et SAM3, premiers tests Ray en local],
    [3], [8h], [Installation de SAM3, premiers tests d'inférence sur CPU, préparation d'un jeu d'images de test],
    [4],
    [8h],
    [Dockerfile SAM3 et build de l'image, push sur le registry, pod K8s avec GPU, premiers tests d'inférence sur le cluster],

    [5], [8h], [Prototype Ray distribué (head et workers), parallélisation des tâches, intégration Ray + SAM3],
    [6], [8h], [Client S3 boto3, connexion à MinIO, pipeline S3 → Ray → SAM3, tests upload/download],
    [7], [8h], [Scénario batch sur un lot d'images, stockage des résultats en Parquet sur S3, validation du format],
    [8], [8h], [Scénario d'inférence à la demande, dockerisation complète, finalisation du cahier des charges],
    [9], [8h], [Observabilité : Prometheus et Grafana sur K8s, métriques GPU/mémoire/latence, dashboards],
    [10], [8h], [Configuration du cluster via Rancher, gestion des namespaces, monitoring],
    [11], [8h], [Label Studio : intégration de l'API, export des annotations, tests de validation humaine],
    [12], [8h], [Manifestes K8s complets (Jobs Ray, Deployments, PVC), tests d'intégration de bout en bout],
    [13],
    [8h],
    [Tests de la pipeline complète (deux scénarios), corrections de bugs, préparation du rapport intermédiaire],

    [*14*], [*8h*], [Remise du rapport intermédiaire, feedback des superviseurs],
    [15], [8h], [Intégration Label Studio, export des annotations, ajustements post-feedback],
    [16], [8h], [Optimisations de performance (taille de batch, parallélisme), benchmarks de downsampling],
    [17],
    [8h],
    [Documentation du déploiement, validation de la pipeline sur le cluster HEIG, préparation du sprint final],

    [*18*], [*63h*], [Déploiement en production sur le cluster HEIG, configuration GPU, premiers runs à grande échelle],
    [19], [63h], [Tests sur GPU du cluster, benchmarks de bout en bout (scalabilité, précision, ressources), tuning],
    [20], [63h], [Rédaction du rapport : introduction, contexte, architecture, choix techniques],
    [21], [63h], [Rédaction du rapport : implémentation, résultats, benchmarks, conclusions],
    [*22*], [*62h*], [Finalisation du rapport, résumé publiable, relecture, soumission GAPS],
    [], [*450h*], [],
  ),
  caption: [Découpage prévisionnel des 450 heures],
)

=== Jalons principaux

#figure(
  table(
    columns: (auto, 1fr, 1fr),
    align: (left, left, left),
    table.header([*Date*], [*Jalon*], [*État attendu de la pipeline*]),
    [09 avril 2026],
    [Remise du cahier des charges],
    [SAM3 sur cluster GPU, Ray + S3 fonctionnels, scénarios batch et on-demand prototypés],

    [20 mai 2026],
    [Remise du rapport intermédiaire],
    [Pipeline de bout en bout complète (MinIO + Ray + SAM3 + Parquet S3 + observabilité + Docker + K8s)],

    [15 juin 2026], [Passage en plein temps], [Déploiement en production sur le cluster HEIG],
    [23 juillet 2026], [Remise du rapport final], [Pipeline déployée sur le cluster HEIG avec GPU],
    [Août–Sept. 2026], [Soutenance], [Démonstration live de la pipeline],
  ),
  caption: [Jalons principaux du projet],
)

#v(5%)
#figure(
  gantt(yaml("planification-gantt.yaml")),
  caption: [
    Planification initiale du projet
  ],
)<gantt>
