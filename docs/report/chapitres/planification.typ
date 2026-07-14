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

// ---- Diagramme de Gantt (Typst natif) : données ----
#let gd(m, day) = datetime(year: 2026, month: m, day: day)
#let g-start = gd(2, 1)
#let g-end = gd(8, 1)
#let g-days = (g-end - g-start).days()
#let gx(dt) = (dt - g-start).days() / g-days * 100%

#let g-phases = (
  (name: "Démarrage", color: rgb("#2563EB"), tasks: (
    ("Documents administratifs", gd(2, 16), gd(2, 27)),
    ("Analyse des besoins", gd(2, 23), gd(3, 13)),
    ("Rédaction du cahier des charges", gd(2, 23), gd(4, 9)),
  )),
  (name: "Prototypage", color: rgb("#7C3AED"), tasks: (
    ("Étude de Ray et SAM3", gd(2, 23), gd(3, 15)),
    ("SAM3 sur cluster GPU", gd(3, 9), gd(3, 29)),
    ("Prototype Ray distribué", gd(3, 16), gd(3, 29)),
    ("Pipeline MinIO + Ray + SAM3", gd(3, 30), gd(4, 12)),
    ("Scénarios batch et on-demand", gd(4, 6), gd(4, 12)),
  )),
  (name: "Intégration", color: rgb("#0891B2"), tasks: (
    ("Observabilité (Prometheus, Grafana, Loki)", gd(4, 20), gd(5, 3)),
    ("Label Studio", gd(5, 4), gd(5, 24)),
    ("Manifestes K8s et tests E2E", gd(5, 11), gd(5, 19)),
  )),
  (name: "Consolidation", color: rgb("#EA580C"), tasks: (
    ("Optimisations et benchmarks", gd(5, 25), gd(6, 7)),
  )),
  (name: "Plein temps", color: rgb("#059669"), tasks: (
    ("Déploiement production HEIG", gd(6, 15), gd(6, 21)),
    ("Benchmarks E2E et tuning", gd(6, 22), gd(6, 28)),
    ("Rédaction du rapport", gd(6, 29), gd(7, 19)),
    ("Finalisation et rendu", gd(7, 20), gd(7, 24)),
  )),
)

// (nom, date, ancre, niveau d'étiquette)
#let g-milestones = (
  ("Kick-off", gd(2, 16), "left", 0),
  ("CdC final", gd(4, 9), "left", 1),
  ("Rapport intermédiaire", gd(5, 20), "left", 2),
  ("Plein temps", gd(6, 15), "left", 0),
  ("Rendu final", gd(7, 24), "right", 1),
)

// ---- Diagramme de Gantt : rendu ----
#let gantt-chart() = {
  let row-h = 15pt
  let head-h = 15pt
  let label-size = 8.5pt
  let grid-stroke = 0.5pt + rgb("#E2E8F0")
  let months = ("Février", "Mars", "Avril", "Mai", "Juin", "Juillet")
  let month-starts = range(2, 9).map(m => gd(m, 1))

  // une ligne par phase (barre pleine) puis par tâche (barre claire)
  let rows = ()
  for p in g-phases {
    let s = p.tasks.fold(p.tasks.first().at(1), (acc, t) => if t.at(1) < acc { t.at(1) } else { acc })
    let e = p.tasks.fold(p.tasks.first().at(2), (acc, t) => if t.at(2) > acc { t.at(2) } else { acc })
    rows.push((label: p.name, start: s, end: e, phase: true, color: p.color))
    for t in p.tasks {
      rows.push((label: t.at(0), start: t.at(1), end: t.at(2), phase: false, color: p.color))
    }
  }
  let chart-h = rows.len() * row-h

  grid(
    columns: (auto, 1fr),
    column-gutter: 10pt,
    row-gutter: 0pt,

    // coin vide au-dessus des libellés
    box(height: head-h),

    // bandeau des mois
    box(width: 100%, height: head-h, {
      for (i, m) in months.enumerate() {
        let x0 = gx(month-starts.at(i))
        let x1 = gx(month-starts.at(i + 1))
        place(dx: x0, box(
          width: x1 - x0, height: head-h,
          align(center + horizon, text(size: 8pt, weight: "bold", fill: rgb("#64748B"), m)),
        ))
      }
    }),

    // colonne des libellés
    stack(dir: ttb, ..rows.map(r => box(
      height: row-h,
      align(horizon, pad(
        left: if r.phase { 0pt } else { 10pt },
        text(size: label-size, weight: if r.phase { "bold" } else { "regular" }, r.label),
      )),
    ))),

    // zone du diagramme
    box(width: 100%, height: chart-h, {
      // bandes de fond derrière les lignes de phase
      for (i, r) in rows.enumerate() {
        if r.phase {
          place(dy: i * row-h, box(width: 100%, height: row-h, fill: rgb("#F1F5F9")))
        }
      }
      // grille mensuelle
      for m in (month-starts + (g-end,)) {
        place(dx: gx(m), line(angle: 90deg, length: chart-h, stroke: grid-stroke))
      }
      // règles horizontales haut et bas
      place(line(length: 100%, stroke: 0.6pt + rgb("#CBD5E1")))
      place(dy: chart-h, line(length: 100%, stroke: 0.6pt + rgb("#CBD5E1")))
      // jalons : ligne pointillée + losange sur l'axe du bas
      for (name, date, anchor, level) in g-milestones {
        place(dx: gx(date), line(
          angle: 90deg, length: chart-h,
          stroke: (paint: rgb("#94A3B8"), thickness: 0.6pt, dash: "densely-dashed"),
        ))
        place(dx: gx(date) - 2.6pt, dy: chart-h - 3.2pt, text(size: 6.5pt, fill: rgb("#334155"), sym.diamond.filled))
      }
      // barres
      for (i, r) in rows.enumerate() {
        let bar-h = if r.phase { 8pt } else { 6pt }
        place(
          dx: gx(r.start),
          dy: i * row-h + (row-h - bar-h) / 2,
          box(
            width: gx(r.end) - gx(r.start), height: bar-h, radius: 3pt,
            fill: if r.phase { r.color } else { r.color.lighten(55%) },
          ),
        )
      }
    }),

    // étiquettes des jalons, sous le diagramme
    box(height: 34pt),
    box(width: 100%, height: 34pt, {
      for (name, date, anchor, level) in g-milestones {
        let lbl = text(size: 7.5pt)[*#name* #text(fill: rgb("#64748B"))[· #date.display("[day].[month]")]]
        if anchor == "right" {
          place(dy: 4pt + level * 10pt, box(width: gx(date) - 3pt, align(right, lbl)))
        } else {
          place(dx: gx(date) + 3pt, dy: 4pt + level * 10pt, lbl)
        }
      }
    }),
  )
}

#v(5%)
#figure(
  block(breakable: false, gantt-chart()),
  caption: [
    Planification initiale du projet
  ],
)<gantt>
