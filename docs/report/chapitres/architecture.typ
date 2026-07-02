= Architecture <architecture>

#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#import "@preview/fletcher:0.5.7" as fletcher: diagram, edge, node
#show: codly-init.with()

== Vue d'ensemble

La pipeline suit un flux linéaire en cinq étapes :

+ *Lecture* : le driver liste les objets du préfixe S3 d'entrée et distribue les clés d'image aux workers Ray.
+ *Téléchargement* : chaque worker télécharge l'image depuis MinIO et extrait les coordonnées GPS de l'EXIF.
+ *Inférence* : l'image est découpée en tuiles 512 × 512 px (après downsampling optionnel), chaque tuile est passée à SAM3 en mode _everything_.
+ *Agrégation* : les masques produits sont convertis en polygones, normalisés en pourcentage des dimensions de l'image originale, filtrés par score de confiance.
+ *Écriture* : les polygones sont sérialisés dans un fichier Parquet et envoyés sur MinIO.

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

#linebreak()

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
  caption: [Vue d'ensemble de la pipeline dans le cas d'un scénario en Batch],
) <fig-pipeline-overview>

== Infrastructure Générale

À haut niveau, la stack se découpe en trois parties qui communiquent uniquement via S3 et l'API Kubernetes, sans qu'aucune ne dépende de l'état interne d'une autre.

- *Le traitement* s'exécute sur le cluster Kubernetes : le RayCluster permanent et ses workers GPU portent l'inférence SAM3, et une API REST orchestre les jobs et expose le service aux utilisateurs.
- *L'observabilité* (Prometheus, Loki, Grafana) supervise l'ensemble : métriques GPU, logs des pods et dashboards.
- *Le stockage objet* (MinIO) est la source et le puits unique : il héberge les images d'entrée, les fichiers Parquet de sortie, le cache du modèle SAM3 et les logs de Loki.

Ce découplage permet de déployer et de faire évoluer chaque partie indépendamment, et de remplacer un composant (le backend S3, par exemple) sans toucher aux autres.

#figure(
  image("../images/Schema-Overall.png", width: 85%),
  caption: [
    Dans les grandes lignes, la stack se découpe en trois parties, traitement, observabilité et stockage.
  ],
) <Schema-Overall>


== CI/CD

Le déploiement et les mises à jour reposent sur une pipeline d'intégration continue hébergée par GitHub Actions. À chaque push sur le dépôt, le workflow enchaîne trois étapes :

+ *Validation* : exécution des tests pour confirmer que le code reste fonctionnel avant toute publication.
+ *Build* : construction des images Docker des composants concernés (API, jobs SAM3, service de segmentation).
+ *Publication* : push des images sur le registre privé GitHub Container Registry, sous le tag attendu par les manifestes Kustomize.

Le cluster tire ensuite ces images via `imagePullPolicy: Always`, ce qui propage les changements au prochain redémarrage des pods. Cette automatisation garantit qu'une modification mergée est testée puis empaquetée de façon reproductible, et supprime les builds manuels locaux, source d'images incohérentes entre développeurs.

== Infrastructure Kubernetes

La pipeline s'exécute sur le cluster `iict-rad` de la HEIG-VD (Kubernetes 1.33.9) @k8s-heig. Le cluster expose 9 GPUs répartis sur trois nœuds :

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Nœud*], text(fill: white)[*GPUs*], text(fill: white)[*Modèle*], text(fill: white)[*VRAM*]
    ),
    [`iict-suchet`], [3], [NVIDIA L40S], [46 GB],
    [`iict-k8s-node4-rad`], [2], [NVIDIA A40], [46 GB],
    [`iict-chasseron`], [4], [NVIDIA L4], [23 GB],
  ),
  caption: [GPUs disponibles sur le cluster iict-rad],
) <tab-gpus>


Le cluster suit l'architecture Kubernetes standard : un control plane gère l'état du cluster (API server, scheduler, etcd) et trois nœuds workers hébergent les pods.
Par défaut, les pods sont schedulés sur n'importe quel nœud disponible.

Deux exceptions s'appliquent dans ce projet :
- les workers Ray ciblent les nœuds L40S (noeud `iict-suchet`) et A40 (noeud `iict-k8s-node4-rad`) via `nodeAffinity`
- les pods Prometheus et Grafana sont épinglés sur `iict-suchet` via `nodeSelector` en raison de volumes Longhorn défectueux sur `iict-k8s-node4-rad`.

#figure(
  image("../images/Schema-Kubernetes.jpg", width: 85%),
  caption: [
    Les ressources K8s sont distribuables sur n'importe quel nœud ; seuls les workers Ray ciblent les nœuds GPU via nodeAffinity.
  ],
) <Schema-Kubernets>

Le nœud `iict-chasseron` est exclu pour deux raisons :
- ses L4 offrent une puissance de calcul inférieure (23 GB VRAM vs 46 GB)
- il portait un taint `node.kubernetes.io/disk-pressure` lors des tests, exposant les pods à des évictions SIGTERM sans préavis.#footnote[Le taint `disk-pressure` est appliqué automatiquement par Kubernetes quand l'usage disque dépasse le seuil `evictionHard`. Les pods sur ce nœud reçoivent un SIGTERM et sont immédiatement reschedules sur un autre nœud, interrompant toute inférence en cours sans possibilité de reprise.]

Ce taint est appliqué automatiquement par Kubernetes quand l'usage disque franchit un seuil configuré sur le nœud.

Le GPU Operator NVIDIA est installé sur le cluster. Il installe automatiquement les drivers GPU, le device plugin et DCGM Exporter sur chaque nœud. Les requêtes de ressource `nvidia.com/gpu` fonctionnent sans configuration manuelle.

== RayCluster

La pipeline repose sur deux modes d'exécution distincts, tous deux pilotés par un driver externe au cluster.

Le *Batch Job Driver* soumet une liste d'images S3 au cluster, crée un pool d'Actors GPU via `ray.remote`, distribue les clés d'image aux workers disponibles et attend les résultats avec `ray.get()`. Chaque résultat est écrit en Parquet sur MinIO.

Le *Solo Job Driver* soumet une seule image et attend la réponse de façon synchrone. Le résultat est retourné en JSON, compatible avec l'import direct dans Label Studio.

Les deux modes partagent le même *Ray Control Plane*, hébergé sur le Head Node : le *Global Control Store* (GCS) maintient l'état global du cluster (Actors actifs, tâches en attente, état des workers) et le *Raylet* tourne sur chaque nœud pour scheduler localement les tâches que le GCS lui assigne.

Chaque worker process héberge un Actor SAM3 avec son propre *Plasma Object Store* local, évitant ainsi la sérialisation et la désérialisation. Les objets volumineux (poids du modèle, données image, résultats) transitent via cet object store partagé en mémoire plutôt que par sérialisation réseau, ce qui évite les copies inutiles entre le driver et les workers.

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


#figure(
  image("../images/Schema-Ray.jpg", width: 100%),
  caption: [
    Le driver soumet les tâches au Ray Control Plane (GCS + Raylet) puis, chaque worker process héberge les Actors avec leur Plasma Object Store local, ainsi, les résultats sont écrits sur MinIO via Boto3.
  ],
) <Schema-Ray>

Le RayCluster est déclaré via la ressource CRD `ray.io/v1alpha1/RayCluster`. KubeRay crée automatiquement les pods head et workers, les Services associés (GCS [:6379], dashboard [:8265], client [:10001]) et gère leur cycle de vie.

Le driver s'exécute à l'extérieur du cluster en tant que Job Kubernetes sans GPU. Il se connecte au head via `ray.init("ray://ray-head-svc:10001")` et soumet les tâches au GCS. Les workers ne sont jamais contactés directement : Ray dispatche les tâches via le GCS.

#pagebreak()

Les workers Ray doivent s'exécuter sur des nœuds GPU. La configuration `nodeAffinity` du groupe de workers restreint le scheduling aux nœuds `iict-suchet` (L40S) et `iict-k8s-node4-rad` (A40) :

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: kubernetes.io/hostname
            operator: In
            values:
              - iict-suchet
              - iict-k8s-node4-rad
```

Les workers Ray s'exécutent dans des pods séparés et n'héritent pas des variables d'environnement du driver. Les credentials MinIO (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT_URL`) et le token HuggingFace (`HF_TOKEN`) doivent être déclarés explicitement dans le `workerGroupSpec` via des références à un Secret Kubernetes :

```yaml
env:
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: minio-secret
        key: access-key
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-secret
        key: token
```

Sans cette configuration, chaque appel S3 depuis un Actor échoue avec `NoCredentialsError` et le premier démarrage du worker tente de télécharger les poids SAM3 sans authentification.

== Cache du modèle SAM3

Les poids du modèle SAM3 représentent 3,3 GB téléchargés depuis HuggingFace Hub. Sans cache persistant, chaque recréation de pod lance un nouveau téléchargement, ajoutant plusieurs minutes de latence avant que le worker soit opérationnel.

Pour cela il faut ajouter un `StorageClass` et un `PersistantVolumClaim`.

Un PVC Longhorn de 10 Gi est partagé entre tous les workers Ray. HuggingFace Hub vérifie ce répertoire avant tout téléchargement. Si les poids sont présents, il les charge directement sans accès réseau. Le PVC survit aux redéploiements du RayCluster car les poids ne sont téléchargés qu'une seule fois.

Le mode `ReadWriteMany` est retenu car les workers s'exécutent sur deux nœuds distincts (`iict-suchet` et `iict-k8s-node4-rad`). Un PVC `ReadWriteOnce` ne peut être monté que par un seul nœud à la fois, ce qui bloquerait les workers sur le second nœud.

Longhorn implémente le `ReadWriteMany` via un share-manager NFS. Chaque nœud qui monte le volume agit comme client NFS et a besoin de `mount.nfs`, fourni par le paquet `nfs-common`. Ce paquet doit être installé sur tous les noeuds sinon tout pod ordonnancé dessus échourait au montage avec `FailedMount` : "bad option".

Déclarer une StorageClass RWX ne suffit donc pas car elle peut supposer implicitement que tous les nœuds candidats sont homogènes. Un pod sans affinité tombant sur un nœud sans `nfs-common` reste bloqué. Une verifications de la dépendance d'infrastructure ßßßdoit être vérifiée avant de compter sur le RWX.

== Stratégie de tuilage

L'hardware est une contrainte pour les performances de notre pipeline, les deux autres vecteurs qui sont envisageables pour gagner en performances est le software (Choix du modèle, optimisation du code) ou bien simplement les données brutes a traitées. Dans notre cas, nous avons des images de très haute résolution (8192 × 4096 px) qui devront être traité par SAM3 qui, pour rappel, à comme taille maximale de traitement par tuilles de 1024px par 1024px.

Les conséquances sont les suivantes :
- > 1024px : l'image est downsamplée par SAM3 et nous avons une perte d'information.
- < 1024px : l'image est upscalée par SAM3 et il n'y à aucun gain d'information.
- \= 1024 px : Natif, donc pas de changement
Il faut donc jouer avec la taille des tuilles et ses nombres.

Nous devons donc définir par défaut des valeurs des nombre de Tuiles et leurs dimmensions à travers de variables pour l'API.

#figure(
  image("../images/tillingExplanation.jpg", width: 100%),
  caption: [
    SAM3 comme tout modèée à base de ViT, attend une entrée carrée de taille fixe. Un objet à cheval sur une bordure de tuile se retrouve grâce au striding, au moins sur une tuile voisine.
  ],
) <Tilling-Explanation>


== Format de sortie Parquet

Chaque image produit un fichier Parquet nommé `<acquisition_id>/<image_stem>.parquet`, écrit sur le préfixe S3 de sortie. Le schéma est le suivant :

#figure(
  table(
    columns: (auto, auto, 1fr),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(text(fill: white)[*Colonne*], text(fill: white)[*Type*], text(fill: white)[*Description*]),
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
  caption: [Schéma Parquet de sortie de la pipeline],
) <tab-parquet-schema>

La compression Snappy est appliquée. Les fichiers sont interrogeables directement depuis DuckDB ou PyArrow sans étape de chargement en base de données.

== Intégration Label Studio

=== Pré-annotations

Label Studio est connecté à MinIO comme _source storage_ S3. Les URLs `s3://nearai/...` sont converties en URLs HTTP temporaires pré-signées, servies directement du stockage au navigateur sans proxy.

L'interface de labeling XML définit deux classes :

```xml
<View>
  <Image name="image" value="$image"/>
  <PolygonLabels name="label" toName="image">
    <Label value="sign" background="#FF0000"/>
    <Label value="road_marking" background="#FFFF00"/>
    <!-- <Label value="value" background="#XXXXXX"/>  Add new pre-annotation -->
  </PolygonLabels>
</View>
```

Les pré-annotations importées doivent utiliser `from_name: "label"` et `to_name: "image"` pour correspondre à cette interface. Une divergence de noms provoque l'affichage des polygones sans label (gris).

== Intégration Near Label

=== Récupération des données

=== Conversion des données Parquet --> JSON

=== Segmentation manuelle

Concernant la *segmentation à la demande*, un utilisateur peut simplement passer à l'API l'url ainsi que les items à re-passer en inférance :
```JSON
{
  "url": "data/acquisitions/20241003-Nyon/01_images/S003/20241003-Nyon_S003_ladybug5plus_000001.jpg",
  "items": [
    { "point": [4637, 2675], "label": "manhole" },
    { "point": [1200, 800],  "label": "road_marking" }
  ]
}
```

L'endpoit `/segment` lance alors une opération sur le pod `sam3-segment-*` et retourne en JSON le résulat des recherches demandées.

Afin d'avoir une attente régulière sur le service, le choix de laisser un pod prêt à agir à été choisi.

Le réveil aurait pu être automatisé avec KEDA et son extension HTTP, qui réveille un service dès qu'une requête arrive. Cette piste a été écartée pour trois raisons.

Le problème dans notre cas, KEDA s'installe à l'échelle du cluster et requiert des droits d'administrateur, hors de portée du namespace actuel : il faudrait passer par l'admin de l'infrastructure.

Ensuite, l'extension HTTP insère un _interceptor_ devant le service pour retenir la requête le temps que le pod démarre, ajoutant une pièce supplémentaire dans le chemin réseau.

Enfin, et surtout, KEDA n'élimine pas le démarrage à froid (le chargement du modèle en mémoire GPU, de l'ordre de 20 à 30 secondes) : il ne fait que le déclencher automatiquement.

Pour un usage ponctuel et séquentiel d'un seul annotateur et une image à la fois, le pilotage manuel par `/segment/up` et `/segment/down` offre la même expérience réelle, un unique démarrage à froid en début de session, sans dépendance d'infrastructure ni composant réseau additionnel.


Le pod charge le modèle via Ultralytics, qui lit un fichier `sam3.pt` (format PyTorch) contenant les poids de SAM3. Le détail de cette intégration est traité au chapitre implémentation.

#pagebreak()
== Observabilité

La stack d'observabilité collecte deux flux distincts : les métriques GPU et Ray via Prometheus, et les logs des pods via Alloy et Loki. Grafana agrège les deux sources dans un dashboard unique.

#figure(
  image("../images/Schema-Observability.png", width: 80%),
  caption: [
    Prometheus récolte les métriques tandis que Loki s'occupe des logs afin d'alimenter Grafana.
  ],
) <Schema-Observability>

#linebreak()


Prometheus scrape deux sources de métriques toutes les 15 secondes depuis 2 sources :

*DCGM Exporter* : 4 métriques GPU par nœud (`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP`). Le scraping utilise `dns_sd_configs` sur le Service headless DCGM, ce qui résout l'IP de chaque pod DaemonSet individuellement et évite le round-robin du ClusterIP.

*RayCluster* : métriques Ray exposées par le head node (`ray_running_jobs`, `ray_gcs_actors_count`).

DCGM tourne via un DeamonSet sur chaque node. Via un endpoint `/metrics` sur le port [9400] et le DNS de K8s, les données peuvent être scrapées individuellment, ce qui permet de garder le `hostname` pour chaque métrique.

Alloy est déployé en Deployment unique dans le namespace `dani`. Il lit les logs de tous les pods via l'API Kubernetes (`loki.source.kubernetes`) sans monter le système de fichiers du nœud hôte et les pousse vers Loki en continu.

#figure(
  ```yaml
  discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app"]
          target_label  = "app"
        }
      }
  ```,
  caption: [Chaque ligne de log est indexée avec les labels `pod`, `container`, `namespace` et `app`.],
)


#linebreak()

Loki stocke l'index (TSDB) et les chunks de logs dans MinIO sous le préfixe `nearai/dani/loki`. Il est ainsi _stateless_ : tout l'état réside dans le bucket S3, et le pod peut être redémarré sans perte de données.

Les logs du driver SAM3 contiennent les résultats de chaque run au format texte.



Grafana intéroge les résultats interroge via LogQL avec `regexp` et `unwrap` pour en extraire des métriques comme le nombre d'images traitées, détections, et temps moyen par image.

#pagebreak()
== API

Une API REST expose la pipeline aux utilisateurs et aux systèmes externes. Elle permet de soumettre des jobs batch ou on-demand, de consulter leur état et d'importer automatiquement les résultats dans NearLabel ou sans accès direct au cluster Kubernetes.

#figure(
  image("../images/API.png", width: 100%),
  caption: [
    L'API permet de créer les pods, lire leurs status via les librairires K8s et de retourner le résultats post traitement.
  ],
) <Schema-Observability>

#linebreak()

L'API tourne comme un `Deployment` dans le namespace `dani`, avec un `ServiceAccount` disposant des droits `create/get/list` sur les `Jobs` Kubernetes. Elle soumet les jobs en créant des ressources `Job` via le SDK Kubernetes Python, ce qui découple l'API de l'état interne du RayCluster.

#figure(
  table(
    columns: (1fr, 1.5fr, 2fr),
    align: (left, left, left),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(text(fill: white)[*Endpoint*], text(fill: white)[*Paramètres*], text(fill: white)[*Description*]),
    [`GET /`],
    [#set par(justify: false); #text(
        size: 0.85em,
      )[`-`]],
    [Retourne `NearApi vX is running`.],

    [`POST /jobs/batch`],
    [#set par(justify: false); #text(
        size: 0.85em,
      )[`s3_uri`, `s3_output_uri`,\ `labels`, `num_workers`,\ `batch_size`, `tile_size`, `tile_stride`]],
    [Soumet un lot d'images S3. Retourne `{job_name, status}`.],

    [`POST /jobs/solo`],
    [#set par(justify: false); #text(size: 0.85em)[`image_uri`, `labels`,\ `tile_size`, `tile_stride`]],
    [Soumet une image unique, poll le statut du Job K8s et retourne le résultat au format JSON Label Studio.],

    [`GET /jobs`], [-], [Liste les Jobs `sam3-batch-*` et `sam3-solo-*` du namespace avec leur statut.],
    [`GET /jobs/{name}`],
    [#text(size: 0.85em)[`name`]],
    [Retourne le statut d'un Job (`Pending`, `Running`, `Succeeded`, `Failed`).],

    [`POST /segment/`],
    [#text(size: 0.85em)[`image_uri`, `items` (position + label)]],
    [Utilise la fonction de SAM3 pour retrouver un item selon son label `label` à la position `position`.],

    [`POST /import/\ {acquisition_id}`],
    [#text(size: 0.85em)[`acquisition_id`]],
    [Lit les Parquets depuis MinIO, les convertit et les importe via l'API REST Label Studio.],
  ),
  caption: [Endpoints de l'API REST],
) <tab-api-endpoints>

Les paramètres d'un traitement (image source, labels, nombre de workers, tuilage) changent à chaque requête. Un manifeste YAML statique ne peut pas les porter ; l'API construit donc chaque `V1Job` dynamiquement à partir du corps de la requête. Le Job hérite de `imagePullPolicy: Always` (toujours tirer la dernière image `:staging`), `restartPolicy: Never`, `runtimeClassName: nvidia` et des ressources `nvidia.com/gpu` pour les pods à GPU, et `ttlSecondsAfterFinished: 3600` pour l'auto-nettoyage.

Ce modèle découple l'API de l'état du RayCluster : un Job batch n'est qu'un driver éphémère qui se connecte au cluster permanent, tandis qu'un Job solo embarque son propre GPU. L'API n'a pas à connaître la topologie Ray, elle ne fait que soumettre des Jobs.

L'API tourne sous le ServiceAccount `sam3-api`, lié par un `RoleBinding` à un `Role` au moindre privilège : `create/get/list/watch/delete` sur les `jobs`, `get` sur les `pods` et `pods/log`, et `get/patch` sur les `deployments/scale` pour le réveil du service de segmentation.

Une subtilité du modèle RBAC a coûté du temps : `jobs/status` est une sous-ressource distincte de `jobs`. Lire le statut d'un Job via `read_namespaced_job_status` exige une permission séparée et renvoie un `403` sans elle. La solution lit la ressource `jobs` complète avec `read_namespaced_job`, déjà couverte par le verbe `get`, et extrait le statut du résultat.


Le Job solo écrit son résultat (`results/<job>.json`) sur S3, et l'endpoint `get_result` relit cet objet. Le stockage S3 est durable et indépendant du TTL des Jobs : le résultat survit à la suppression automatique du pod après une heure.

Deux alternatives ont été écartées. Les logs du pod sont éphémères (effacés avec le pod) et, sur `kubernetes-client` 36.x, leur lecture souffre d'un bug d'encodage. Une base SQLite est inadaptée à un accès distribué et à un montage NFS partagé. S3 est déjà la source des données et le puits des prédictions : l'y conserver les résultats évite toute pièce supplémentaire.

== Segmentation interactive

...

=== Prompt visuel (PVS) vs prompt concept (PCS)

SAM3 accepte deux familles de prompts.

Le *prompt visuel* (PVS) répond à la question OÙ : il produit un masque class-agnostic à l'endroit désigné, sans nommer l'objet.

Le *prompt concept* (PCS) répond à QUOI: il trouve toutes les instances du concept fourni dans l'image.

La pipeline batch et le job solo utilisent le PCS, on leur passe des labels texte (`sign`, `road_marking`) et SAM3 détecte chaque occurrence. L'endpoint interactif (segmentation à la volée), lui, utilise le PVS, l'annotateur clique un point, SAM3 retourne le contour de l'objet sous le curseur.

Le label n'oriente pas la détection ici car il est fourni en entrée et sert uniquement à étiqueter le masque retourné.

La *segmentation à la volée* impose une latence faible. Lancer un Job par requête est exclu car chaque clic paierait le démarrage à froid. Le service de segmentation est donc un Deployment qui charge SAM3 une seule fois, au démarrage du pod avec FastAPI lifespan et garde le modèle chaud en VRAM pour toute la session.

Mais, garder ce pod actif en permanence monopoliserait un GPU sur les ceux disponibles, même hors session d'annotation. Le Deployment reste donc à zéro réplica par défaut, et l'API le pilote : `POST /segment/up` le scale à 1 et `POST /segment/down` le scale à 0 et libère le GPU.

Le détail de ce mécanisme et le choix d'écarter KEDA sont traités au chapitre implémentation.

L'endpoint interactif s'appuie sur l'API *Ultralytics*, qui expose la prédiction par prompt visuel en un seul appel (`model.predict(points=, labels=)`). Le service n'utilise que le prompt par point, l'annotateur clique, SAM3 renvoie le masque de l'objet sous le curseur. Cette API évite le pipeline complet du mode batch (tuilage, collate, postprocessor), inutile pour une inférence ponctuelle ; l'image en est plus légère. Le service n'a pas d'authentification propre : il est exposé via l'Ingress et protégé au niveau du cluster.


== Variables d'environnement
Toutes les valeurs interchangeables du projet sont définies dans un fichier `.env` unique situé à la racine du projet. L'API les lit via `os.getenv`, avec une valeur par défaut raisonnable pour chacune. En développement local, `load_dotenv()` charge ce `.env`. Un `.env.example` versionné sert de modèle et ne contient aucun secret. En production, ces variables sont injectées par le Deployment Kubernetes.

#figure(
  table(
    columns: (auto, 1fr),
    align: (left, left),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(text(fill: white)[*Variable*], text(fill: white)[*Rôle*]),
    [`NAMESPACE`], [Namespace où l'API crée les Jobs et scale le service de segmentation],
    [`S3_ENDPOINT_URL`], [Endpoint du stockage objet MinIO],
    [`BUCKET`], [Bucket par défaut pour la lecture des images et l'écriture des résultats],
    [`BATCH_IMAGE`], [Image du driver batch (identique aux workers Ray)],
    [`SOLO_IMAGE`], [Image du Job solo],
    [`SEGMENT_URL`], [URL interne du service de segmentation interactive],
    [`SEGMENT_DEPLOYMENT`], [Nom du Deployment scalé par `/segment/up` et `/segment/down`],
    [`PORT`], [Port HTTP exposé par l'API],
    [`V4_ADDRESS`], [Adresse d'écoute du serveur],
  ),
  caption: [Variables d'environnement de l'API],
) <tab-env-vars>

Ces variables configurent le comportement de l'API, elles ne sont pas sensibles et peuvent figurer en clair. Les credentials MinIO (`AWS_ACCESS_KEY`, `AWS_SECRET_ACCESS_KEY`) et le token HuggingFace (`HF_TOKEN`) sont au contraire des secrets k8s, ils ne sont jamais inscrits dans l'image ni dans le `.env.example`, et proviennent de Secrets Kubernetes dédiés (cf. @arch-secrets).

== Gestion des secrets <arch-secrets>

Trois secrets alimentent la pipeline : les credentials MinIO (`minio-secret`), le token HuggingFace (`hf-secret`) et les identifiants du registre privé (`ghcr-secret`). Aucun n'est inscrit dans une image ni dans un fichier en clair du dépôt. Ils existent comme Secrets Kubernetes dans le namespace `dani`, et les pods les consomment au runtime via `secretKeyRef`.

=== SOPS

Créer ces Secrets uniquement à la main (`kubectl create secret`) les laisse hors du contrôle de version, rien ne documente leur structure, et un secret perdu doit être reconstitué de mémoire. SOPS résout ce problème en chiffrant les valeurs avant de les commiter.

Le fichier `.sops.yaml` déclare une règle qui chiffre, via une clé publique age, les seules valeurs sous `stringData` (`encrypted_regex`). Le reste du manifeste reste en clair, ce qui préserve des diffs Git lisibles. La clé privée `age` vit hors du dépôt (`~/.config/sops/age/keys.txt`) ; elle seule permet le déchiffrement.

Un secret chiffré ressemble à ceci, sûr à versionner :

```yaml
stringData:
    access_key: ENC[AES256_GCM,data:DjC2SqT5...,type:str]
    secret_key: ENC[AES256_GCM,data:qduNJEEj...,type:str]
```

Le déploiement déchiffre à la volée vers `kubectl`, sans jamais écrire le secret en clair sur le disque :

```sh
sops -d deploy/secrets/minio-secret.enc.yaml | kubectl apply -f -
```

Cette approche reste volontairement simple car le déchiffrement est manuel au moment du déploiement. Un déchiffrement automatique en GitOps (Flux ou ArgoCD avec ksops) exigerait d'installer des composants à l'échelle du cluster, hors de portée du namespace dans notre cas.

=== Kubernetes API python

Une fois le Secret présent dans le cluster, l'API ne manipule jamais sa valeur : elle déclare seulement, dans le `V1Job` qu'elle construit, que telle variable d'environnement doit être tirée de telle clé d'un Secret. Le `kubelet` résout la référence au démarrage du pod.

```python
from kubernetes import client

env = [
    client.V1EnvVar(
        name="AWS_ACCESS_KEY",
        value_from=client.V1EnvVarSource(
            secret_key_ref=client.V1SecretKeySelector(
                name="minio-secret",
                key="access_key",
            )
        ),
    )
]
```
