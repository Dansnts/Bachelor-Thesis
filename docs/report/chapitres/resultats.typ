#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#show: codly-init.with()

#let col-blue = rgb("#2563EB")

= Résultats <resultats>

NB : Pour les tests, étant donné que l'institut utilise les GPUs nous n'avons pas forcément à chaque fois ceux que nous volons pour faire les tests. Le meilleurs des cas serait d'avoir constament les 3 L40s pour avoir les meilleurs résultats et les plus constants.

== Benchmark de tuilage
Le protocole de benchmark fixe tous les paramètres sauf la taille de tuile, la taille de l'image fournie et trois workers Ray (2× L40S sur `iict-suchet`, 1× A40 sur `iict-k8s-node4-rad`). Deux tailles de tuile sont comparées, 512×512 et 1024×1024, à résolution pleine.

Pour le cas du 512x512 :

Run de Juillet ici

Pour le cas du 1024x1024 :

Run de Juillet ici


=== Impact du downsampling

Le downsampling réduit la résolution de l'image avant le tuilage. Un facteur 0,5 divise par deux la largeur et la hauteur, donc par quatre le nombre de tuiles et le temps d'inférence. Le compromis porte sur le détail : SAM3 voit moins d'information de contour par tuile.

==== Facteur 1
Run de Juillet ici

==== Facteur 0,5
Run de Juillet ici


== Scalabilité de la pipeline

=== Throughput par nombre de workers

Le cluster expose 9 GPUs (cf. @tab-gpus), mais seuls trois workers ont pu être schedulés simultanément pendant les tests, deux sur `iict-suchet` et un sur `iict-k8s-node4-rad`. Les autres GPUs étaient occupés par d'autres namespaces, le scheduler renvoyant `Insufficient nvidia.com/gpu`.

Le nœud `iict-chasseron` (4 GPUs) est exclu par `nodeAffinity` (L4 moins puissants, taint `disk-pressure`).

Le throughput croît linéairement avec le nombre de workers tant que les tuiles d'une image sont réparties sur des GPUs distincts, l'étape d'inférence est *embarrassingly parallel*, c'est-à-dire que chaque tuile est traité de façon indépendante. Le plafond pratique est donc le nombre de GPUs libres au moment du run et non pas l'architecture de la pipeline.

=== Comparaison L40S vs A40

Les deux GPUs disponibles pour les workers diffèrent par leur architecture, Ada Lovelace (2023) pour le L40S @l40s-datasheet et Ampere (2022) pour le A40 @a40-datasheet. Tous deux embarquent 48 GB en GDDR6, mais le L40S domine sur la plupart des métriques.

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Spécification*],
      text(fill: white)[*L40S*],
      text(fill: white)[*A40*],
      text(fill: white)[*Ratio L40S/A40*],
    ),
    [Architecture], [Ada Lovelace], [Ampere], [—],
    [CUDA Cores], [18'176], [10'752], [x1,69],
    [Tensor Cores], [568 (4ᵉ gén)], [336 (3ᵉ gén)], [—],
    [BF16 Tensor TFLOPS], [362], [149,7], [*x2,42*],
    [FP32 TFLOPS], [91,6], [37,4], [x2,45],
    [Bande passante mémoire], [864 GB/s], [696 GB/s], [x1,24],
    [Mémoire], [48 GB GDDR6], [48 GB GDDR6], [x1,00],
    [Puissance max], [350 W], [300 W], [x1,17],
  ),
  caption: [Spécifications L40S vs A40 (datasheets NVIDIA @l40s-datasheet @a40-datasheet)],
) <tab-l40s-a40>

SAM3 tourne en `bfloat16` (cf. @architecture), la métrique pertinente est donc le débit BF16 Tensor, le L40S annonce 362 TFLOPS contre 149,7 pour l'A40, un ratio théorique de *2,42×*. Or, sur une image de 4000x8000 avec une tuile de 1024x1024 et 2 labels, le L40S traite une tuile en 6,4 s contre 9,3 s pour l'A40, soit un gain mesuré de seulement *1,45×*.

L'écart entre le ratio théorique (x2,42) et le gain observé (x1,45) montre que l'inférence par tuiles n'est pas purement lié au spécifications de l'hardwar #footnote[Sans compter la silicon lottery, tous les GPUs labelisés avec une certaines performance, avec un score moyen de X un GPU est labelisé L40S mais il peut être dans la fourchette haute (juste trop faible pour être considéré comme un GPU d'une gamme supérieur) ou au contraire à peine assez puissant pour être considéré comme L40S]. Le gain mesuré se situe entre le ratio de bande passante mémoire (x1,24) et le ratio de calcul (x2,42), plus proche du premier.

Le temps par tuile est en partie dicté par les transferts mémoire et les surcoûts (préparation des tenseurs, dispatch Python, accès à la RAM, ...), pas seulement par la puissance tensorielle brute. Le scheduler ne distinguant pas les modèles de GPU (sauf affinity dédiée à un seul type de carte), un run mixte est cadencé par les workers les plus lents, un pool homogène de L40S maximiserait donc le throughput.


== Runs sur données réelles

Le plan d'expériences sépare ce qui est _prévisible_ de ce qui ne l'est pas. Le temps d'inférence suit le modèle :

$ "temps" approx "nombre de tuiles" times "coût par tuile" $

où le nombre de tuiles est proportionnel à $("Longueur" times "Hauteur" times "downsampling"^2) \/ "tile_stride"^2$ et le coût par tuile dépend de la taille de tuile. La vitesse se déduit donc de la formule et ne demande que quelques runs de confirmation. La qualité de segmentation, elle, n'est pas prévisible analytiquement, c'est là que les runs empiriques sont concentrés.

Le dataset Vevey est homogène en résolution : les 21'819 panoramas de l'acquisition font tous 8000x4000 (32 MP). Il n'y a donc qu'une seule taille native à tester. Ce jeu de données est donc parfait pour testers les différetne paramètre au cas apr cas et faire des run conséquants avec énormément d'images à haute résolution afin de valider la solidité de la pipeline.

La réduction de résolution est explorée via le downsampling. La résolution native et downsampling sont le même axe physique#footnote[Downsampler une image 8000×4000 à 0,5 revient à traiter une image 4000×2000]. Le sweep de downsampling couvre ainsi toute la plage de tailles effectives.

La méthode est One-factor-at-a-time (OFAT), on fixe une image de référence et on ne fait varier qu'un seul paramètre par sweep.

Image de référence : `pano_0002_004731.jpg` (8000×4000, 32 MP), tirée du jeu de Vevey.

Deux jeux de labels sont comparés. Le jeu *grossier* (3 labels) regroupe les familles d'objets  le jeu *précis* (6 labels) les sous-divise, selon le mapping suivant :

#figure(
  table(
    columns: (auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(text(fill: white)[*Grossier (3)*], text(fill: white)[*Précis (6)*]),
    [`sign`], [`circular_sign`, `rectangular_sign`],
    [`manhole`], [`circular_manhole_cover`, `rectangular_drain_grate`],
    [`road_mark`], [`road_marking`, `arrow_marking`],
  ),
  caption: [Les deux jeux de labels comparés (grossier vs précis)],
) <tab-labels>

Chaque label est une requête `FindQuery` distincte par tuile, le coût d'inférence croît donc à peu près linéairement avec le nombre de labels. Sauf mention contraire, les sweeps tile_size et downsampling utilisent le jeu grossier (3 labels).

=== Job Solo : sweep sur l'image de référence

==== Effet de la taille de tuile

À downsampling fixé (1,0), comparaison 512×512 vs 1024×1024 :

#figure(
  table(
    columns: (auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Taille de tuile*], text(fill: white)[*Temps total*], text(fill: white)[*Polygones extraits*]
    ),
    [512×512], [≈ ... s], [...],
    [1024×1024], [≈ ... s], [...],
  ),
  caption: [Solo : effet de la taille de tuile (downsample 1,0, image de référence)],
) <tab-solo-tile>

// TODO : commenter le compromis qualité/vitesse observé.
...

==== Effet du downsampling

À taille de tuile fixée (512×512), sweep du facteur de downsampling. Mesure la courbe qualité <--> vitesse.

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Facteur*],
      text(fill: white)[*Tuiles*],
      text(fill: white)[*Temps total*],
      text(fill: white)[*Polygones extraits*],
    ),
    [1,0 (référence)], [...], [≈ ... s], [...],
    [0,75], [...], [≈ ... s], [...],
    [0,5], [...], [≈ ... s], [...],
    [0,25], [...], [≈ ... s], [...],
  ),
  caption: [Solo : effet du downsampling (tuiles 512×512, image de référence)],
) <tab-solo-downsample>

// TODO : ajouter un graph en courbe

// TODO : commenter à partir de quel facteur la qualité décroche (perte des contours fins).
...

==== Effet de la granularité des labels

À tuile et downsampling fixés (512×512, downsample 1,0), comparaison du jeu grossier (3 labels) et du jeu précis (6 labels, cf. @tab-labels). Mesure le surcoût en temps et le gain en finesse de classification.

#figure(
  table(
    columns: (auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Jeu de labels*], text(fill: white)[*Temps total*], text(fill: white)[*Polygones extraits*]
    ),
    [Grossier (3)], [≈ ... s], [...],
    [Précis (6)], [≈ ... s], [...],
  ),
  caption: [Solo : effet de la granularité des labels (512×512, downsample 0,5, image de référence)],
) <tab-solo-labels>

// TODO : confronter au run de production Vevey (6 labels 34 h 17 vs 2 labels ≈ 18 h) pour valider la linéarité à grande échelle.
...

=== Job Batch : scalabilité

Le batch ne refait pas le sweep de paramètres : par image, le coût est identique au solo. Sa valeur propre est le *throughput* et la scalabilité avec le nombre de workers. 40 images issues du même jeu (même appareil, mêmes conditions météo) que le run solo sont traitées en configuration par défaut (1024×1024, downsample 0,5).

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Workers*],
      text(fill: white)[*Temps total*],
      text(fill: white)[*Débit (img/h)*],
      text(fill: white)[*Speed-up*],
    ),
    [1], [≈ ... s], [...], [1,0×],
    [3], [≈ ... s], [...], [...×],
  ),
  caption: [Batch 40 images : scalabilité selon le nombre de workers (1024×1024, downsample 1,0)],
) <tab-batch-scaling>

// TODO : commenter la linéarité du speed-up (étape d'inférence embarrassingly parallel, cf. @resultats).
//
// TODO : Ajouté en graphe avec en axe des coordonnées le temps écoulé et en axe des absicices le % de complétion

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Workers*],
      text(fill: white)[*Temps total*],
      text(fill: white)[*Débit (img/h)*],
      text(fill: white)[*Speed-up*],
    ),
    [1], [≈ ... s], [...], [1,0×],
    [3], [≈ ... s], [...], [...×],
  ),
  caption: [Batch 40 images : scalabilité selon le nombre de workers (512×512, downsample 0,5)],
) <tab-batch-scaling>

// TODO : commenter la linéarité du speed-up (étape d'inférence embarrassingly parallel, cf. @resultats).
//
// TODO : Ajouté en graphe avec en axe des coordonnées le temps écoulé et en axe des absicices le % de complétion
...

=== Segmenatation à la volée

Pour la segmentation à la volée, n'importe quelle image peut être utilisée car ici le job va simplement faire une prédiction selon à un label donnée à une coordonée donnée.

=== Batch Dataset Vevey

Le run de production sur le dataset Vevey traite l'ensemble des 21'819 images en un seul batch. Trois configurations de labels ont été exécutées sur le même jeu, de la plus grossière (2 labels génériques) à la plus fine (6 labels précis) :

- *2 labels* : `sign`, `road_mark`
- *3 labels* : `sign`, `road_mark`, `manhole`
- *6 labels* : `circular_sign`, `rectangular_sign`, `circular_manhole_cover`, `rectangular_drain_grate`, `road_marking`, `arrow_marking`

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Jeu de labels*],
      text(fill: white)[*Temps total*],
      text(fill: white)[*Débit*],
      text(fill: white)[*Temps/image*],
    ),
    [2 (générique)], [18 h 30 min], [≈ 1179 img/h], [≈ 3,1 s],
    [3 (générique)], [22 h 47 min], [≈ 958 img/h], [≈ 3,8 s],
    [6 (précis)], [34 h 17 min], [≈ 637 img/h], [≈ 5,7 s],
  ),
  caption: [Run de production Vevey (21'819 images) : effet du nombre de labels],
) <tab-run-vevey>

Le temps total n'est pas proportionnel au nombre de labels car, comme montré dans le tableau, passer de 2 à 6 labels (×3) n'allonge le run que de 18 h 30 à 34 h 17 (×1,85). Un modèle linéaire $"temps" = "base" + k times "labels"$ ajuste ≈ 10 h de coût fixe (téléchargement, tuilage, I/O, indépendant des labels) et ≈ 3,9 h par label. C'est la partie inférence qui croît linéairement avec le nombre de labels, conformément à la structure une requête `FindQuery` par label et par tuile.

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
