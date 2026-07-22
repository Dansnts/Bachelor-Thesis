#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#import "@preview/lilaq:0.5.0" as lq
#show: codly-init.with()

#let col-blue = rgb("#2563EB")

= Résultats <resultats>

== Environnement

Le cluster expose 9 GPUs (cf. @tab-gpus). Pour ces tests, jusqu'à trois workers ont été schedulés simultanément, tous sur `iict-suchet`.

Chaque worker Ray reçoit un GPU dédié, 4 CPU et 16 Gio de mémoire garantis (jusqu'à 8 CPU et 32 Gio en pointe). Le head, qui ne porte aucun GPU, tient dans 2 CPU et 4 Gio, un dimensionnement dont les limites sont discutées dans @bottlenecks.

Travailler sur chasseron est compliqué : ses pods subissent des évictions liées au taint `disk-pressure`, c'est pourquoi le nœud est exclu par `nodeAffinity` (ses L4 sont en outre moins puissants). Les A40 de `iict-k8s-node4-rad` restent utilisables, mais les benchmarks et le run de production ont été menés sur les L40S du nœud suchet afin d'obtenir les meilleurs résultats possibles. Les A40 n'ont servi qu'à la comparaison entre cartes (cf. @tab-l40s-a40 et l'analyse des coûts, @couts).

#pagebreak()

== Méthodologie des runs

La méthode utilisée pour les runs est One-factor-at-a-time (OFAT) : on fixe une image de référence et on ne fait varier qu'un seul paramètre par sweep.

Le plan d'expériences sépare ce qui est _prévisible_ de ce qui ne l'est pas. Le temps d'inférence suit le modèle :

$ "temps" approx "nombre de tuiles" times "coût par tuile" $

où le nombre de tuiles est proportionnel à : $ frac("largeur" times "hauteur" times "downsampling"^2, "stride"^2) $

Des trois paramètres de cette formule, la taille de tuile et le downsampling sont balayés dans les runs qui suivent, le stride, lui, garde un ratio fixe de 76 % de la taille de tuile (768 px pour la tuile de 1008, 384 px pour celle de 504). Ce ratio mérite d'être justifié, car le nombre de tuiles varie en $1 slash "stride"^2$ : tout recouvrement supplémentaire renchérit le calcul de façon quadratique.

Par exemple : un stride de 768 sur une tuile de 1008 laisse un recouvrement de $1008 - 768 = 240$ px, soit ~24 % de la tuile. Concrètement, tout objet de moins de 240 px de large est capté entier dans au moins une tuile, ce qui couvre les panneaux, plaques et marquages dans une image panoramique de 8000 px de large. Le @tab-stride chiffre l'arbitrage sur l'image de référence :

#figure(
  image("../images/stride.png", width: 60%),
  caption: [
    Avec des tuiles de 1008 px et un stride de 768 px, deux tuiles voisines se chevauchent de 240 px, soit 24 % de recouvrement.
  ],
) <fig-stride-overlap>



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

Passer d'un découpage sans recouvrement (stride égal à la taille de tuile) à un stride de 768 px ne coûte que +72 % de tuiles tout en supprimant le risque de coupure sur les objets courants. Descendre à 504 (recouvrement de 50 %) triple le nombre de tuiles pour ne rattraper que des objets plus gros, déjà souvent captés par d'autres tuiles adjacentes.

Ce recouvrement de 24 % est donc un compromis raisonné, non un optimum, sa valeur idéale se calibrerait sur la distribution réelle des tailles d'objets, ce qui reste un axe d'amélioration mais sortirait du cadre de ce travail étant donné le nombre de tests supplémentaires.

Le dataset Vevey est homogène en résolution : les 14'207 images de l'acquisition font toutes 8000×4000 pixels, il n'y a donc qu'une seule taille native à tester. Ce volume permet à la fois d'isoler chaque paramètre au cas par cas et de mener des runs conséquents à haute résolution pour valider la solidité de la pipeline.

#figure(
  image("../images/pano_0002_004731.jpg", width: 80%),
  caption: [
    Pour les runs en solo, l'image de référence est la `pano_0002_004731.jpg` (8000×4000, 32 MP), tirée du jeu de Vevey.

  ],
) <imageReference>


La réduction de résolution est explorée via le downsampling : downsampler une image 8000×4000 à 0,5 revient à traiter une image 4000×2000, ce qui couvre toute la plage de tailles effectives.

SAM3 n'accepte qu'une entrée de 1008×1008. Comme tout modèle basé sur ViT, il ne voit pas des pixels mais des patches de 14×14 pixels placés à des positions précises, soit une grille de 72 patches par tuile (1008 ÷ 14 = 72). La table qui contient ces positions est calculée *une* seule fois et reste figée pour la suite : changer la taille de tuile crée un conflit avec elle et fait échouer le backbone sur une assertion#footnote[`assert freqs_cis.shape == (x.shape[-2], x.shape[-1])` dans `vitdet.py`.].

Nous l'avons vérifié sur l'image de référence : des tuiles de 512, 644, 672 ou 1024 plantent toutes, seule la résolution 1008×1008 passe.

Le predictor officiel de SAM3 contourne le problème en redimensionnant chaque image en 1008 avant le backbone. La pipeline ne le faisait pas : elle se contentait de normaliser la taille et ne fonctionnait que parce que les tuiles valaient déjà 1008.

La correction redimensionne chaque tuile en 1008×1008 dans `_make_datapoint`, tout en conservant sa taille réelle comme `original_size` : le post-traitement (`use_original_sizes_mask`) re-projette le masque prédit sur la tuile d'origine, le recollage reste donc inchangé. La taille de tuile redevient ainsi un paramètre libre, découplé de la résolution figée du modèle.

*Tuilage* et *downsampling* sont alors deux axes distincts.

La taille de tuile fixe la portion d'image couverte à pleine résolution. Comme chaque tuile est ensuite ramenée à 1008, le coût par tuile est constant. Une tuile plus petite (504) couvre moins de terrain et se retrouve agrandie ×2. Davantage de tuiles, une vue rapprochée des petits objets, mais un run plus lent.

Le downsampling, lui, réduit la résolution de l'image entière avant le tuilage : moins de tuiles de 1008 et un détail globalement plus grossier. Les deux ne se rejoignent que vers le haut car une tuile plus grande que 1008 est réduite à 1008, ce qui revient exactement à downsampler cette zone, sans intérêt. Le levier utile du tuilage va donc vers le bas (504), celui de la résolution vers le downsampling.


Deux jeux de labels sont comparés. Le jeu *grossier* (3 labels) regroupe les familles d'objets, le jeu *précis* (6 labels) les sous-divise, selon le mapping suivant :

#figure(
  grid(
    columns: 2,
    column-gutter: 28pt,
    align: top,
    table(
      columns: (auto,),
      fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
      table.header(text(fill: white)[*Jeu grossier (3 labels)*]),
      [`sign`],
      [`manhole`],
      [`road_mark`],
    ),
    table(
      columns: (auto, auto),
      fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
      table.header(table.cell(colspan: 2, text(fill: white)[*Jeu précis (6 labels)*])),
      [`circular_sign`], [`rectangular_sign`],
      [`circular_manhole_cover`], [`rectangular_drain_grate`],
      [`road_marking`], [`arrow_marking`],
    ),
  ),
  caption: [Les deux jeux de labels comparés, une ligne par famille d'objets : le jeu précis subdivise chaque label grossier.],
) <tab-labels>

Chaque label est une requête `FindQuery` distincte par tuile, le coût d'inférence croît donc à peu près linéairement avec le nombre de labels.

La vitesse peut se déduire mais la qualité de segmentation, elle, n'est pas prévisible analytiquement, c'est là que les runs empiriques sont concentrés.


== Run Solo <run-solo>

La contrainte d'entrée décrite plus haut rend la taille de tuile libre (le mécanisme de redimensionnement est détaillé au chapitre implémentation, cf. @implementation). Nous croisons la taille native 1008×1008 et 504×504 avec les quatre facteurs de downsampling.

Le temps mesuré couvre le traitement d'une image (tuilage, inférence, polygonisation, écriture du résultat), hors chargement du modèle (≈ 54 s, amorti sur un batch). Le score est la confiance moyenne de SAM3 (0 à 1) sur les polygones retenus. Tous les runs de cette section ont été exécutés sur une L40S.

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
  caption: [Résultats sur l'image de référence (8000×4000) : deux tailles de tuile croisées avec quatre facteurs de downsampling.],
) <tab-solo-tile>

À pleine résolution, le tuilage 504 détecte environ 1,2× plus d'objets que celui à 1008 (36 contre 29), avec un score de confiance supérieur, au prix d'environ 3× plus de temps. Le bénéfice s'estompe dès qu'on downsample. Avec un facteur 0,5, le 504 repasse sous le 1008 (23 contre 27 polygones), la réduction de résolution ayant déjà effacé le détail que les petites tuiles auraient exploité. L'avantage du petit tuilage est donc indissociable de la pleine résolution.

#figure(
  lq.diagram(
    width: 12cm,
    height: 5cm,
    xlabel: [Facteur de downsampling],
    ylabel: [Polygones détectés],
    legend: (position: left + top),
    lq.plot((0.25, 0.5, 0.75, 1.0), (15, 23, 32, 36), mark: "o", label: [504×504]),
    lq.plot((0.25, 0.5, 0.75, 1.0), (15, 27, 29, 29), mark: "s", label: [1008×1008]),
  ),
  caption: [Nombre de polygones détectés selon le facteur de downsampling, pour les deux tailles de tuile.],
) <fig-tile-downsample>

#figure(
  lq.diagram(
    width: 12cm,
    height: 5cm,
    xlabel: [Facteur de downsampling],
    ylabel: [Secondes],
    legend: (position: left + top),
    lq.plot((0.25, 0.5, 0.75, 1.0), (4.3, 9.0, 18.1, 32.7), mark: "o", label: [504×504]),
    lq.plot((0.25, 0.5, 0.75, 1.0), (3.2, 5.1, 7.8, 11.1), mark: "s", label: [1008×1008]),
  ),
  caption: [Temps de traitement selon le facteur de downsampling, pour les deux tailles de tuile.],
) <fig-downsample-time>

Le downsampling à tuile fixe est le levier le plus prometteur. À 1008, les facteurs 1,0 et 0,75 donnent le même nombre de détections (29), le second avec 30 % de temps en moins (7,8 s contre 11,1 s). Un downsampling de 0,5 reste acceptable, mais 0,25 effondre la détection : 15 polygones, la moitié perdue. La remontée apparente du score à 0,25 (0,72) est un artefact de survie, c'est-à-dire que seuls les gros objets à haute confiance subsistent, les petits ayant entièrement disparu. Le score moyen seul est donc trompeur, il se lit conjointement au nombre de détections.

Pour la *granularité des labels* à downsampling fixe de 1,0, comparaison du jeu grossier et du jeu précis aux deux tailles de tuile :

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

Passer de 3 à 6 labels ne coûte presque rien en temps car le tuilage domine devant la requête `FindQuery` ajoutée par label. La granularité redistribue en revanche les détections. Le vocabulaire fin trouve moins de panneaux que le générique `sign` (7 contre 15 à 1008), qui ratisse large en captant aussi les panneaux publicitaires et les pancartes, mais davantage de marquages au sol, `road_marking` se révélant plus efficace que `road_mark` car le terme est univoque dans le contexte routier. Le label `arrow_marking` ne ressort quasiment jamais (0 puis 1 détection), ce qui est attendu, l'image choisie ne comportant volontairement aucune flèche au sol. Le total reste comparable (26 à 36 polygones) : la granularité change surtout _quels_ objets sont retenus, pas leur nombre.

Après discussion avec mon collègue Valentin (cf. @introduction), nous avons remarqué que les bouches d'égout et plaques de canalisation sont parfois mal, voire très mal, détectées. La cause est simple : un béton sombre a souvent une couleur très proche de celle d'une plaque de canalisation.

#figure(
  image("../images/sam3BadView.png", height : 30%),
  caption: [La bouche d'égout n'a pas été vue par le modèle, elle a été ajoutée à la main lors de la correction.],
) <fig-badview-manhole>


#figure(
  image("../images/sam3BadView2.png", width: 80%),
  caption: [Cas récurrent lié à la luminosité : une partie de l'objet est oubliée, ici la moitié de la ligne jaune.],
) <fig-badview-line>

La segmentation à la volée n'échappe pas à ces limites. Elle accepte n'importe quelle image, le service prédisant simplement l'objet situé sous le point cliqué pour le label fourni :

#figure(
  image("../images/sam3BadView3.png", width: 80%),
  caption: [Segmentation à la volée au point du curseur (à gauche) avec le label `circular_manhole_cover` : le modèle hallucine et retient une partie de la bordure au lieu de la bouche d'égout.],
) <fig-badview-hallucination>

En résumé, éviter les faux positifs demande un *vocabulaire spécifique au domaine routier*. Le meilleur rapport qualité/coût revient à la *tuile standard de 1008* avec un *downsampling de 0,75* : le tuilage 504 à pleine résolution détecte davantage (36 polygones contre 29), mais au triple du temps de calcul.


== Comparaison L40S vs A40

Les deux GPUs disponibles pour les workers diffèrent par leur architecture, Ada Lovelace (2022) pour le L40S @l40s-datasheet et Ampere (2020) pour l'A40 @a40-datasheet. Tous deux embarquent 48 Go en GDDR6, mais le L40S domine sur la plupart des métriques.

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
    [CUDA Cores], [18'176], [10'752], [×1,69],
    [Tensor Cores], [568 (4ᵉ gén)], [336 (3ᵉ gén)], [—],
    [BF16 Tensor TFLOPS], [362], [149,7], [*×2,42*],
    [FP32 TFLOPS], [91,6], [37,4], [×2,45],
    [Bande passante mémoire], [864 Go/s], [696 Go/s], [×1,24],
    [Mémoire], [48 Go GDDR6], [48 Go GDDR6], [×1,00],
    [Puissance max], [350 W], [300 W], [×1,17],
  ),
  caption: [Spécifications L40S vs A40 (datasheets NVIDIA @l40s-datasheet @a40-datasheet)],
) <tab-l40s-a40>

SAM3 tourne en `bfloat16` (cf. @architecture), la métrique pertinente est donc le débit BF16 Tensor, le L40S annonce 362 TFLOPS contre 149,7 pour l'A40, un ratio théorique de *2,42×*. Or, sur une image de 8000×4000 avec une tuile de 504×504 et 3 labels, le L40S traite les 231 tuiles en 32,7 s (0,14 s/tuile) contre 48,8 s (0,21 s/tuile) pour l'A40, soit un gain mesuré de seulement *1,49×*.

L'écart entre le ratio théorique (2,42×) et le gain observé (1,49×) montre que l'inférence par tuiles n'est pas purement liée aux spécifications de l'hardware #footnote[Sans compter la _silicon lottery_ : deux exemplaires d'un même modèle n'atteignent pas exactement la même performance, une puce donnée pouvant se situer dans la fourchette haute ou basse de sa gamme.]. Le gain mesuré se situe entre le ratio de bande passante mémoire (×1,24) et le ratio de calcul (×2,42), plus proche du premier.

Le temps par tuile est en partie dicté par les transferts mémoire et les surcoûts (préparation des tenseurs, dispatch Python, accès à la RAM, etc.), pas seulement par la puissance tensorielle brute. Le scheduler ne distinguant pas les modèles de GPU (sauf affinité dédiée à un seul type de carte), un run mixte est cadencé par les workers les plus lents, un pool homogène de L40S maximise donc le throughput.

#pagebreak()
Les quatre runs A40 reprennent le sweep de downsampling du run solo (tuile 504, 3 labels grossiers, image de référence), lancés sur `iict-k8s-node4-rad` :

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Downsampling*],
      text(fill: white)[*Nombre tuiles*],
      text(fill: white)[*Temps L40S*],
      text(fill: white)[*Temps A40*],
      text(fill: white)[*Ratio A40/L40S*],
    ),
    [1,0], [231], [32,7 s], [48,8 s], [1,49×],
    [0,75],
    [128],
    [18,1 s],
    [≈ 28,4 s#footnote[Temps reconstruit à partir des timestamps du log (la ligne de synthèse est absente), donc légèrement surestimé : il inclut l'écriture du résultat sur S3.]],
    [≈ 1,57×],

    [0,5], [55], [9,0 s], [12,1 s], [1,34×],
    [0,25], [15], [4,3 s], [4,4 s], [1,02×],
  ),
  caption: [Comparaison L40S vs A40 : runs solo sur l'image de référence (8000×4000), tuile 504×504, 3 labels grossiers.],
) <tab-l40s-a40-mesures>

#figure(
  lq.diagram(
    width: 12cm,
    height: 5cm,
    xlabel: [Facteur de downsampling],
    ylabel: [Temps en secondes],
    legend: (position: left + top),
    lq.plot((0.25, 0.5, 0.75, 1.0), (4.4, 12.1, 28.4, 48.8), mark: "o", label: [A40]),
    lq.plot((0.25, 0.5, 0.75, 1.0), (4.3, 9.0, 18.1, 32.7), mark: "s", label: [L40S]),
  ),
  caption: [Temps par image selon le downsampling : quasi identiques à 0,25, les deux cartes s'écartent réellement entre 0,75 et 1,0.],
) <fig-l40s-a40-temps>

Le ratio suit la charge : de 1,02× à 15 tuiles, où les coûts fixes (téléchargement, tuilage, écriture) dominent et masquent le GPU, il monte à 1,49× à 231 tuiles, où l'inférence occupe l'essentiel du temps. L'avance du L40S croît donc avec le travail par image. Les détections, elles, sont strictement identiques d'une carte à l'autre (mêmes polygones, mêmes scores) : changer de GPU ne modifie que le temps, jamais le résultat.

Le seul intérêt de mélanger les GPUs est donc d'augmenter le nombre de workers disponibles, au prix d'un run cadencé par les cartes les plus lentes.

#pagebreak()
== Job batch

Le batch ne refait pas le sweep de paramètres : par image, le coût est identique au solo. Sa valeur propre est le *throughput* et la scalabilité avec le nombre de workers. 40 images issues du même jeu (même appareil, mêmes conditions météo) que le run solo sont traitées avec les *trois labels grossiers* (`sign`, `manhole`, `road_mark`) et un *downsample de 0,5*, pour deux tailles de tuile (1008 et 504). Le nombre de détections est identique quel que soit le nombre de workers (843 en 1008, 921 en 504).

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
  caption: [Batch 40 images avec tuiles de 1008 : scalabilité selon le nombre de workers],
) <tab-batch-scaling-1024>

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
  caption: [Batch 40 images avec tuiles de 504 : scalabilité selon le nombre de workers],
) <tab-batch-scaling-512>

#linebreak()
L'utilisation GPU relevée pendant ces runs (cf. @fig-gpu-batch) confirme que les trois workers travaillent en parallèle et non en série.

Le speed-up mesuré (2,47× en 1008, 2,52× en 504) reste toutefois sous le 3× idéal. Sur un lot de 40 images, les coûts fixes pèsent encore : chaque worker paie son warmup avant sa première image, et le lot ne se divise pas exactement en trois, deux workers reçoivent 13 images et le troisième 14, le run se terminant au rythme du plus chargé. Ces effets s'estompent avec la taille du lot, comme le confirme le run de production où le même passage de un à trois workers atteint 2,99× (cf. @tab-run-vevey-scaling).


== Batch dataset Vevey

Le run de production sur le dataset Vevey traite l'ensemble des 14'207 images en un seul batch, sur trois workers L40S (`iict-suchet`), en tuile 1008 et downsample 0,75. Les deux configurations de labels décrites au @tab-labels ont été exécutées sur le même jeu, le jeu grossier de 3 labels puis le jeu précis de 6.

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

Le temps total ne double pas avec le nombre de labels. Passer de 3 à 6 labels (×2) n'allonge le run que de 8h04 à 10h23 (×1,29), et le nombre de détections ne croît que de 397'741 à 423'819. L'essentiel du temps est un coût fixe (téléchargement, downsampling, tuilage, I/O), indépendant du nombre de labels. Seule la partie inférence croît avec eux, à raison d'une requête `FindQuery` par label et par tuile. Entre ces deux runs, chaque label supplémentaire ajoute ≈ 46 min (2'777 s) au-dessus d'un coût fixe estimé à ≈ 5h45.

Le run de production permet aussi de mesurer la scalabilité à grande échelle, là où le micro-benchmark de 40 images était trop bruité par le warmup. Le run 6 labels a été rejoué sur le même jeu complet avec un *seul* worker, pour le comparer à la version à trois workers.

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
    [1], [31 h 05 min], [≈ 457], [1,0×],
    [3], [10 h 23 min], [≈ 1368], [2,99×],
  ),
  caption: [Run de production Vevey (14'207 images, 6 labels précis, tuile 1008, downsample 0,75) : scalabilité 1 → 3 workers L40S.],
) <tab-run-vevey-scaling>

Les deux runs produisent exactement les mêmes 423'819 détections : le dispatch round-robin ne change que le temps, jamais le résultat. Le passage d'un à trois workers donne un speed-up de *2,99×*, quasi parfait, très au-dessus du 2,52× mesuré sur les 40 images (cf. @tab-batch-scaling-512). Sur un dataset assez grand pour saturer durablement les GPUs, le coût fixe (warmup, JIT, cache disque) est amorti et chaque worker travaille en continu, confirmant empiriquement le caractère *embarrassingly parallel* de l'inférence par tuiles : le débit croît linéairement avec le nombre de GPUs libres.


== Exploitation des résultats

Les scores présentés ici sont agrégés directement depuis les Parquet du run de production Vevey. Sur ce jeu, 14'083 images portent au moins une détection (124 sont vides), soit ≈ 30 détections par image. La confiance moyenne toutes classes confondues est de 0,676 (médiane 0,664), pour un seuil de détection fixé à 0,5 dans SAM3.

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Label*],
      text(fill: white)[*Détections*],
      text(fill: white)[*Part*],
      text(fill: white)[*Score moyen*],
    ),
    [`road_marking`], [249'064], [58,8 %], [0,671],
    [`rectangular_sign`], [57'669], [13,6 %], [0,642],
    [`circular_manhole_cover`], [46'981], [11,1 %], [0,721],
    [`circular_sign`], [38'329], [9,0 %], [0,705],
    [`rectangular_drain_grate`], [17'157], [4,0 %], [0,715],
    [`arrow_marking`], [14'619], [3,4 %], [0,622],
    [*Total*], [*423'819*], [100 %], [*0,676*],
  ),
  caption: [Distribution des détections par label et score moyen (run Vevey 6 labels, 14'207 images)],
) <tab-score-labels>

Le `road_marking` domine largement (58,8 % des détections) : dans un contexte routier, le marquage au sol est omniprésent et chaque bande ou ligne compte comme un polygone distinct. Les formes circulaires, géométriquement nettes, obtiennent les meilleures confiances (`circular_manhole_cover` 0,721, `circular_sign` 0,705), tandis que les flèches (`arrow_marking` 0,622) et les panneaux rectangulaires (`rectangular_sign` 0,642), plus facilement confondus avec des façades ou des panneaux publicitaires, sont les moins bien notés.

#let bulle-couleurs = (
  rgb("#EAB308"), rgb("#2563EB"), rgb("#16A34A"),
  rgb("#9333EA"), rgb("#0D9488"), rgb("#DC2626"),
)

#figure(
  lq.diagram(
    width: 12cm,
    height: 6.5cm,
    xlabel: [Nombre de détections (milliers)],
    ylabel: [Score de confiance moyen],
    xlim: (-10, 280),
    ylim: (0.60, 0.75),
    legend: (position: right + bottom),
    lq.scatter(
      (249.1, 57.7, 47.0, 38.3, 17.2, 14.6),
      (0.671, 0.642, 0.721, 0.705, 0.715, 0.622),
      size: (2490, 577, 470, 383, 172, 146),
      color: bulle-couleurs,
      alpha: 65%,
    ),
    ..range(6).map(i => lq.scatter(
      (-999,), (0.7,),
      size: (60,),
      color: bulle-couleurs.at(i),
      alpha: 65%,
      label: (
        [`road_marking`], [`rectangular_sign`], [`circular_manhole_cover`],
        [`circular_sign`], [`rectangular_drain_grate`], [`arrow_marking`],
      ).at(i),
    )),
  ),
  caption: [Volume et confiance par label (run Vevey 6 labels) : chaque bulle est un label, sa position donne le nombre de détections et le score moyen, sa surface est proportionnelle au volume. Les formes circulaires sont sûres mais peu nombreuses, le `road_marking` est massif avec une confiance moyenne.],
) <fig-score-bubbles>

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Tranche de score*],
      text(fill: white)[*Détections*],
      text(fill: white)[*Part*],
      text(fill: white)[*Cumulé*],
    ),
    [0,50 – 0,55], [63'102], [14,9 %], [14,9 %],
    [0,55 – 0,60], [69'676], [16,4 %], [31,3 %],
    [0,60 – 0,65], [62'462], [14,7 %], [46,1 %],
    [0,65 – 0,70], [56'998], [13,4 %], [59,5 %],
    [0,70 – 0,75], [52'873], [12,5 %], [72,0 %],
    [0,75 – 0,80], [46'458], [11,0 %], [83,0 %],
    [0,80 – 0,85], [39'164], [9,2 %], [92,2 %],
    [0,85 – 0,90], [25'045], [5,9 %], [98,1 %],
    [0,90 – 0,95], [7'984], [1,9 %], [100,0 %],
    [0,95 – 1,00], [57], [0,0 %], [100,0 %],
  ),
  caption: [Distribution des scores de confiance par tranche (run Vevey 6 labels, 423'819 détections).],
) <tab-score-hist>

La distribution (@tab-score-hist) est concentrée dans le bas de l'échelle : 83 % des détections tombent entre 0,50 et 0,80, et à peine 1,9 % dépassent 0,90. La concentration près du seuil (min mesuré 0,504) indique qu'une part importante des détections passe tout juste la barre des 0,5.

Relever le `detection_threshold` élaguerait donc surtout les détections basses de `road_marking` et `rectangular_sign`, au prix d'un rappel moindre sur les petits objets.


== Qualité des résultats

Les résultats de SAM3 sont en général de bonne qualité et largement exploitables, mais certains éléments sont en trop, d'autres mal détourés, d'autres encore manquants.

#figure(
  image("../images/firstOutputLabelStudio.png", width:75%),
  caption: [Pré-annotations SAM3 importées dans Label Studio depuis un fichier Parquet converti],
) <fig-labelstudio-output>


#figure(
  image("../images/outputManualyFixed.png", width: 75%),
  caption: [Annotations corrigées manuellement],
) <fig-labelstudio-fixed>

Afin de mesurer le gain réel, deux tests ont été chronométrés sur un jeu de 10 images de Vevey : l'annotation manuelle d'images vierges d'une part, la correction d'images pré-annotées par un run batch d'autre part :

#figure(
  table(
    columns: (auto, auto, auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Image*],
      text(fill: white)[*Pré-annotation SAM3*],
      text(fill: white)[*Correction humaine*],
      text(fill: white)[*Total assisté*],
      text(fill: white)[*Annotation manuelle*],
      text(fill: white)[*Gain total de temps*],
    ),
    [1], [7,8 s], [1min44], [1min52], [2min52], [35 %],
    [2], [6,9 s], [1min03], [1min10], [2min40], [56 %],
    [3], [7,9 s], [39 s], [47 s], [1min42], [54 %],
    [4], [6,6 s], [1min06], [1min13], [2min15], [46 %],
    [5], [6,3 s], [1min02], [1min08], [2min10], [47 %],
    [6], [6,1 s], [1min15], [1min21], [2min16], [40 %],
    [7], [6,5 s], [25 s], [32 s], [1min45], [70 %],
    [8], [6,6 s], [35 s], [42 s], [1min58], [65 %],
    [9], [7,3 s], [1min27], [1min34], [2min02], [23 %],
    [10], [6,3 s], [56 s], [1min02], [1min40], [38 %],
    [*Total*],
    [*1min08*#footnote[Somme des temps par image sur les workers. Le wall time réel du batch est de 46 s, les 3 workers travaillant en parallèle.]],
    [*10min12*],
    [*11min20*],
    [*21min20*],
    [*47 %*],
  ),
  caption: [Temps de correction des pré-annotations vs temps SAM3 par image (10 images Vevey, 6 labels précis, tuile 1008, downsample 0,75, 3 workers).],
) <tab-score-e>



Les annotations manuelles restent acceptables et reconnaissables, mais elles sont moins précises géométriquement : l'humain découpe l'objet sans chercher la forme parfaite. Sur une bouche d'égout, le contour SAM3 compte une quarantaine de points contre environ 8 à la main.

#figure(
  image("../images/ComparaisonPrecisionSAMVsHumain.png", width: 80%),
  caption: [Les bouches d'égout de gauche sont annotées par SAM3, celles de droite par un humain.],
) <fig-sam-vs-humain>


== Observabilité en production

DCGM Exporter, installé par le GPU Operator NVIDIA, expose les métriques GPU (utilisation, mémoire, température, puissance) à Prometheus. Pendant un run, le suivi de l'utilisation et de la VRAM par worker confirme que les GPUs ciblés sont effectivement saturés et qu'aucun n'est sous-employé (@fig-gpu-batch).

#figure(
  image("../images/gpuUsageBatchBenchmark.png", width: 80%),
  caption: [Utilisation GPU (%) mesurée par DCGM pendant les runs batch de scalabilité : les trois workers sous L40S (une couleur par GPU) montent ensemble à 90–100 %. Les pics étroits correspondent aux runs 1008×1008 (≈ 15 tuiles/image, vite traités), les plateaux larges et soutenus aux runs 504×504 (≈ 55 tuiles/image). Les creux à 0 % marquent la préparation de la requête, le warmup et les téléchargements S3 entre images.],
) <fig-gpu-batch>


Pour le *dashboard*, Grafana corrèle sur une même vue les métriques Prometheus (GPU, CPU, mémoire des pods) et les logs Loki. Un pic d'utilisation GPU se relit directement à côté des logs du worker correspondant.

Le dashboard dédié aux runs batch (@fig-batch-running) illustre cette corrélation pendant le run de production Vevey. Les tuiles d'état du haut agrègent des signaux extraits des logs des workers : temps d'inférence moyen, tuiles par image, temps de chargement du modèle. La série temporelle suit le temps d'inférence de chaque image, et deux panneaux de logs filtrés affichent la progression du run et les détections par image.

#figure(
  image("../images/BatchRunning.png", width: 80%),
  caption: [Dashboard Grafana des runs batch pendant le run de production Vevey : état des tuiles, temps d'inférence par image, progression et détections extraites des logs Loki.],
) <fig-batch-running>

Les compteurs « dernier run » (images, détections) sont à zéro sur la capture car ils se remplissent à la fin du run, quand le driver écrit sa ligne de synthèse :

#figure(
  ```log
  INFO:__main__:Done: 14207 images, 397741 detections
     Wall time   : 29057s (2.0s/images)
     Worker avg  : 6.1s/image (summed over workers)
  ```,
  caption: [Dernières lignes de log d'un run batch.],
) <fig-batch-final-logs>


=== Logs Ray dans Grafana

Alloy collecte les `stdout`/`stderr` de chaque pod du namespace et les expédie vers Loki, stocké sur MinIO (bucket dédié `nearai-logs`, rétention 30 jours). Les logs se requêtent ensuite en LogQL par label, ce qui permet de filtrer une catégorie précise, ici la progression du run de production :

#figure(
  ```log
  2026-07-03 11:04:25.706 INFO:__main__:Progress: 40 % (5683/14207)
  2026-07-03 10:46:38.484 INFO:__main__:Progress: 39 % (5541/14207)
  2026-07-03 10:31:13.111 INFO:__main__:Progress: 38 % (5399/14207)
  2026-07-03 10:17:09.447 INFO:__main__:Progress: 37 % (5257/14207)
  2026-07-03 10:02:56.138 INFO:__main__:Progress: 36 % (5115/14207)
  2026-07-03 09:49:19.657 INFO:__main__:Progress: 35 % (4973/14207)
  ```,
  caption: [Extrait des logs depuis Grafana, filtrés et affichés par catégorie.],
) <fig-logs-grafana>

Les logs restent aussi consultables à la source (`kubectl logs`, k9s) tant que le pod existe, ce que le TTL prolongé des Jobs (48 h) garantit deux jours après un run. Loki double cette voie d'une copie centralisée qui survit à la suppression des pods : une requête sur le label `app=sam3-batch` rejoue l'historique complet d'un driver disparu, dans la limite des 30 jours de rétention.


== Analyse générale cluster

La vue k9s ci-dessous fige l'état du namespace après une journée de tests : vingt pods, dont l'intégralité de la stack décrite au chapitre architecture.

#figure(
  image("../images/podsK9s.png", width: 100%),
  caption: [Vue k9s des pods du namespace après une journée de tests.],
) <fig-pods-k9s>

La colonne `NODE` matérialise la politique de placement : seuls les pods à GPU sont épinglés, les trois workers Ray tournent sur `iict-suchet` (L40S), tandis que les pods sans GPU (head Ray, API, drivers batch) se répartissent librement sur `iict-chasseron` et `iict-k8s-node4-rad` au gré du scheduler.

La colonne `RESTARTS` est à zéro partout, y compris pour l'API en ligne depuis trois jours et pour Alloy et Prometheus, en place depuis 48 jours. Les consommations confirment le dimensionnement du chapitre architecture : le head occupe 2,1 Gio, soit la moitié de ses 4 Gio, les workers au repos retombent à ≈ 0,5 Gio et quelques pourcents de CPU (le gros de l'inférence vit en VRAM), et la stack d'observabilité complète tient dans ≈ 460 Mio cumulés. L'API illustre au passage l'intérêt de la marge entre requête et limite : elle dépasse sa requête mémoire (181 %) tout en restant à 45 % de sa limite, sans jamais être tuée.

Les onze pods `Completed` en bas de liste sont les drivers des runs batch et solo passés. Ils ne consomment plus rien (0 CPU, 0 mémoire) mais restent listés grâce au TTL prolongé des Jobs, ce qui permet de relire les logs d'un run plusieurs jours après coup, en complément des logs centralisés dans Loki.


== Goulots d'étranglement <bottlenecks>

Identifier le maillon limitant conditionne toute décision de mise à l'échelle : inutile d'ajouter des GPUs si le stockage sature, ou d'accélérer les disques si le calcul domine. Chaque étage de la pipeline a été instrumenté (DCGM pour le GPU, métriques MinIO pour le stockage, logs Ray pour le débit) afin de mesurer, et non supposer, où se trouve le goulot au régime de test.


À trois workers, la pipeline est *GPU-bound*. La mesure le confirme directement : pendant le run de production Vevey (14'207 images), l'utilisation des trois GPUs relevée par DCGM tient 90–100 % (cf. @fig-gpu-batch), tandis que MinIO reste au repos (voir plus bas). Le cycle par image l'explique : un `GET` de ~4 Mo (< 100 ms), puis plusieurs secondes d'inférence, puis un petit `PUT` Parquet. Le calcul domine chaque cycle d'un à deux ordres de grandeur sur les I/O.

Le plafond pratique n'est donc pas l'architecture de la pipeline mais le *nombre de GPUs libres* : pendant les tests, seuls trois workers ont pu être schedulés simultanément, le scheduler renvoyant `Insufficient nvidia.com/gpu` pour les suivants, les autres cartes étant occupées par d'autres namespaces. L'étape d'inférence étant *embarrassingly parallel* (chaque tuile traitée indépendamment), le débit croît avec le nombre de GPUs jusqu'à ce que le stockage devienne le maillon limitant, un seuil qui n'est pas atteint à cette échelle.


MinIO tourne sur un unique nœud NAS Synology, exposant *un seul volume*. Cette topologie sans erasure coding ni parallélisme multi-disque en fait le point de contention *théorique* de l'architecture.

Or la mesure montre qu'il ne l'est pas au régime actuel. Pendant le run de production, l'occupation disque (`minio_node_drive_perc_util`) et les requêtes `getobject` en vol (`minio_s3_requests_inflight_total`) restent à zéro sur les fenêtres échantillonnées, et une trace live (`mc admin trace`) ne capture aucune requête sur plusieurs secondes. Le volume à lire (14'207 images de ~4 Mo, soit ~57 Go sur ~8 h) représente *~2 Mo/s de débit moyen*, deux à trois ordres de grandeur sous la capacité du NAS.

Le stockage redeviendrait le goulot dans deux cas :
1. un parallélisme GPU bien supérieur (des dizaines de workers lisant de front),
2. la charge *métadonnées*, car le driver liste l'intégralité du préfixe au démarrage (`list_images`) et, en reprise, tous les Parquet déjà écrits (`already_processed`), d'où les volumes cumulés observés (`listobjectsv1` : 2,2 M, `headobject` : 1,9 M).

Ces pics sont concentrés au démarrage et à la reprise, pas en régime établi.

Le plafond exact du NAS n'a pas été mesuré : un benchmark de charge (`mc support perf`) solliciterait un stockage partagé avec d'autres projets de l'institut. La marge se lit néanmoins dans l'écart entre le débit observé (~2 Mo/s) et l'ordre de grandeur nominal d'un NAS récent (centaines de Mo/s).

Les deux goulots précédents portent sur le *débit* d'un run. Un troisième, découvert en lançant délibérément plusieurs batchs simultanés, porte sur le *nombre de runs lancés de front*. Chaque driver batch se connecte au cluster en mode Ray Client (`ray://ray-cluster-head-svc:10001`), et le head démarre alors un sous-processus serveur *par connexion* (`ray_client_server_2300x`). Ce processus charge le runtime complet, PyTorch inclus, dans les *2 CPU / 4 Gi* alloués au head.

En pratique, au-delà d'une à deux connexions concurrentes le démarrage du serveur suivant échoue et le driver s'arrête sur `ConnectionAbortedError`. Les retries du driver puis le `backoffLimit` du Job Kubernetes absorbent l'échec (cf. @problemes-driver) : le run finit par passer une fois les connexions précédentes libérées.

Ce plafond n'est pas contraignant, car *paralléliser les soumissions n'apporte rien* : les runs concurrents se disputent les mêmes trois GPUs. Le modèle prévu reste un driver unique qui distribue son travail sur tous les workers, les batchs s'enchaînent en série. Si un jour la soumission concurrente devient utile (plusieurs acquisitions traitées en parallèle sur un cluster plus large), deux leviers existent : augmenter les ressources du head, ou basculer de Ray Client vers une soumission de job intra-cluster (`RayJob`), qui supprime le serveur par-connexion sur le head.

#figure(
  table(
    columns: (auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Étage*], text(fill: white)[*État au régime 3 GPUs*], text(fill: white)[*Devient limitant si*]
    ),
    [GPU], [Saturé (90–100 %)], [— (maillon actif)],
    [Nombre de GPUs libres], [Dépend de l'infra, 3× L40S dans notre cas], [Priorité / quota cluster],
    [Stockage MinIO], [Au repos (~2 Mo/s, util ≈ 0 %)], [Dizaines de workers, ou pics métadonnées],
    [Head Ray (mode Client)],
    [1–2 connexions (2 CPU / 4 Gi)],
    [Soumissions parallèles → sérialiser, grossir le head, ou `RayJob`],

    [Réseau], [Non saturé], [Débit agrégé >>> actuel],
  ),
  caption: [Localisation du goulot d'étranglement par étage de la pipeline],
) <tab-bottlenecks>

Au régime actuel, accélérer la pipeline passe par *plus de GPUs*, pas par un stockage plus rapide. C'est ce qui oriente l'arbitrage de coût vers la location de GPUs (cf. @couts) plutôt que vers une refonte du stockage, le stockage on-premise gardant une large marge.


== Analyse des coûts <couts>

Le run de production Vevey fixe la donnée de base : *31 GPU-heures* de L40S pour 14'207 images en 6 labels (cf. @tab-run-vevey-scaling), soit *≈ 7,9 s de GPU par image*, un volume invariant au nombre de workers. Extrapolé au corpus cible de 300'000 images : *≈ 660 GPU-heures*.

Les deux cartes utilisées par l'institut se louent à l'heure chez les fournisseurs GPU professionnels#footnote[Prix on-demand relevés le 13 juillet 2026 sur les pages de tarification officielles : #link("https://www.runpod.io/pricing")[runpod.io/pricing], #link("https://www.scaleway.com/en/pricing/gpu/")[scaleway.com] et #link("https://www.ovhcloud.com/en/public-cloud/prices/")[ovhcloud.com], et le 14 juillet 2026 sur #link("https://www.infomaniak.com/en/hosting/public-cloud/prices")[infomaniak.com], qui facture directement en CHF. Conversions au taux du 10 juillet 2026 : 1 \$ = 0,807 CHF, 1 € = 0,922 CHF.] :

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Fournisseur*],
      text(fill: white)[*GPU*],
      text(fill: white)[*Prix horaire*],
      text(fill: white)[*≈ CHF/h*],
      text(fill: white)[*Corpus 300k (CHF)*],
    ),
    [Infomaniak (Suisse)], [L40S], [0,70 CHF/h#footnote[Flavor `nvl40s_a16_ram32` (16 vCPU, 32 Go de RAM), de 0,70 à 0,72 CHF/h selon le disque local attaché.]], [0,70], [≈ 465],
    [RunPod (Secure Cloud)], [L40S], [≈ 0,99 \$/h], [0,80], [≈ 525],
    [Scaleway], [L40S], [≈ 1,46 €/h], [1,35], [≈ 890],
    [OVHcloud], [L40S], [≈ 1,80 \$/h], [1,45], [≈ 960],
    [RunPod (Community Cloud)], [A40], [≈ 0,44 \$/h], [0,36], [≈ 350#footnote[Sur la base de ≈ 11,8 s par image (temps L40S × 1,49, le ratio mesuré à pleine charge, cf. @tab-l40s-a40-mesures), soit ≈ 980 GPU-heures pour le corpus.]],
  ),
  caption: [Coût de location cloud pour l'annotation du corpus complet (660 GPU-h L40S, 6 labels, tuile 1008, downsample 0,75)],
) <tab-couts-cloud>

Annoter une ville comme Vevey coûte donc *≈ 22 CHF* de location (31 GPU-h × 0,70 CHF/h chez Infomaniak), et le corpus complet entre 350 et 960 CHF selon l'offre. L'A40, 1,49× plus lente mais moitié moins chère à l'heure, produit exactement les mêmes détections pour un coût par image inférieur d'un tiers. Réserve : ce tarif relève du _Community Cloud_ mutualisé de RunPod, sans garantie de disponibilité. Sur le marché suisse, Infomaniak est le seul à louer la L40S à l'heure, en CHF et sans conversion, et il s'avère aussi le moins cher des fournisseurs L40S. Il n'existe en revanche pas d'A40 à l'heure en Suisse (Nine.ch ne loue qu'en dédié mensuel, SwissGPU n'aligne que des cartes gaming RTX sans A40 ni L40S).


Sur le cluster HEIG-VD, déjà acquis, le coût marginal d'un run se réduit à l'électricité : 660 GPU-h × 350 W ≈ 231 kWh, soit *≈ 67 CHF* à 0,29 CHF/kWh#footnote[Tarif suisse moyen, le tarif institutionnel de la HEIG étant probablement inférieur.]. La comparaison avec l'achat repose sur trois hypothèses supplémentaires : une L40S neuve à *≈ 8'000 CHF*#footnote[Fourchette de marché de 7'500 à 10'000 \$ en juillet 2026 : #link("https://www.thundercompute.com/blog/nvidia-l40-pricing")[thundercompute.com], 7'569 \$ chez #link("https://www.serversupply.com/GPU/GDDR6/48GB/NVIDIA/L40S_395278.htm")[serversupply.com]. Hypothèse haute retenue, à confirmer selon le canal d'achat institutionnel.], une A40 à *≈ 4'000 CHF*#footnote[Prix de marché 2026, de 4'000 à 5'000 \$ selon le canal : #link("https://gpucost.org/gpu/a40")[gpucost.org], #link("https://gpupoet.com/gpu/learn/price/may-2026/nvidia-a40")[gpupoet.com]. La carte (2020) n'est plus au catalogue neuf de NVIDIA.] et un entretien (refroidissement, part du serveur hôte, administration) à *10 % du matériel par an*.


Un service sur site évite en outre le transfert du corpus vers le cloud : ~1,2 To d'images (57 Go pour le seul jeu Vevey). Les fournisseurs comparés ne facturent pas le trafic entrant, le coût est ailleurs : environ trois heures de transfert à 1 Gbit/s soutenu (davantage sur un lien partagé), puis le stockage objet du corpus pendant la durée des runs, ≈ 0,07 \$/Go/mois chez RunPod soit ≈ 68 CHF/mois pour le corpus complet. Le cluster local, colocalisé avec le MinIO source, échappe à ces deux postes.

Cette estimation de transfert reste théorique, non mesurée. L'analyse des goulots d'étranglement (cf. @bottlenecks) couvre le régime testé, calcul et stockage colocalisés sur le cluster HEIG-VD, pas un scénario hybride où des GPUs loués liraient les images depuis MinIO par Internet. Sur ce chemin, la latence et le débit réel du lien pourraient redevenir le facteur limitant à la place du GPU, ce qui resterait à vérifier avant tout déploiement cloud en production.

Pour un *run unique* du corpus complet, la hiérarchie est sans ambiguïté :

#figure(
  table(
    columns: (auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Option*],
      text(fill: white)[*Coût (CHF)*],
      text(fill: white)[*Composition*],
    ),
    [Cluster HEIG existant], [*≈ 67*], [Électricité seule (coût marginal)],
    [Location A40 (RunPod Community)], [≈ 350], [980 GPU-h × 0,36 CHF/h],
    [Location L40S (Infomaniak)], [≈ 465], [660 GPU-h × 0,70 CHF/h],
    [Location L40S (RunPod Secure)], [≈ 525], [660 GPU-h × 0,80 CHF/h],
    [Location L40S (OVHcloud)], [≈ 960], [660 GPU-h × 1,45 CHF/h],
    [Achat d'une A40 dédiée], [≈ 4'138], [4'000 achat + 53 entretien au prorata + 85 électricité#footnote[980 GPU-h à 300 W ≈ 294 kWh, l'A40 compensant son prix horaire par des runs 1,49× plus longs.]],
    [Achat d'une L40S dédiée], [≈ 8'170], [8'000 achat + 107 entretien au prorata + 67 électricité],
  ),
  caption: [Coût d'un run unique du corpus 300k images, par option d'infrastructure],
) <tab-couts-run-unique>

En *usage récurrent*, l'achat s'amortit-il ? Hypothèse de cadence : 15 runs tous les deux ans (≈ 57 % d'occupation d'une carte unique), entretien compté au prorata, soit ≈ 107 CHF par run en plus de l'électricité.

#figure(
  lq.diagram(
    width: 13cm,
    height: 7cm,
    xlabel: [Nombre de runs de corpus],
    ylabel: [Coût cumulé (CHF)],
    legend: (position: left + top),
    lq.plot((0, 5, 10, 15, 20, 25, 30), (0, 4800, 9600, 14400, 19200, 24000, 28800), color: rgb("#1F77B4"), label: [Location L40S (OVHcloud)]),
    lq.plot((0, 5, 10, 15, 20, 25, 30), (0, 2625, 5250, 7875, 10500, 13125, 15750), color: rgb("#FF7F0E"), label: [Location L40S (RunPod)]),
    lq.plot((0, 5, 10, 15, 20, 25, 30), (0, 2325, 4650, 6975, 9300, 11625, 13950), color: rgb("#2CA02C"), label: [Location L40S (Infomaniak)]),
    lq.plot((0, 5, 10, 15, 20, 25, 30), (0, 1750, 3500, 5250, 7000, 8750, 10500), color: rgb("#D62728"), label: [Location A40 (RunPod)]),
    lq.plot((0, 5, 10, 15, 20, 25, 30), (8000, 8870, 9740, 10610, 11480, 12350, 13220), color: rgb("#9467BD"), label: [Achat d'une L40S]),
    lq.plot((0, 5, 10, 15, 20, 25, 30), (4000, 4690, 5380, 6070, 6760, 7450, 8140), color: rgb("#8C564B"), label: [Achat d'une A40]),
    lq.plot((0, 5, 10, 15, 20, 25, 30), (0, 335, 670, 1005, 1340, 1675, 2010), color: rgb("#7F7F7F"), label: [Cluster HEIG existant]),
    lq.scatter((10.2, 22.8, 27.5), (9770, 11965, 12785), mark: "x", size: 9pt, color: rgb("#9467BD")),
    lq.scatter((18.9,), (6610,), mark: "x", size: 9pt, color: rgb("#8C564B")),
  ),
  caption: [Coût cumulé selon le nombre de runs, avec les points de bascule marqués sur la droite d'achat concernée : l'achat d'une L40S (croix violettes) passe sous OVHcloud au 11#super[e] run, sous RunPod au 23#super[e] et sous Infomaniak au 28#super[e], l'achat d'une A40 (croix brune) passe sous sa propre location au 19#super[e]. Le cluster existant reste sous toutes les droites sur toute la plage.],
) <fig-couts-runs>

#figure(
  table(
    columns: (auto, auto, auto, auto, auto, auto, auto, auto),
    align: (center, right, right, right, right, right, right, right),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Runs*],
      text(fill: white)[*Cluster HEIG*],
      text(fill: white)[*A40 (RunPod)*],
      text(fill: white)[*L40S (Infomaniak)*],
      text(fill: white)[*L40S (RunPod)*],
      text(fill: white)[*L40S (OVH)*],
      text(fill: white)[*Achat A40*#footnote[4'000 CHF d'achat, plus 400 CHF/an d'entretien à la même cadence (53 CHF par run), plus 85 CHF d'électricité par run, soit 4'000 + 138 × n CHF.]],
      text(fill: white)[*Achat L40S*#footnote[8'000 CHF d'achat, plus 800 CHF/an d'entretien à la cadence de 7,5 runs par an, plus 67 CHF d'électricité par run, soit 8'000 + 174 × n CHF.]],
    ),
    [1], [67], [350], [465], [525], [960], [4'138], [8'170],
    [5], [335], [1'750], [2'330], [2'625], [4'800], [4'690], [8'870],
    [10], [670], [3'500], [4'650], [5'250], [9'600], [5'380], [9'740],
    [15], [1'005], [5'250], [6'980], [7'880], [14'400], [6'070], [10'610],
    [20], [1'340], [7'000], [9'300], [10'500], [19'200], [6'760], [11'480],
    [25], [1'675], [8'750], [11'630], [13'130], [24'000], [7'450], [12'350],
    [30], [2'010], [10'500], [13'950], [15'750], [28'800], [8'140], [13'220],
  ),
  caption: [Coût cumulé de 1 à 30 runs de corpus par option d'infrastructure, en CHF],
) <tab-couts-recurrents>

La même lecture s'exprime en volume d'images plutôt qu'en runs, une unité qui parle davantage à un donneur d'ordre : combien coûte l'annotation de N images ?

#figure(
  lq.diagram(
    width: 13cm,
    height: 7cm,
    xlabel: [Images annotées (millions)],
    ylabel: [Coût cumulé (CHF)],
    legend: (position: left + top),
    lq.plot((0, 1.5, 3, 4.5, 6, 7.5, 9), (0, 4800, 9600, 14400, 19200, 24000, 28800), color: rgb("#1F77B4"), label: [Location L40S (OVHcloud)]),
    lq.plot((0, 1.5, 3, 4.5, 6, 7.5, 9), (0, 2625, 5250, 7875, 10500, 13125, 15750), color: rgb("#FF7F0E"), label: [Location L40S (RunPod)]),
    lq.plot((0, 1.5, 3, 4.5, 6, 7.5, 9), (0, 2325, 4650, 6975, 9300, 11625, 13950), color: rgb("#2CA02C"), label: [Location L40S (Infomaniak)]),
    lq.plot((0, 1.5, 3, 4.5, 6, 7.5, 9), (0, 1750, 3500, 5250, 7000, 8750, 10500), color: rgb("#D62728"), label: [Location A40 (RunPod)]),
    lq.plot((0, 1.5, 3, 4.5, 6, 7.5, 9), (8000, 8870, 9740, 10610, 11480, 12350, 13220), color: rgb("#9467BD"), label: [Achat d'une L40S]),
    lq.plot((0, 1.5, 3, 4.5, 6, 7.5, 9), (4000, 4690, 5380, 6070, 6760, 7450, 8140), color: rgb("#8C564B"), label: [Achat d'une A40]),
    lq.plot((0, 1.5, 3, 4.5, 6, 7.5, 9), (0, 335, 670, 1005, 1340, 1675, 2010), color: rgb("#7F7F7F"), label: [Cluster HEIG existant]),
    lq.scatter((3.05, 6.84, 8.25), (9770, 11965, 12785), mark: "x", size: 9pt, color: rgb("#9467BD")),
    lq.scatter((5.67,), (6610,), mark: "x", size: 9pt, color: rgb("#8C564B")),
  ),
  caption: [Coût cumulé selon le volume total d'images annotées, à 300'000 images par run. Mêmes hypothèses et mêmes bascules que @fig-couts-runs.],
) <fig-couts-images>

L'achat d'une L40S passe sous OVHcloud dès *11 runs*, sous RunPod à *23 runs* (trois ans de service) et sous Infomaniak à *28 runs* seulement. L'achat d'une A40, deux fois moins chère pour des détections identiques, s'amortit plus vite : il passe sous la location L40S la moins chère dès *13 runs* et sous sa propre location au *19#super[e] run*, au prix de runs 1,49× plus longs. L'achat ne se justifie donc qu'au-delà d'une douzaine de runs de corpus, et toutes les options restent un ordre de grandeur au-dessus du cluster existant : le scénario le plus économique est d'exploiter les heures creuses d'une infrastructure mutualisée déjà en place, le cadre exact de ce travail.

Le coût de l'annotation automatisée ne prend son sens que rapporté à la chaîne dont elle n'est qu'un maillon. Une campagne combine deux modes d'acquisition aux coûts distincts : l'acquisition par véhicule couvre les axes routiers, une acquisition piétonne complète les zones inaccessibles (places, ruelles, chemins). Toutes les images passent ensuite par un post-traitement obligatoire : extraction des positions, égalisation radiométrique et surtout anonymisation, le floutage des plaques et des visages. Vient enfin l'annotation, pré-annotée par la pipeline puis validée par un humain.

#figure(
  table(
    columns: (auto, auto, auto),
    align: (left, right, right),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Maillon de la chaîne*],
      text(fill: white)[*Coût par ville (CHF)*],
      text(fill: white)[*Part*],
    ),
    [Acquisition (véhicule et piétonne)], [25'000 – 40'000], [≈ 58 %],
    [Post-traitement (floutage, positions)], [15'000 – 25'000], [≈ 36 %],
    [Validation humaine assistée (≈ 63 h)], [≈ 3'150], [≈ 6 %],
    [Pré-annotation SAM3 (calcul GPU)], [≈ 22], [< 0,1 %],
  ),
  caption: [La chaîne complète pour une ville de la taille de Vevey (14'207 images), de la route à l'annotation validée. Acquisition et post-traitement sont des fourchettes estimées#footnote[Fourchettes estimées sur la base de potentiels devis d'acquisition mobile (véhicule et piétonne) pour une ville de cette taille ; les parts sont calculées au milieu des fourchettes et varient de moins de deux points d'un bout à l'autre.], la validation est convertie à un taux horaire indicatif#footnote[Hypothèse de 50 CHF/h pour un annotateur, temps mesurés au @tab-score-e.].],
) <tab-chaine-complete>

L'annotation manuelle intégrale du corpus exigerait plus de 2'500 heures humaines (cf. @introduction), soit ≈ 120 heures pour une ville. L'annotation assistée réduit ce temps de 47 % (cf. @tab-score-e) : la validation retombe à ≈ 63 heures, soit ≈ 2'850 CHF économisés par ville pour ≈ 22 CHF de pré-annotation. Chaque franc de calcul GPU en économise ainsi plus de cent en temps humain, et le seul maillon de la chaîne qui se prêtait à l'automatisation est désormais son poste le moins cher.

#figure(
  table(
    columns: (auto, auto, auto),
    align: (left, right, right),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Par ville (≈ Vevey)*],
      text(fill: white)[*Annotation manuelle*],
      text(fill: white)[*Annotation assistée*],
    ),
    [Temps humain], [≈ 120 h], [≈ 63 h],
    [Coût humain (50 CHF/h)], [≈ 6'000 CHF], [≈ 3'150 CHF],
    [Pré-annotation SAM3 (GPU)], [—], [≈ 22 CHF],
    [*Total*], [*≈ 6'000 CHF*], [*≈ 3'170 CHF*],
  ),
  caption: [Annotation manuelle et annotation assistée pour une ville, au taux horaire indicatif de 50 CHF/h. La pré-annotation coûte moins de 1 % de ce qu'elle économise en validation humaine.],
) <tab-annotation-assistee>

Optimiser encore la pipeline ne changerait presque rien à ce total. La pré-annotation pèse moins de 0,1 % du coût d'une ville (@tab-chaine-complete) : la diviser par dix ne déplacerait le budget total que de quelques dizaines de francs. Les gains réels se jouent en amont, sur l'acquisition et le post-traitement, qui pèsent ensemble ≈ 94 % du coût combiné. Les 660 GPU-heures projetées plus haut pour le corpus cible de 300'000 images restent une simulation à l'échelle du projet NearAI. Ramenée à une seule ville, la chaîne complète de Vevey (14'207 images, @tab-chaine-complete) le confirme sur un cas réel : accélérer ou fiabiliser encore la pipeline améliore le confort d'exploitation, pas le budget d'une campagne d'acquisition.


== Problèmes rencontrés lors des tests <problemes-driver>

Trois incidents d'exploitation ont marqué les tests. Chacun a été diagnostiqué puis corrigé, les correctifs font partie du rendu.

Un batch échoue parfois avant d'avoir traité la moindre image, même sans aucune soumission concurrente. Au lancement, le driver se connecte au head par Ray Client, et le proxier du head crée un serveur dédié à la connexion. Ce démarrage est sujet à une course entre le fork du processus et les threads gRPC déjà actifs : quand elle est perdue, le serveur naissant meurt, la connexion est avortée et le driver s'arrête sur `ConnectionAbortedError`#footnote[`RuntimeError: Starting Ray client server failed`, détaillé dans les logs `ray_client_server_<port>.err` du head. Le même symptôme apparaît quand le plafond de connexions concurrentes du head est atteint (cf. @bottlenecks), mais ici une seule connexion suffit à le déclencher.].

L'erreur est intermittente et un simple relancement suffit. Le `backoffLimit` du Job Kubernetes la masquait en recréant le pod entier, au prix d'un redémarrage complet (image, montages, initialisation). Le driver retente désormais la connexion lui-même, jusqu'à cinq tentatives espacées de dix secondes, ce qui absorbe la course sans recréer de pod.


Pendant les longs runs, l'API devenait progressivement injoignable. Le pod a d'abord été tué par sa limite mémoire de 512 Mio (OOMKilled). La limite relevée, il plafonnait à 100 % de CPU et chaque appel à `/status` prenait 27 secondes. La cause était applicative : chaque requête créait son propre client S3 boto3, une initialisation coûteuse que le polling de la console (toutes les 4 secondes) répétait sans fin, jusqu'à ce que la création de clients consomme tout le CPU disponible.

La correction partage un unique client S3 par processus, via une fabrique commune dans `jobCore` réutilisée par l'API, les jobs et la CLI, et fixe des limites adaptées au pod (2 Gio de mémoire, 1 CPU). La console a été durcie dans la foulée : chaque requête est coupée après un délai maximal et un cycle de polling n'est jamais lancé tant que le précédent est en vol, une API lente ne fige donc plus la page.


Le cluster est mutualisé entre plusieurs équipes et rien ne réserve les GPUs à un namespace. Pendant une série de tests, un namespace tiers occupait la carte visée et les jobs restaient `Pending` sans message explicite. Trois mesures rendent cette contention gérable : les workers Ray et les jobs GPU sont épinglés par `nodeAffinity` sur les nœuds retenus, le service de segmentation interactive redescend à zéro réplique hors utilisation pour libérer sa carte, et la console distingue désormais un job qui tourne (`Running`) d'un job en file d'attente d'un GPU (`Pending`), ce qui rend l'attente visible au lieu de la laisser passer pour une panne.
