= Architecture <architecture>

== Vue d'ensemble

Le pipeline suit un flux linéaire en cinq étapes :

+ *Lecture* : le driver liste les objets du préfixe S3 d'entrée et distribue les clés d'image aux workers Ray.
+ *Téléchargement* : chaque worker télécharge l'image depuis MinIO et extrait les coordonnées GPS de l'EXIF.
+ *Inférence* : l'image est découpée en tuiles 512 × 512 px (après downsampling optionnel), chaque tuile est passée à SAM3 en mode _everything_.
+ *Agrégation* : les masques produits sont convertis en polygones, normalisés en pourcentage des dimensions de l'image originale, filtrés par score de confiance.
+ *Écriture* : les polygones sont sérialisés dans un fichier Parquet et envoyés sur MinIO.

== Infrastructure Kubernetes

Le pipeline s'exécute sur le cluster `iict-rad` de la HEIG-VD (Kubernetes 1.32.5). Le cluster expose 9 GPUs répartis sur trois nœuds :

#figure(
  table(
    columns: (auto, auto, auto, auto),
    [*Nœud*], [*GPUs*], [*Modèle*], [*VRAM*],
    [`iict-suchet`], [3], [NVIDIA L40S], [46 GB],
    [`iict-k8s-node4-rad`], [2], [NVIDIA A40], [46 GB],
    [`iict-chasseron`], [4], [NVIDIA L4], [23 GB],
  ),
  caption: [GPUs disponibles sur le cluster iict-rad]
) <tab-gpus>

Les workers Ray ciblent exclusivement les nœuds L40S et A40 via `nodeAffinity`. Le nœud `iict-chasseron` est exclu pour deux raisons : ses L4 offrent une puissance de calcul inférieure (23 GB VRAM vs 46 GB), et il portait un taint `node.kubernetes.io/disk-pressure` lors des tests. Ce taint, appliqué automatiquement par Kubernetes quand l'usage disque franchit un seuil, expose les pods à des évictions SIGTERM sans préavis.

Le GPU Operator NVIDIA est installé sur le cluster (confirmé via le wiki IICT). Il installe automatiquement les drivers GPU, le device plugin et DCGM Exporter sur chaque nœud. Les requêtes de ressource `nvidia.com/gpu` fonctionnent sans configuration manuelle.

== RayCluster

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
  caption: [Schéma Parquet de sortie du pipeline]
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
