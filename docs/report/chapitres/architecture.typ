= Architecture <architecture>

#import "@preview/fletcher:0.5.7" as fletcher: diagram, edge, node

== Vue d'ensemble

Le pipeline suit un flux linéaire en cinq étapes :

+ *Lecture* : le driver liste les objets du préfixe S3 d'entrée et distribue les clés d'image aux workers Ray.
+ *Téléchargement* : chaque worker télécharge l'image depuis MinIO et extrait les coordonnées GPS de l'EXIF.
+ *Inférence* : l'image est découpée en tuiles 512 × 512 px (après downsampling optionnel), chaque tuile est passée à SAM3 en mode _everything_.
+ *Agrégation* : les masques produits sont convertis en polygones, normalisés en pourcentage des dimensions de l'image originale, filtrés par score de confiance.
+ *Écriture* : les polygones sont sérialisés dans un fichier Parquet et envoyés sur MinIO.

// Palette moderne
#let col-blue = rgb("#2563EB")
#let col-violet = rgb("#7C3AED")
#let col-cyan = rgb("#0891B2")
#let col-green = rgb("#059669")
#let col-orange = rgb("#EA580C")
#let col-red = rgb("#DC2626")
#let col-indigo = rgb("#4F46E5")
#let col-purple = rgb("#9333EA")
#let col-teal = rgb("#0F766E")
#let col-slate = rgb("#334155")

#let wt(it) = text(fill: white, it)
#let e-stroke = 1.2pt + rgb("#94A3B8")

#figure(
  diagram(
    node-stroke: none,
    edge-stroke: e-stroke,
    spacing: (2.5em, 2em),
    node((0, 0), wt[*MinIO*\ #text(size: 0.78em)[Images S3]], corner-radius: 8pt, fill: col-blue, name: <s3in>),
    node((1, 0), wt[*Driver*], corner-radius: 8pt, fill: col-violet, name: <driver>),
    node((2, 0), wt[*Workers*\ #text(size: 0.78em)[SAM3 × N]], corner-radius: 8pt, fill: col-cyan, name: <workers>),
    node((3, 0), wt[*MinIO*\ #text(size: 0.78em)[Parquet S3]], corner-radius: 8pt, fill: col-blue, name: <s3out>),
    node((4, 0), wt[*Label*\ *Studio*], corner-radius: 8pt, fill: col-green, name: <ls>),
    edge(<s3in>, <driver>, "->"),
    edge(<driver>, <workers>, "->"),
    edge(<workers>, <s3out>, "->"),
    edge(<s3out>, <ls>, "->"),
  ),
  caption: [Vue d'ensemble du pipeline],
) <fig-pipeline-overview>

== Infrastructure Kubernetes

Le pipeline s'exécute sur le cluster `iict-rad` de la HEIG-VD (Kubernetes 1.33.9). Le cluster expose 9 GPUs répartis sur trois nœuds :

#figure(
  table(
    columns: (auto, auto, auto, auto),
    [*Nœud*], [*GPUs*], [*Modèle*], [*VRAM*],
    [`iict-suchet`], [3], [NVIDIA L40S], [46 GB],
    [`iict-k8s-node4-rad`], [2], [NVIDIA A40], [46 GB],
    [`iict-chasseron`], [4], [NVIDIA L4], [23 GB],
  ),
  caption: [GPUs disponibles sur le cluster iict-rad],
) <tab-gpus>


#figure(
  image("../images/Schema-Kubernetes.png", width: 80%),
  caption: [
    Les différentes ressources k8s sont distribuables sur n'importe quel noeud, à l'exception des workers qui visent des noeuds avec GPU.
  ],
) <Schema-Kubernets>
Les workers Ray ciblent exclusivement les nœuds L40S et A40 via `nodeAffinity`. Le nœud `iict-chasseron` est exclu pour deux raisons :
- ses L4 offrent une puissance de calcul inférieure (23 GB VRAM vs 46 GB)
- et il portait un taint `node.kubernetes.io/disk-pressure` lors des tests.

Ce taint, appliqué automatiquement par Kubernetes quand l'usage disque franchit un seuil, expose les pods à des évictions SIGTERM sans préavis.

Le GPU Operator NVIDIA est installé sur le cluster. Il installe automatiquement les drivers GPU, le device plugin et DCGM Exporter sur chaque nœud. Les requêtes de ressource `nvidia.com/gpu` fonctionnent sans configuration manuelle.

== RayCluster

#figure(
  diagram(
    node-stroke: none,
    edge-stroke: e-stroke,
    spacing: (3em, 2.5em),
    node((1, 0), wt[*Driver*\ #text(size: 0.78em)[externe]], corner-radius: 8pt, fill: col-violet, name: <rdriver>),
    node(
      (1, 1),
      wt[*Head Node*\ #text(size: 0.78em)[GCS · Scheduler · Dashboard]],
      corner-radius: 8pt,
      fill: col-blue,
      name: <head>,
    ),
    node((0, 2), wt[*L40S × 3*\ #text(size: 0.78em)[iict-suchet]], corner-radius: 8pt, fill: col-cyan, name: <l40s>),
    node((1, 2), wt[*A40 × 2*\ #text(size: 0.78em)[iict-node4]], corner-radius: 8pt, fill: col-cyan, name: <a40>),
    node((2, 2), wt[*L4 × 4*\ #text(size: 0.78em)[iict-chasseron]], corner-radius: 8pt, fill: col-teal, name: <l4>),
    edge(<rdriver>, <head>, "->", [`ray.init(:10001)`]),
    edge(<head>, <l40s>, "<->"),
    edge(<head>, <a40>, "<->"),
    edge(<head>, <l4>, "<->"),
  ),
  caption: [Architecture du RayCluster sur iict-rad],
) <fig-raycluster>

=== Injection des credentials

== Cache du modèle SAM3

== Stratégie de tuilage


== Format de sortie Parquet

Chaque image produit un fichier Parquet nommé `<acquisition_id>/<image_stem>.parquet`, écrit sur le préfixe S3 de sortie. Le schéma est le suivant :

#figure(
  table(
    columns: (auto, auto, auto),
    [*Colonne*], [*Type*], [*Description*],
    [`image_key`], [`string`], [Chemin S3 complet de l'image source],
    [`acquisition_id`], [`string`], [Dossier parent (identifiant de l'acquisition)],
    [`label`], [`string`], [`sign` ou `road_marking`],
    [`score`], [`float32`], [Score de confiance SAM3 (0–1)],
    [`points`], [`string`], [Polygone JSON encodé, en % des dimensions de l'image],
    [`original_width`], [`int32`], [Largeur de l'image source en pixels],
    [`original_height`], [`int32`], [Hauteur de l'image source en pixels],
    [`latitude`], [`float64`], [Latitude GPS en degrés décimaux (null si absent)],
    [`longitude`], [`float64`], [Longitude GPS en degrés décimaux (null si absent)],
  ),
  caption: [Schéma Parquet de sortie du pipeline],
) <tab-parquet-schema>

La compression Snappy est appliquée. Les fichiers sont interrogeables directement depuis DuckDB ou PyArrow sans étape de chargement en base de données.

== Intégration Label Studio

Label Studio est connecté à MinIO comme _source storage_ S3. Les URLs `s3://nearai/...` sont converties en URLs HTTP temporaires pré-signées, servies directement du stockage au navigateur sans proxy.

L'interface de labeling XML définit deux classes :

```xml
<View>
  <Image name="image" value="$image"/>
  <PolygonLabels name="label" toName="image">
    <Label value="sign" background="#FF0000"/>
    <Label value="road_marking" background="#FFFF00"/>
  </PolygonLabels>
</View>
```

Les pré-annotations importées doivent utiliser `from_name: "label"` et `to_name: "image"` pour correspondre à cette interface. Une divergence de noms provoque l'affichage des polygones sans label (gris).

== Observabilité

#figure(
  image("../images/Schema-Observability.png", width: 80%),
  caption: [
    Prometheus récolte les métriques tandis que Loki s'occupe des logs afin d'allimenter Grafana.
  ],
) <Schema-Observability>
