#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#show: codly-init.with()

#let col-blue = rgb("#2563EB")

= Résultats <resultats>

Pour les tests, étant donné que l'institut utilise les GPUs nous n'avons pas forcément à chaque fois ceux que nous volons pour faire les tests. Le meilleurs des cas serait d'avoir constament le 3 L40s pour avoir les meilleurs résultats et les plus constants.

== Benchmark de tuilage
Le protocole de benchmark fixe tous les paramètres sauf la taille de tuile, la taille de l'image fournie et trois workers Ray (2× L40S sur `iict-suchet`, 1× A40 sur `iict-k8s-node4-rad`). Deux tailles de tuile sont comparées, 512×512 et 1024×1024, à résolution pleine.

Pour le cas du 512x512 :

#figure(
  table(
    columns: (auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(text(fill: white)[*Métrique*], text(fill: white)[*Valeur*]),
    [Tuiles], [128],
    [Init worker (à froid)], [≈ 71 s],
    [Init worker (cache chaud)], [≈ 19 s],
    [Inférence/tuile — L40S], [≈ 2,0 s],
    [Inférence/tuile — A40], [≈ 2,5 s],
    [Inférence totale], [111,4 s],
    [Polygones extraits], [146],
    [*Temps total (wall)*], [*≈ 1 min 50 s*],
  ),
  caption: [Run A — tuiles 512×512, image 4096×8192, 3 workers],
) <tab-run-512>

Pour le cas du 1024x1024 :

#figure(
  table(
    columns: (auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(text(fill: white)[*Métrique*], text(fill: white)[*Valeur*]),
    [Tuiles], [32],
    [Inférence/tuile — L40S], [≈ 6,4 s],
    [Inférence/tuile — A40], [≈ 9,3 s],
    [Inférence totale], [103,3 s],
    [Polygones extraits], [49],
    [*Temps total (wall)*], [*≈ 1 min 43 s*],
  ),
  caption: [Run B — tuiles 1024×1024, image 4096×8192, 3 workers],
) <tab-run-1024>

Passer de 512×512 à 1024×1024 ne gagne que ≈ 8 s sur l'image entière. Le temps est dominé par SAM3 lui-même, pas par le nombre de tuiles : quatre fois moins de tuiles ne divise pas le temps par quatre, car chaque tuile plus grande coûte proportionnellement plus cher à inférer. Le nombre de polygones, en revanche, chute d'un facteur trois (146 → 49). Les tuiles 512×512 sont retenues pour leur meilleure qualité de segmentation.

=== Impact du downsampling

Le downsampling réduit la résolution de l'image avant le tuilage. Un facteur 0,5 divise par deux la largeur et la hauteur, donc par quatre le nombre de tuiles et le temps d'inférence. Le compromis porte sur le détail : SAM3 voit moins d'information de contour par tuile.

#figure(
  table(
    columns: (auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Facteur*], text(fill: white)[*Tuiles (image 4096×8192)*], text(fill: white)[*Temps relatif*]
    ),
    [1,0 (référence)], [128], [1,0×],
    [0,75], [72], [≈ 0,56×],
    [0,5], [32], [≈ 0,25×],
    [0,25], [8], [≈ 0,06×],
  ),
  caption: [Effet du facteur de downsampling sur le coût d'inférence (tuiles 512×512)],
) <tab-downsampling>

Le facteur 0,5 est retenu par défaut : il divise le temps d'inférence par ≈ 4 tout en préservant assez de détail pour la qualité d'annotation visée. Le facteur 0,25 est trop agressif, SAM3 perd les contours fins des objets de moins de ≈ 50 px dans l'image réduite.

== Scalabilité de la pipeline

=== Throughput par nombre de workers

Le cluster expose 9 GPUs (cf. @tab-gpus), mais seuls trois workers ont pu être schedulés simultanément pendant les tests : deux sur `iict-suchet`, un sur `iict-k8s-node4-rad`. Les autres GPUs étaient occupés par d'autres namespaces, le scheduler renvoyant `Insufficient nvidia.com/gpu`. Le nœud `iict-chasseron` est exclu par `nodeAffinity` (L4 moins puissants, taint `disk-pressure`).

Le throughput croît linéairement avec le nombre de workers tant que les tuiles d'une image sont réparties sur des GPUs distincts, l'étape d'inférence est *embarrassingly parallel*, c'est-à-dire que chaque tuile est traité defaçon indépendante indépendante. Le plafond pratique est donc le nombre de GPUs libres au moment du run et non pas l'architecture de la pipeline.

=== Comparaison L40S vs A40

Sur une image de 4000x8000, avec une tuile de 1024×1024 et 2 labels (`road_mark` et `sign`), le L40S traite une tuile en 6,4s contre 9,3s pour l'A40, soit un rapport de x1,45. Cet écart est cohérent avec la différence de performance tensorielle entre les deux GPUs. Le scheduler ne distinguant pas les modèles de GPU (sauf si nous utilison des affinity précises pour 1 seul type de carte), un run mixte est cadencé par les workers les plus lents, un pool homogène de L40S maximiserait donc le throughput.

== Runs sur données réelles

=== Job Solo


=== Segmenatation à la volée

=== Batch Dataset Samples : 40 images

// TODO : remplir avec les chiffres mesurés du run Samples (temps total, polygones, échecs éventuels)

=== Batch Dataset Vevey : ≈ 21 000 images

Le run de production sur le dataset HSN traite l'ensemble des images en un seul batch.

// TODO : chiffres finaux à compléter quand le run se termine (≈ 19.06.2026).
// Observé en cours de run : 11 500 / 21 000 images en 20 h (≈ 575 images/h).
// Config du run à confirmer (workers, taille de tuile, downsampling) pour expliquer
// l'écart avec l'extrapolation single-image (≈ 111 s/image à 3 workers).

== Qualité des annotations

=== Impacts sur les performances

=== Distribution des scores de confiance

// TODO : histogramme des scores SAM3 sur un run réel (depuis les Parquet).

=== Exemples visuels dans Label Studio

#figure(
  image("../images/firstOutputLabelStudio.png", width: 90%),
  caption: [Pré-annotations SAM3 importées dans Label Studio depuis un fichier Parquet converti],
) <fig-labelstudio-output>

== Observabilité en production

=== Métriques GPU (DCGM)

DCGM Exporter, installé par le GPU Operator NVIDIA, expose les métriques GPU (utilisation, mémoire, température, puissance) à Prometheus. Pendant un run, le suivi de l'utilisation et de la VRAM par worker confirme que les GPUs ciblés sont effectivement saturés et qu'aucun n'est sous-employé.

// TODO : capture du panel DCGM pendant un run + commentaire (utilisation %, VRAM).

...

=== Dashboard Grafana

Grafana corrèle sur une même vue les métriques Prometheus (GPU, CPU, mémoire des pods) et les logs Loki. Un pic d'utilisation GPU se relit directement à côté des logs du worker correspondant.

// TODO : capture du dashboard Grafana.
//
//
...

=== Logs Ray dans Grafana

Promtail tourne en DaemonSet et expédie les `stdout`/`stderr` de chaque pod vers Loki, stocké sur MinIO (bucket dédié `nearai-logs`, rétention 30 jours). Les logs des workers Ray se requêtent en LogQL par label.

...
