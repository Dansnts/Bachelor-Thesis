#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#import "@preview/lilaq:0.5.0" as lq
#show: codly-init.with()

#let col-blue = rgb("#2563EB")

= Résultats <resultats>

== Environnement

Le cluster expose 9 GPUs (cf. @tab-gpus), pour ces tests, jusqu'à trois workers ont étés schedulés simultanément, tous sur `iict-suchet`.

En effet, comme dit avant, travailler sur chasseron est relativement compliqué car nous avons toujours une erreur de disk-pressure sur nos pods, c'est pour cela que nous l'avons exclu par `nodeAffinity` (L4 moins puissants, taint `disk-pressure`). Utiliser les A40 du`iict-k8s-node4-rad` est aussi envisageable, mais afin d'obtenir les meilleurs résultats possibles, il à été décider d'exploiter exclusivement les L40S du noeud suchet.

Si les GPUs voulu via l'affinité sont occupés le scheduler renvoye `Insufficient nvidia.com/gpu`.

Le throughput#footnote["Taux d'images ou tuiles traitées par secondes"] croît linéairement avec le nombre de workers tant que les tuiles d'une image sont réparties sur des GPUs distincts, l'étape d'inférence est *embarrassingly parallel*, c'est-à-dire que chaque tuile est traité de façon indépendante.

Le plafond pratique est donc le nombre de GPUs libres au moment du run et non pas l'architecture de la pipeline.

#pagebreak()
== Comparaison L40S vs A40

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

SAM3 tourne en `bfloat16` (cf. @architecture), la métrique pertinente est donc le débit BF16 Tensor, le L40S annonce 362 TFLOPS contre 149,7 pour l'A40, un ratio théorique de *2,42×*. Or, sur une image de 4000x8000 avec une tuile de 1024x1024 et 2 labels, le L40S traite une tuile en 6,4 s contre 9,3 s pour l'A40, soit un gain mesuré de seulement *1,45×*. < - - Valeur à re-calculer sur un solo run

L'écart entre le ratio théorique (x2,42) et le gain observé (x1,45) montre que l'inférence par tuiles n'est pas purement lié au spécifications de l'hardwar #footnote[Sans compter la silicon lottery, tous les GPUs labelisés avec une certaines performance, avec un score moyen de X un GPU est labelisé L40S mais il peut être dans la fourchette haute (juste trop faible pour être considéré comme un GPU d'une gamme supérieur) ou au contraire à peine assez puissant pour être considéré comme L40S]. Le gain mesuré se situe entre le ratio de bande passante mémoire (x1,24) et le ratio de calcul (x2,42), plus proche du premier.

Le temps par tuile est en partie dicté par les transferts mémoire et les surcoûts (préparation des tenseurs, dispatch Python, accès à la RAM, etc...) pas seulement par la puissance tensorielle brute. Le scheduler ne distinguant pas les modèles de GPU (sauf affinity dédiée à un seul type de carte), un run mixte est cadencé par les workers les plus lents, un pool homogène de L40S maximise donc le throughput.

Le seul intêret de mélanger les GPUs est simplement d'augmenter le nombre de workers.

#pagebreak()
== Runs sur données réelles

La méthode utilisé pour les runs est One-factor-at-a-time (OFAT), on fixe une image de référence et on ne fait varier qu'un seul paramètre par sweep.

Le plan d'expériences sépare ce qui est _prévisible_ de ce qui ne l'est pas. Le temps d'inférence suit le modèle :

$ "temps" approx "nombre de tuiles" times "coût par tuile" $

où le nombre de tuiles est proportionnel à : $ frac("largeur" times "hauteur" times "downsampling"^2, "stride"^2) $

Des trois paramètres de cette formule, la taille de tuile et le downsampling sont balayés dans les runs qui suivent, le stride, lui, reste fixé à 768px dans le code. Cette valeur mérite d'être justifiée, car le nombre de tuiles varie en $1 slash "stride"^2$ : tout recouvrement supplémentaire renchérit le calcul de façon quadratique.

Par exemple : un stride de 768 sur une tuile de 1008 laisse un recouvrement de $1008 - 768 = 240$ px, soit ~24 % de la tuile. Concrètement ça veux dire que tout objet de moins de 240px de large est capté entier dans au moins une tuile, ce qui couvre les panneaux, plaques et marquages dans une panoramique de 8000 px de large. Le tableau @tab-stride chiffre l'arbitrage sur l'image de référence :

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Stride*],
      text(fill: white)[*Recouvrement*],
      text(fill: white)[*Tuiles*],
      text(fill: white)[*Coût relatif*],
    ),
    [1008], [0 px (0 %)], [32], [×1,0],
    [*768*], [*240 px (24 %)*], [*55*], [*×1,7*],
    [504], [504 px (50 %)], [105], [×3,3],
  ),
  caption: [Coût du recouvrement selon le stride (image 8000×4000, tuile 1008×1008).],
) <tab-stride>

Passer d'un découpage sans recouvrement (stride de 0px) à un stride de 768px ne coûte que +72 % de tuiles tout en supprimant le risque de coupure sur les objets courants. Descendre à 504 (recouvrement de 50 %) triple le nombre de tuiles pour ne rattraper que des objets plus gros, déjà souvent captés par d'autres tuiles adjacentes.

Le stride de 768 est donc un compromis raisonné, non un optimum, sa valeur idéale se calibrerait sur la distribution réelle des tailles d'objets, ce qui reste un axe d'amélioration mais sortirais du scope de ce TB étant donné le nombre de tests supplémentaires.

La vitesse peut se déduire mais la qualité de segmentation, elle, n'est pas prévisible analytiquement, c'est là que les runs empiriques sont concentrés.

Le dataset Vevey est homogène en résolution, toutes les images de l'acquisition font 8000x4000 pixels. Il n'y a donc qu'une seule taille native à tester. Ce jeu de données est donc parfait pour testers les différetne paramètre au cas pas cas et faire des run conséquants avec énormément d'images à haute résolution afin de valider la solidité de la pipeline.

Pour les runs en solo, l'image de référence est la `pano_0002_004731.jpg` (8000×4000, 32 MP), tirée du jeu de Vevey.

La réduction de résolution est explorée via le downsampling. Car downsampler une image 8000×4000 à 0,5 revient à traiter une image 4000×2000 et permet ainsi de couvrir toute la plage de tailles effectives.

Deux jeux de labels sont comparés. Le jeu *grossier* (3 labels) regroupe les familles d'objets  le jeu *précis* (6 labels) les sous-divise, selon le mapping suivant :

#figure(
  table(
    columns: (auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(text(fill: white)[*Grossier *], text(fill: white)[*Précis *]),
    [`sign`], [`circular_sign`, `rectangular_sign`],
    [`manhole`], [`circular_manhole_cover`, `rectangular_drain_grate`],
    [`road_mark`], [`road_marking`, `arrow_marking`],
  ),
  caption: [Les deux jeux de labels comparés (grossier vs précis)],
) <tab-labels>

Chaque label est une requête `FindQuery` distincte par tuile, le coût d'inférence croît donc à peu près linéairement avec le nombre de labels.

== Run Solo

Comme dit dans la section état de l'art (cf @etat-de-lart), SAM3 fige son entrée à 1008×1008, chaque tuile lui est donc redimensionnée avant inférence (cf. @implementation), ce qui rend la taille de tuile libre. Nous croisons la taille native 1008×1008 (sans redimensionnement) et 504×504 (la moitié exacte, agrandie ×2 avant le modèle) avec les quatre facteurs de downsampling. Une tuile plus grande serait simplement réduite à 1008, soit l'équivalent d'un downsampling, sans intérêt ici.

Le temps mesuré couvre le traitement d'une image (tuilage, inférence, polygonisation, écriture du résultat), hors chargement du modèle ($~54s$, amorti sur un batch). Le score est la confiance moyenne de SAM3 (0 à 1) sur les polygones retenus. Tous les runs solo on été tournés sur un L40S (`iict-suchet`).

#figure(
  table(
    columns: (auto, auto, auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Taille de tuile*],
      text(fill: white)[*Downsampling*],
      text(fill: white)[*Tuiles*],
      text(fill: white)[*Temps*],
      text(fill: white)[*Polygones*],
      text(fill: white)[*Score moyen*],
    ),
    [1008×1008], [1,0], [55], [≈ 11,1 s], [29], [0,69],
    [1008×1008], [0,75], [32], [≈ 7,8 s], [29], [0,69],
    [1008×1008], [0,5], [15], [≈ 5,1 s], [27], [0,66],
    [1008×1008], [0,25], [3], [≈ 3,2 s], [15], [0,72],
    [504×504], [1,0], [231], [≈ 32,7 s], [36], [0,72],
    [504×504], [0,75], [128], [≈ 18,1 s], [32], [0,71],
    [504×504], [0,5], [55], [≈ 9,0 s], [23], [0,71],
    [504×504], [0,25], [15], [≈ 4,3 s], [15], [0,70],
  ),
  caption: [Résultat sur la même image de référence (8000x4000), avec 2 tailles de tuillage combinées à 4 downsamplings.],
) <tab-solo-tile>

À pleine résolution, le tuilage 504 détecte en moyenne 1.3x plus d'objets de plus que celui à 1008 avec un score de confiance supérieur, au prix d'environ 3x plus de temps. Le bénéfice s'estompe dès qu'on downsample. Avec un facteur 0.5, le 504 repasse sous le 1008 (23 contre 27 polygones), la réduction de résolution ayant déjà effacé le détail que les petites tuiles auraient exploité. L'avantage du petit tuilage est donc indissociable de la pleine résolution.

#figure(
  lq.diagram(
    width: 12cm,
    height: 5cm,
    xlabel: [Facteur de downsampling],
    ylabel: [Polygones détectés],
    legend: (position: left + top),
    lq.plot((0.25, 0.5, 0.75, 1.0), (15, 23, 32, 36), mark: "o", label: [504x504]),
    lq.plot((0.25, 0.5, 0.75, 1.0), (15, 27, 29, 29), mark: "s", label: [1008x1008]),
  ),
  caption: [Nombre de polygones trouvés selon downsampling
    d
  ],
) <fig-tile-downsample>

#figure(
  lq.diagram(
    width: 12cm,
    height: 5cm,
    xlabel: [Facteur de downsampling],
    ylabel: [Secondes],
    legend: (position: left + top),
    lq.plot((0.25, 0.5, 0.75, 1.0), (4, 9, 18, 33), mark: "o", label: [504x504]),
    lq.plot((0.25, 0.5, 0.75, 1.0), (3, 5, 7, 29), mark: "s", label: [1008x1008]),
  ),
  caption: [Vitesse d'execution selon downsampling
  ],
) <fig-tile-downsample>

Le downsampling à tuile fixe est le plus prométeur. À 1008, les facteurs 1.0 et 0.75 donnent le même nombre de détections pour 3x moins de temps. Un downsampling de 0.5 reste acceptable mais 0.25 effondre la détection avec 15 polygones ce qui vaut la moitié perdue. La remontée apparente du score à 0.25 (0.72) est simplement un artefact de survie càd que seuls les gros objets, à haute confiance subsistent et les petits disparaissant entièrement. Le score moyen seul est donc trompeur, il se lit conjointement au nombre de détections.

Pour la *granularité des labels* à downsampling fixe de 1.0, comparaison du jeu grossier et du jeu précis aux deux tailles de tuile :

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Taille de tuile*],
      text(fill: white)[*Jeu de labels*],
      text(fill: white)[*Polygones*],
      text(fill: white)[*Score moyen*],
      text(fill: white)[*Temps*],
    ),
    [1008×1008], [Grossier (3)], [29], [0,69], [≈ 11,1 s],
    [1008×1008], [Précis (6)], [26], [0,70], [≈ 12,2 s],
    [504×504], [Grossier (3)], [36], [0,72], [≈ 32,7 s],
    [504×504], [Précis (6)], [31], [0,72], [≈ 39,7 s],
  ),
  caption: [Effet de la granularité des labels (downsample 1,0, image de référence)],
) <tab-solo-labels>

Passer de 3 à 6 labels ne coûte presque rien en temps car le tuilage domine devant la requête `FindQuery` ajoutée par label. La granularité redistribue en revanche les détections. Le vocabulaire fin trouve moins de panneaux que le générique `sign`, qui ratisse large (7 contre 15 à 1008), mais davantage de marquages au sol (`road_marking` est plus efficace que `road_mark`), cella est simplemetn du au fait que dans le contexte routier, le marquage est unique, il est plus simple de trouver des panneau publicitaire ou pancartes, ce qui va naturellement augementer le nombre de match. Le label `arrow_marking` ne ressort quasiment jamais (0 puis 1 détection), ce qui est normal vu que dans notre image séléctionée il n'ya volontairement pas de flèche au sol. Le total reste comparable (26 à 36 polygones) : la granularité change surtout _quels_ objets sont retenus, pas leur nombre.

Après discussion avec mon collègue Valentin qui lui travaillait sur la partie analyse pure de NearAI, nous avons remarqués que les bouches d'égout ou de canalisations sont parfois mal voir très mal détectés et cela est simplement du au fait que bien souvent, la couleur du béton est très sombre et similaire à celle d'une plaque de canalisation.

#figure(
  image("../images/sam3BadView.png", width: 100%),
  caption: [La bouche d'égout n'était pas visible par le modèle, après correction elle à été mise par un humain],
) <fig-batch-running>

En resumé, pour eviter les faux positifs et avoir les meilleurs résultats, il faut utiliser un vocabulaire plus spécifique au plan routier garder une résolution standard de 1008 et exploiter un downsampling de 0.75.

=== Job Batch

Le batch ne refait pas le sweep de paramètres : par image, le coût est identique au solo. Sa valeur propre est le *throughput* et la scalabilité avec le nombre de workers. 40 images issues du même jeu (même appareil, mêmes conditions météo) que le run solo sont traitées avec les trois labels grossiers (`sign`, `manhole`, `road_mark`) et un downsample de 0,5, pour deux tailles de tuile (1008 et 504). Le nombre de détections est identique quel que soit le nombre de workers (843 en 1008, 921 en 504) : le dispatch round-robin ne change que le temps, pas le résultat.

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
    [1], [185 s], [778], [1,0×],
    [3], [75 s], [1920], [2,47×],
  ),
  caption: [Batch 40 images : scalabilité selon le nombre de workers (1008×1008, downsample 0,5)],
) <tab-batch-scaling-1024>

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
    [1], [323 s], [446], [1,0×],
    [3], [128 s], [1125], [2,52×],
  ),
  caption: [Batch 40 images : scalabilité selon le nombre de workers (504×504, downsample 0,5)],
) <tab-batch-scaling-512>

Pendant ces runs, l'utilisation des trois GPUs relevée par DCGM (cf. @fig-gpu-batch) monte simultanément à 90–100 %, confirmant que les workers travaillent en parallèle et non en série.

// TODO : commenter la linéarité du speed-up (étape d'inférence embarrassingly parallel, cf. @resultats).
//
// TODO : Ajouté en graphe avec en axe des coordonnées le temps écoulé et en axe des absicices le % de complétion
...

=== Segmenatation à la volée

Pour la segmentation à la volée, n'importe quelle image peut être utilisée car ici le job va simplement faire une prédiction selon à un label donnée à une coordonée donnée.

=== Batch Dataset Vevey

Le run de production sur le dataset Vevey traite l'ensemble des 14'207 images en un seul batch, sur trois workers L40S (`iict-suchet`), en tuile 1008 et downsample 0,75. Deux configurations de labels ont été exécutées sur le même jeu, de la plus grossière (3 labels génériques) à la plus fine (6 labels précis) :

- *3 labels* : `sign`, `road_mark`, `manhole`
- *6 labels* : `circular_sign`, `rectangular_sign`, `circular_manhole_cover`, `rectangular_drain_grate`, `road_marking`, `arrow_marking`

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Jeu de labels*],
      text(fill: white)[*Temps total*],
      text(fill: white)[*Détections*],
      text(fill: white)[*Débit*],
      text(fill: white)[*Temps/image*],
    ),
    [3 (générique)], [8 h 04 min], [397'741], [≈ 1760 img/h], [≈ 2,0 s],
    [6 (précis)], [10 h 23 min], [423'819], [≈ 1368 img/h], [≈ 2,6 s],
  ),
  caption: [Run de production Vevey (14'207 images, 3 workers L40S, tuile 1008, downsample 0,75) : effet du nombre de labels],
) <tab-run-vevey>

Le temps total ne double pas avec le nombre de labels. Passer de 3 à 6 labels (×2) n'allonge le run que de 8 h 04 à 10 h 23 (×1,29), et le nombre de détections ne croît que de 397'741 à 423'819. L'essentiel du temps est un coût fixe (téléchargement, downsampling, tuilage, I/O), indépendant du nombre de labels ; seule la partie inférence croît avec eux, conformément à la structure une requête `FindQuery` par label et par tuile. Entre ces deux runs, chaque label supplémentaire ajoute ≈ 46 min (2'777 s) au-dessus d'un coût fixe estimé à ≈ 5 h 45.

== Exploitation des résultats

=== Scores de confiance

// TODO : histogramme des scores SAM3 sur un run réel (depuis les Parquet).

=== Exemples visuels dans Label Studio

#figure(
  image("../images/firstOutputLabelStudio.png", width: 90%),
  caption: [Pré-annotations SAM3 importées dans Label Studio depuis un fichier Parquet converti],
) <fig-labelstudio-output>


#figure(
  image("../images/outputManualyFixed.png", width: 90%),
  caption: [Annotations corrigées manuelment],
) <fig-labelstudio-output>

=== Comparaison des runs Solo avec notation humaine



== Observabilité en production

=== Métriques GPU (DCGM)

DCGM Exporter, installé par le GPU Operator NVIDIA, expose les métriques GPU (utilisation, mémoire, température, puissance) à Prometheus. Pendant un run, le suivi de l'utilisation et de la VRAM par worker confirme que les GPUs ciblés sont effectivement saturés et qu'aucun n'est sous-employé (@fig-gpu-batch).

#figure(
  image("../images/gpuUsageBatchBenchmark.png", width: 100%),
  caption: [Utilisation GPU (%) mesurée par DCGM pendant les runs batch de scalabilité : les trois workers (une couleur par GPU) montent ensemble à 90–100 %. Les pics étroits correspondent aux runs 1008×1008 (≈ 15 tuiles/image, vite traités), les plateaux larges et soutenus aux runs 504×504 (≈ 55 tuiles/image) ; les creux à 0 % marquent le warmup et les téléchargements S3 entre images.],
) <fig-gpu-batch>

...

=== Dashboard Grafana

Grafana corrèle sur une même vue les métriques Prometheus (GPU, CPU, mémoire des pods) et les logs Loki. Un pic d'utilisation GPU se relit directement à côté des logs du worker correspondant.

// TODO : capture du dashboard Grafana.
//
//
...


#figure(
  ```log
  INFO:__main__:Done: 14207 images, 397741 detections
     Wall time   : 29057s (2.0s/images)
     Worker avg  : 6.1s/image (summed over workers)
  ```,
  caption: [Derniers logs d'un job solo ou batch. Ici dans le cas d'un batch, ces dernières lignes servent à alimenter le dashboard grafana pour avoir un résultat plus lisible et accesible lors du design de celui-ci.],
) <fig-ray-logs>


#figure(
  image("../images/batchRunning.png", width: 100%),
  caption: [Viusalisation d'un run sur le dataset de Vevey],
) <fig-batch-running>


=== Logs Ray dans Grafana

```bash

```

#figure(
  ```log
  2026-07-03 11:04:25.706 INFO:__main__:Progress: 40 % (5683/14207)
  2026-07-03 10:46:38.484 INFO:__main__:Progress: 39 % (5541/14207)
  2026-07-03 10:31:13.111 INFO:__main__:Progress: 38 % (5399/14207)
  2026-07-03 10:17:09.447 INFO:__main__:Progress: 37 % (5257/14207)
  2026-07-03 10:02:56.138 INFO:__main__:Progress: 36 % (5115/14207)
  2026-07-03 09:49:19.657 INFO:__main__:Progress: 35 % (4973/14207)
  ```,
  caption: [Extrait des logs depuis Graphana. Les logs on été choisis et affichés selon leur catégories.],
) <fig-ray-logs>


#figure(
  ```log
  (autoscaler +8h4m3s) Removing 1 nodes of type workers (max number of worker nodes reached).
  (autoscaler +8h4m3s) Resized to 18 CPUs, 2 GPUs.
  (SAM3Worker ip=10.42.17.137) 69 polygons over 32 tiles in 9.0s {'sign': 23, 'road_mark': 36, 'manhole': 10}
  (SAM3Worker ip=10.42.17.137) pano_0002_021707.jpg -> 69 detections in 9.4s
  (SAM3Worker ip=10.42.17.137) Downsampling 8000x4000 -> 6000x3000 (factor 0.75)
  ```,
  caption: [Extrait des logs Ray d'un run Vevey. L'autoscaler plafonne à 2 GPUs,
    puis un worker traite une image 8000×4000 downsamplée à 0,75 (→ 6000×3000),
    soit 32 tuiles de 1008 px, en 9 s.],
) <fig-ray-logs>

=== Ray

Promtail tourne en DaemonSet et expédie les `stdout`/`stderr` de chaque pod vers Loki, stocké sur MinIO (bucket dédié `nearai-logs`, rétention 30 jours). Les logs des workers Ray se requêtent en LogQL par label.

=== Pods



...

== Goulots d'étranglement <bottlenecks>

Identifier le maillon limitant conditionne toute décision de mise à l'échelle : inutile d'ajouter des GPUs si le stockage sature, ou d'accélérer les disques si le calcul domine. Chaque étage de la pipeline a été instrumenté (DCGM pour le GPU, métriques MinIO pour le stockage, logs Ray pour le débit) afin de mesurer, et non supposer, où se trouve le goulot au régime de test.

=== Le GPU, goulot au régime actuel

À trois workers, la pipeline est *GPU-bound*. La mesure le confirme directement : pendant le run de production Vevey (14'207 images), l'utilisation des trois GPUs relevée par DCGM tient 90–100 % (cf. @fig-gpu-batch), tandis que MinIO reste au repos (voir plus bas). Le cycle par image l'explique : un `GET` de ~4 Mo (< 100 ms), puis plusieurs secondes d'inférence, puis un petit `PUT` Parquet. Le calcul domine chaque cycle d'un à deux ordres de grandeur sur les I/O.

Le plafond pratique n'est donc pas l'architecture de la pipeline mais le *nombre de GPUs libres* : pendant les tests, seuls trois workers ont pu être schedulés simultanément, le scheduler renvoyant `Insufficient nvidia.com/gpu` pour les suivants, les autres cartes étant occupées par d'autres namespaces. L'étape d'inférence étant *embarrassingly parallel* (chaque tuile traitée indépendamment), le débit croît avec le nombre de GPUs jusqu'à ce que le stockage devienne le maillon limitant — seuil qui n'est pas atteint à cette échelle.

=== Le stockage MinIO, latent mais pas actif

MinIO tourne sur un unique nœud NAS Synology, exposant *un seul volume* (`mc admin info` : pool unique, 1 drive, `EC:0`, 126 TiB dont 8,5 TiB utilisés). Cette topologie sans erasure coding ni parallélisme multi-disque en fait le point de contention *théorique* de l'architecture.

Or la mesure montre qu'il ne l'est pas au régime actuel. Pendant le run de production, l'occupation disque (`minio_node_drive_perc_util`) et les requêtes `getobject` en vol (`minio_s3_requests_inflight_total`) restent à zéro sur les fenêtres échantillonnées, et une trace live (`mc admin trace`) ne capture aucune requête sur plusieurs secondes. Le volume à lire — 14'207 images de ~4 Mo, soit ~57 Go sur ~8 h — représente *~2 Mo/s de débit moyen*, deux à trois ordres de grandeur sous la capacité du NAS.

Le stockage redeviendrait le goulot dans deux cas : (1) un parallélisme GPU bien supérieur (des dizaines de workers lisant de front), ou (2) la charge *métadonnées* — le driver liste l'intégralité du préfixe au démarrage (`list_images`) et, en reprise, tous les Parquet déjà écrits (`already_processed`), d'où les volumes cumulés observés (`listobjectsv1` : 2,2 M, `headobject` : 1,9 M). Ces pics sont concentrés au démarrage et à la reprise, pas en régime établi.

// TODO : chiffrer le plafond réel de MinIO avec `mc support perf object/drive/net` (run à vide) → comparer aux ~2 Mo/s réels pour quantifier la marge exacte.

#figure(
  table(
    columns: (auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Étage*], text(fill: white)[*État au régime 3 GPUs*], text(fill: white)[*Devient limitant si*]
    ),
    [GPU], [Saturé (90–100 %)], [— (maillon actif)],
    [Nombre de GPUs libres], [Plafond à 3 (contention multi-namespace)], [Priorité / quota cluster],
    [Stockage MinIO], [Au repos (~2 Mo/s, util ≈ 0 %)], [Dizaines de workers, ou pics métadonnées],
    [Réseau], [Non saturé], [Débit agrégé ≫ actuel],
  ),
  caption: [Localisation du goulot d'étranglement par étage de la pipeline],
) <tab-bottlenecks>

Au régime actuel, accélérer la pipeline passe par *plus de GPUs*, pas par un stockage plus rapide. C'est ce qui oriente l'arbitrage de coût vers la location de GPUs (cf. @conclusion) plutôt que vers une refonte du stockage, le NAS on-premise gardant une large marge.


== Problème rencontré lors des tests

SAM3 n'accepte qu'une entrée de 1008×1008. Comme tout modèle basé sur ViT, il ne voit pas des pixels mais des patches de 14x14 pixels qui sont à des positions précises lors de l'execution. Ce qui nous donne une grille de 72 patchs par tuile (1008 ÷ 14 = 72). La table qui contient les informations sur les patchs et leur position est calculée *une* seule fois et reste figée pour la suite, si on change la taille de la tuille, nous aurons un conflit avec la table des position et une erreur sur le backbone à traver une assertion#footnote[`assert freqs_cis.shape == (x.shape[-2], x.shape[-1])` dans `vitdet.py`.].

Nous l'avons vérifié sur l'image de référence des tuiles de 512, 644, 672 ou 1024 plantent toutes, seule la résolution 1008x1008 passe.

Le predictor officiel de SAM3 contourne le problème en redimensionnant chaque image en 1008 avant le backbone. Notre pipeline ne le faisait pas il se contentait de normaliser la taille et ne fonctionnait que parce que les tuiles valaient déjà 1008. La correction redimensionne chaque tuile en 1008×1008 dans `_make_datapoint`, tout en conservant sa taille réelle comme `original_size` : le post-traitement (`use_original_sizes_mask`) re-projette le masque prédit sur la tuile d'origine, le recollage reste donc inchangé. La taille de tuile redevient ainsi un paramètre libre, découplé de la résolution figée du modèle.

*Tuilage* et *downsampling* sont alors deux axes distincts.

La taille de tuile fixe la portion d'image couverte à pleine résolution. Comme chaque tuile est ensuite ramenée à 1008, le coût par tuile est constant. Une tuile plus petite (504) couvre moins de terrain et se retrouve agrandie 2x. Davantage de tuiles, une vue rapprochée des petits objets, mais un run plus lent.

Le downsampling, lui, réduit la résolution de l'image entière avant le tuilage : moins de tuiles de 1008 et un détail globalement plus grossier. Les deux ne se rejoignent que vers le haut car une tuile plus grande que 1008 est réduite à 1008, ce qui revient exactement à downsampler cette zone, sans intérêt. Le levier utile du tuilage va donc vers le bas (504), celui de la résolution vers le downsampling.
