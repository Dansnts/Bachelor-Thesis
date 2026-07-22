= Architecture <architecture>

#import "@preview/codly:1.3.0": *
#import "@preview/codly-languages:0.1.1": *
#import "@preview/fletcher:0.5.7" as fletcher: diagram, edge, node
#show: codly-init.with()

== Vue d'ensemble

La pipeline suit un flux linéaire en cinq étapes :

+ *Lecture* : le driver liste les objets sous le préfixe S3 d'entrée et distribue les clés d'image aux workers Ray.
+ *Téléchargement* : chaque worker télécharge l'image depuis MinIO et récupère ses coordonnées GPS (fichier de trajectoire, EXIF en secours).
+ *Inférence* : l'image est découpée en tuiles de 1008 × 1008 px par défaut (après un downsampling optionnel), chaque tuile est passée à SAM3 en mode _prompt_, une requête `FindQuery` par label du vocabulaire (cf. @etat-de-lart).
+ *Agrégation* : les masques produits sont convertis en polygones et normalisés en pourcentage des dimensions de l'image originale, puis filtrés par score de confiance.
+ *Écriture* : les polygones sont sérialisés dans un fichier Parquet et envoyés sur le bucket.

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
    node((0, 0), wt[*Bucket S3*\ #text(size: 0.78em)[Images]], corner-radius: 8pt, fill: col-blue, name: <s3in>),
    node((1, 0), wt[*Driver*], corner-radius: 8pt, fill: col-violet, name: <driver>),
    node((2, 0), wt[*Workers*\ #text(size: 0.78em)[SAM3 avec N workers]], corner-radius: 8pt, fill: col-cyan, name: <workers>),
    node((3, 0), wt[*Boto 3*\ #text(size: 0.78em)[Upload fichiers Parquet]], corner-radius: 8pt, fill: col-green, name: <s3out>),
    node((4, 0), wt[*Bucket S3*\ #text(size: 0.78em)[Images + Prédictions]], corner-radius: 8pt, fill: col-blue, name: <ls>),
    edge(<s3in>, <driver>, "->"),
    edge(<driver>, <workers>, "->"),
    edge(<workers>, <s3out>, "->"),
    edge(<s3out>, <ls>, "->"),
  ),
  caption: [Vue d'ensemble de la pipeline dans le cas d'un scénario en Batch],
) <fig-pipeline-overview>

#pagebreak()

== Infrastructure Générale

À haut niveau, la stack se découpe en trois parties qui communiquent uniquement via S3 et l'API Kubernetes, sans qu'aucune ne dépende de l'état interne d'une autre.

- *Le traitement* s'exécute sur le cluster Kubernetes : le RayCluster permanent et ses workers GPU portent l'inférence SAM3, et une API REST orchestre les jobs et expose le service aux utilisateurs.
- *L'observabilité* (Prometheus, Loki, Grafana) supervise l'ensemble : métriques GPU, logs des pods et dashboards.
- *Le stockage objet* (MinIO) est la source et le puits unique : il héberge les images d'entrée, les fichiers Parquet de sortie, le cache du modèle SAM3 et les logs de Loki.

Ce découplage permet de déployer et de faire évoluer chaque partie indépendamment, et de remplacer un composant (le backend S3, par exemple) sans toucher aux autres.

#figure(
  image("../images/Schema-Overall.png", width: 95%),
  caption: [
    Dans les grandes lignes, la stack se découpe en trois parties, traitement, observabilité et stockage.
  ],
) <Schema-Overall>

#pagebreak()

== CI/CD

Le déploiement et les mises à jour reposent sur une pipeline d'intégration continue hébergée par GitHub Actions. À chaque push sur le dépôt, le workflow enchaîne trois étapes :

+ *Validation* : exécution des tests pour confirmer que le code reste fonctionnel avant toute publication.
+ *Build* : construction des images Docker des composants concernés (API, jobs SAM3, service de segmentation).
+ *Publication* : push des images sur le registre privé GitHub Container Registry, sous le tag attendu par les manifestes Kustomize.

Le cluster tire ensuite ces images via `imagePullPolicy: Always`, ce qui propage les changements au prochain redémarrage des pods. Cette automatisation garantit qu'une modification mergée est testée puis empaquetée de façon reproductible, et supprime les builds manuels locaux, source d'images incohérentes entre développeurs.

#figure(
  image("../images/Schema-Pipeline.png", width: 100%),
  caption: [
    Chaque commit sur la branche master lance le workflow. Les tests et les builds d'images s'exécutent en parallèle.
  ],
) <Schema-Pipeline>

#pagebreak()


== Infrastructure Kubernetes

La pipeline s'exécute sur le cluster `iict-rad` de la HEIG-VD (Kubernetes 1.33.9) @k8s-heig. Le cluster expose 9 GPUs répartis sur trois nœuds :

#figure(
  table(
    columns: (auto, auto, auto, auto),
    fill: (_, row) => if row == 0 { col-blue } else if calc.odd(row) { rgb("#F1F5F9") } else { white },
    table.header(
      text(fill: white)[*Nœud*], text(fill: white)[*GPUs*], text(fill: white)[*Modèle*], text(fill: white)[*VRAM*]
    ),
    [`iict-suchet`], [3], [NVIDIA L40S], [48 Go],
    [`iict-k8s-node4-rad`], [2], [NVIDIA A40], [48 Go],
    [`iict-chasseron`], [4], [NVIDIA L4], [24 Go],
  ),
  caption: [GPUs disponibles sur le cluster iict-rad],
) <tab-gpus>


Le cluster suit l'architecture Kubernetes standard : un control plane gère l'état du cluster (API server, scheduler, etcd) et trois nœuds workers hébergent les pods.
Par défaut, les pods sont schedulés sur n'importe quel nœud disponible.

Deux exceptions s'appliquent dans ce projet :
- les workers Ray ciblent les nœuds L40S (nœud `iict-suchet`) et A40 (nœud `iict-k8s-node4-rad`) via `nodeAffinity`
- les pods Prometheus et Grafana sont épinglés sur `iict-suchet` via `nodeSelector` en raison de volumes Longhorn défectueux sur `iict-k8s-node4-rad`.

#figure(
  image("../images/Schema-Kubernetes.png", width: 95%),
  caption: [
    Les ressources K8s sont distribuables sur n'importe quel nœud ; seuls les workers Ray ciblent les nœuds GPU via nodeAffinity.
  ],
) <Schema-Kubernets>

Le nœud `iict-chasseron` est exclu pour deux raisons :
- ses L4 offrent une puissance de calcul inférieure (24 Go de VRAM contre 48 Go)
- il portait un taint `node.kubernetes.io/disk-pressure` lors des tests, exposant les pods à des évictions SIGTERM sans préavis.#footnote[Le taint `disk-pressure` est appliqué automatiquement par Kubernetes quand l'usage disque dépasse le seuil `evictionHard`. Les pods sur ce nœud reçoivent un SIGTERM et sont immédiatement reschedulés sur un autre nœud, interrompant toute inférence en cours sans possibilité de reprise.]

Le GPU Operator NVIDIA est installé sur le cluster. Il installe automatiquement les drivers GPU, le device plugin et DCGM Exporter sur chaque nœud. Les requêtes de ressource `nvidia.com/gpu` fonctionnent sans configuration manuelle.

== RayCluster

La pipeline repose sur deux modes d'exécution distincts, tous deux pilotés par un driver externe au cluster.

Le *Batch Job Driver* soumet une liste d'images S3 au cluster, crée un pool d'Actors GPU via `ray.remote`, distribue les clés d'image aux workers disponibles et attend les résultats avec `ray.get()`. Chaque résultat est écrit en Parquet sur MinIO.

Le *Solo Job Driver* soumet une seule image et attend la réponse de façon synchrone. Le résultat est retourné en JSON, compatible avec l'import direct dans Label Studio.

Les deux modes partagent le même *Ray Control Plane*, hébergé sur le Head Node : le *Global Control Store* (GCS) maintient l'état global du cluster (Actors actifs, tâches en attente, état des workers) et le *Raylet* tourne sur chaque nœud pour scheduler localement les tâches que le GCS lui assigne.

Chaque worker process héberge un Actor SAM3 avec son propre *Plasma Object Store* local. Les objets volumineux (poids du modèle, données image, résultats) transitent par cet object store partagé en mémoire plutôt que par le réseau, ce qui évite les copies inutiles entre le driver et les workers.

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
    node((2, 2), wt[*L4 × 4*\ #text(size: 0.78em)[iict-chasseron]], corner-radius: 8pt, fill: col-red, name: <l4>),
    edge(<rdriver>, <head>, "->", [`ray.init(:10001)`]),
    edge(<head>, <l40s>, "<->"),
    edge(<head>, <a40>, "<->"),
    edge(<head>, <l4>, "<->", stroke: (dash: "dashed")),
  ),
  caption: [Architecture du RayCluster sur iict-rad],
) <fig-raycluster>


#figure(
  image("../images/Schema-Ray.png", width: 100%),
  caption: [
    Le driver soumet les tâches au Ray Control Plane (GCS + Raylet), puis chaque worker process héberge les Actors avec leur Plasma Object Store local ; les résultats sont écrits sur MinIO via boto3.
  ],
) <Schema-Ray>

Le RayCluster est déclaré via la ressource CRD `ray.io/v1/RayCluster`, que KubeRay gère (cf. @etat-de-lart pour le rôle de l'opérateur et les Services associés).

Le driver s'exécute à l'extérieur du cluster en tant que Job Kubernetes sans GPU, et se connecte au head en soumettant ses tâches au GCS de la même façon.

Les workers Ray doivent s'exécuter sur des nœuds GPU : une contrainte `nodeAffinity` sur le groupe de workers restreint leur scheduling aux nœuds `iict-suchet` (L40S) et `iict-k8s-node4-rad` (A40).

Les workers s'exécutent dans des pods séparés et n'héritent pas des variables d'environnement du driver : les credentials MinIO et le token HuggingFace doivent donc être déclarés explicitement dans le `workerGroupSpec`, par référence aux Secrets Kubernetes (cf. @arch-secrets). Sans cette déclaration, chaque appel S3 depuis un Actor échoue avec `NoCredentialsError` et le premier démarrage du worker tente de télécharger les poids SAM3 sans authentification.

Les manifestes correspondants sont détaillés au chapitre implémentation.

== Cache du modèle SAM3

Les poids du modèle SAM3 représentent 3,3 Go téléchargés depuis HuggingFace Hub. Sans cache persistant, chaque recréation de pod lance un nouveau téléchargement, ajoutant plusieurs minutes de latence avant que le worker soit opérationnel.

Pour cela il faut ajouter une `StorageClass` et un `PersistentVolumeClaim`.

Un PVC Longhorn de 10 Gi est partagé entre tous les workers Ray. HuggingFace Hub vérifie ce répertoire avant tout téléchargement. Si les poids sont présents, il les charge directement sans accès réseau. Le PVC survit aux redéploiements du RayCluster : les poids ne sont donc téléchargés qu'une seule fois.

Le mode `ReadWriteMany` est retenu car les workers s'exécutent sur deux nœuds distincts (`iict-suchet` et `iict-k8s-node4-rad`). Un PVC `ReadWriteOnce` ne peut être monté que par un seul nœud à la fois, ce qui bloquerait les workers sur le second nœud.

Longhorn implémente le `ReadWriteMany` via un share-manager NFS. Chaque nœud qui monte le volume agit comme client NFS et a besoin de `mount.nfs`, fourni par le paquet `nfs-common`. Ce paquet doit être installé sur tous les nœuds, sinon tout pod ordonnancé dessus échouerait au montage avec `FailedMount` : "bad option".

Déclarer une StorageClass RWX ne suffit donc pas car elle peut supposer implicitement que tous les nœuds candidats sont homogènes. Un pod sans affinité tombant sur un nœud sans `nfs-common` reste bloqué. Cette dépendance d'infrastructure doit être vérifiée avant de compter sur le RWX.

== Stratégie de tuilage <tuilage-strategie>

Le hardware est une contrainte pour les performances de notre pipeline. Les deux autres vecteurs envisageables pour gagner en performances sont le software (choix du modèle, optimisation du code) ou simplement les données brutes à traiter. Dans notre cas, des images de très haute résolution (8192 × 4096 px) doivent être traitées par SAM3 qui, pour rappel, a comme taille maximale de traitement une tuile de 1008 × 1008 px.

Les conséquences sont les suivantes :
- > 1008 px : la tuile est downsamplée par SAM3 et nous avons une perte d'information.
- < 1008 px : la tuile est upscalée par SAM3 et il n'y a aucun gain d'information.
- \= 1008 px : natif, donc pas de changement.
Il faut donc jouer avec la taille des tuiles et leur nombre.

Nous devons donc définir des valeurs par défaut pour le nombre de tuiles et leurs dimensions, à travers des variables exposées par l'API.

#figure(
  image("../images/tillingExplanation.jpg", width: 100%),
  caption: [
    SAM3, comme tout modèle à base de ViT, attend une entrée carrée de taille fixe. Un objet à cheval sur une bordure de tuile se retrouve, grâce au striding, entier sur au moins une des tuiles voisines.
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
    [`label`], [`string`], [Label demandé (ex. `sign`, `road_marking`)],
    [`score`], [`float32`], [Score de confiance SAM3 (0–1)],
    [`points`], [`string`], [Polygone JSON encodé, en % des dimensions de l'image],
    [`original_width`], [`int32`], [Largeur de l'image source en pixels],
    [`original_height`], [`int32`], [Hauteur de l'image source en pixels],
    [`latitude`], [`float64`], [Latitude GPS en degrés décimaux (null si absent)],
    [`longitude`], [`float64`], [Longitude GPS en degrés décimaux (null si absent)],
  ),
  caption: [Schéma Parquet de sortie de la pipeline],
) <tab-parquet-schema>

Les coordonnées sont stockées en `float64` (double précision) et non en `float32` car le format standard `float32`, par sa capacité limitée, ne permet pas de conserver suffisamment de chiffres après la virgule, ce qui génère une imprécision d'environ 60 centimètres au moment même du stockage. L'utilisation du `float64` élimine cette erreur d'arrondi et préserve la précision du récepteur GNSS.

Le `score` de confiance, lui, reste en `float32` car quelques décimales suffisent à un seuil de filtrage, et la colonne est ainsi deux fois plus compacte.

La compression Snappy#footnote[Algorithme de compression développé par Google et utilisé par défaut par Parquet. Il privilégie la vitesse de compression et de décompression sur le taux de compression. Les fichiers sont un poil plus gros qu'avec gzip, mais leur lecture ne coûte presque rien en CPU.] est appliquée. Les fichiers sont interrogeables directement avec PyArrow, déjà présent dans la pipeline, sans étape de chargement en base de données.

== Géoréférencement des détections

Chaque polygone hérite des coordonnées GPS de son image, portées par les colonnes `latitude` et `longitude` du schéma (@tab-parquet-schema). Ces coordonnées ne sont pas lues dans l'EXIF, mais dans le fichier de trajectoire de l'acquisition.

L'EXIF s'est révélé une source peu fiable : les panoramas Ladybug5+ ne portent aucune balise `GPSLatitude`/`GPSLongitude`, là où les prises GoPro Max les renseignent. Le lire directement laissait des colonnes vides sur des acquisitions entières.

La position de chaque prise vit dans un fichier écrit par le système de cartographie mobile : `<acquisition>/02_poses/<session>_trajectory.csv`. Il associe chaque nom d'image à sa latitude, sa longitude, son altitude et son cap, échantillonnés par le récepteur GNSS embarqué.

Pour chaque image, le worker déduit le chemin de ce fichier, le charge une fois par session et le met en cache dans l'acteur Ray, ce qui est un coût négligeable pour un CSV de quelques milliers de lignes. Il joint ensuite la ligne correspondant au nom de fichier.

La session est déduite de l'arborescence de l'acquisition (`01_images/<session>/`) et l'EXIF ne subsiste qu'en secours, s'il n'y a pas de CSV.

== Intégration Label Studio

Label Studio est connecté à MinIO comme _source storage_ S3. Les URLs `s3://nearai/...` sont converties en URLs HTTP temporaires pré-signées, servies directement du stockage au navigateur sans proxy.

L'interface de labeling du projet déclare les classes annotables, et les pré-annotations importées doivent référencer exactement les mêmes noms d'interface (au format XML) ; une divergence provoque l'affichage des polygones sans label avec une couleur grise.

La définition XML de l'interface et le format d'import sont détaillés au chapitre implémentation.

#pagebreak()
== Intégration NearLabel <nearlabel-integration>

NearLabel lit ses données directement depuis les fichiers Parquet stockés dans le bucket S3, sans passer par l'API de la pipeline. Le stockage objet sert de contrat d'échange entre les deux applications. Ce contrat repose sur une arborescence précise. Chaque acquisition expose un dossier `09_Pipeline_result/` contenant, par run, les fichiers Parquet de détections (en miroir de l'arborescence de `01_images/`), le fichier `params.json` qui fige les paramètres du run (labels, tuile, stride, downsample) et la configuration de la caméra propre à l'acquisition.

C'est à partir de ces trois éléments que NearLabel reconstitue ce qu'il affiche sur l'application web : les Parquet fournissent les polygones et leurs coordonnées GPS, `params.json` documente la provenance des détections, et la configuration caméra permet d'interpréter la géométrie des panoramas. Tant que cette arborescence est respectée, les deux applications évoluent indépendamment et la pipeline peut changer d'implémentation sans casser NearLabel, et inversement.

NearLabel peut enfin déclencher une *segmentation à la demande* : l'utilisateur transmet à l'endpoint `/segment` la clé de l'image et les points à segmenter, et reçoit les polygones en retour. Ce service est décrit à la section Segmentation interactive ; le format de la requête figure au chapitre implémentation.

== Observabilité

La stack d'observabilité collecte deux flux distincts :
1. les métriques GPU et Ray via Prometheus
2. les logs des pods via Alloy et Loki.

Grafana agrège les deux sources dans un dashboard unique.

#figure(
  image("../images/Schema-Observability.png", width: 65%),
  caption: [
    Prometheus récolte les métriques tandis que Loki s'occupe des logs afin d'alimenter Grafana.
  ],
) <Schema-Observability>

Prometheus scrape deux sources de métriques toutes les 15 secondes :

*DCGM Exporter* : 4 métriques GPU par nœud (`DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP`), exposées en DaemonSet sur le port 9400 (cf. @implementation pour le mécanisme de scraping via Service headless).

*RayCluster* : métriques Ray exposées par le head node (`ray_running_jobs`, `ray_gcs_actors_count`).

*Alloy* est déployé en Deployment unique dans le namespace `dani`. Il lit les logs de tous les pods via l'API Kubernetes (`loki.source.kubernetes`) sans monter le système de fichiers du nœud hôte et les pousse vers Loki en continu. Chaque ligne de log est indexée avec les labels `pod`, `container`, `namespace` et `app`, ce qui permet de filtrer les logs par composant depuis Grafana. Les règles de relabeling correspondantes sont données au chapitre implémentation.

*Loki* stocke l'index (TSDB) et les chunks de logs dans MinIO, dans un bucket dédié `nearai-logs`. Il est ainsi _stateless_, tout l'état réside dans le bucket S3, et le pod peut être redémarré sans perte de données.

Les logs du driver SAM3 contiennent les résultats de chaque run au format texte.

Grafana interroge les résultats via LogQL avec `regexp` et `unwrap` pour en extraire des métriques comme le nombre d'images traitées, détections, et temps moyen par image.

#pagebreak()
== API

Une API REST expose la pipeline aux utilisateurs et aux systèmes externes. Elle permet de soumettre des jobs batch ou on-demand, de consulter leur état et d'importer automatiquement les résultats dans Label Studio, le tout sans accès direct au cluster Kubernetes.

#figure(
  image("../images/API.png", width: 100%),
  caption: [
    L'API permet de créer les pods, de lire leur statut via les librairies K8s et de retourner les résultats post-traitement.
  ],
) <Schema-API>

#linebreak()

L'API tourne comme un `Deployment` dans le namespace `dani`, avec un `ServiceAccount` aux droits limités (le détail du Role figure plus bas). Elle soumet les jobs en créant des ressources `Job` via le SDK Kubernetes Python, ce qui découple l'API de l'état interne du RayCluster.

#pagebreak()
La liste des endpoints est la suivante :
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
    [Message de vie en JSON ; redirige un navigateur vers la console `/ui`.],

    [`POST /jobs/batch`],
    [#set par(justify: false); #text(
        size: 0.85em,
      )[`s3Uri` ou `s3Uris`, `s3OutputUri`,\ `s3Bucket`, `labels`, `numWorkers`,\ `batchSize`, `tileSize`, `tileStride`,\ `downsample`]],
    [Soumet un lot d'images S3. Retourne `{job_name, status}`.],

    [`POST /jobs/solo`],
    [#set par(justify: false); #text(size: 0.85em)[`imageUri`, `s3Bucket`, `labels`,\ `tileSize`, `tileStride`, `downsample`]],
    [Soumet une image unique, poll le statut du Job K8s et retourne le résultat au format JSON Label Studio.],

    [`GET /jobs`], [-], [Liste les Jobs `sam3-batch-*` et `sam3-solo-*` du namespace avec leur statut.],
    [`GET /jobs/{name}`],
    [#text(size: 0.85em)[`name`]],
    [Retourne le statut d'un Job (`Pending`, `Running`, `Succeeded`, `Failed`).],

    [`POST /segment`],
    [#text(size: 0.85em)[`url`, `items` (point + label)]],
    [Segmente l'objet situé sous chaque point cliqué et étiquette le masque avec le label fourni.],

    [`POST /import/\ {acquisition_id}`],
    [#text(size: 0.85em)[`acquisition_id`]],
    [Lit les Parquets depuis MinIO, les convertit et les importe via l'API REST Label Studio.],

    [`GET /segment/status`],
    [-],
    [Retourne l'état du service de segmentation interactive (`replicas` voulus, `ready` prêts).],

    [`GET /ui`],
    [-],
    [Sert la console web de pilotage de la pipeline.],
  ),
  caption: [Endpoints de l'API REST],
) <tab-api-endpoints>

Ce tableau n'est d'ailleurs qu'une photographie, car la référence vivante est la documentation *OpenAPI* que FastAPI génère automatiquement par introspection du code : routes, modèles Pydantic (types, champs optionnels, valeurs par défaut) et docstrings.

Elle est exposée en trois formes : `/docs` (interface Swagger interactive, qui permet d'exécuter une requête depuis le navigateur), `/redoc` (présentation de type manuel de référence) et `/openapi.json` (spécification brute, consommable par des générateurs de clients). Aucun fichier de documentation n'est maintenu à la main, le contrat publié ne peut pas diverger du code, puisqu'il en est extrait à chaque démarrage.

Les paramètres d'un traitement (image source, labels, nombre de workers, tuilage) changent à chaque requête. Un manifeste YAML statique ne peut pas les porter, l'API construit donc chaque `V1Job` dynamiquement à partir du corps de la requête. Le Job hérite de `imagePullPolicy: Always` (toujours tirer la dernière image `:staging`), `restartPolicy: Never`, `runtimeClassName: nvidia` et des ressources `nvidia.com/gpu` pour les pods à GPU, et `ttlSecondsAfterFinished: 3600` pour l'auto-nettoyage après 1 h, un délai qui laisse le temps de relire les logs d'un run avant la suppression du pod.

Ce modèle découple l'API de l'état du RayCluster, un Job batch n'est qu'un driver éphémère qui se connecte au cluster permanent, tandis qu'un Job solo embarque son propre GPU. L'API n'a pas à connaître la topologie Ray, elle ne fait que soumettre des Jobs.

Les gabarits de ressources suivent ce partage des rôles. Le Job solo reçoit un GPU, 4 CPU et 16 Gio de mémoire garantis (jusqu'à 8 CPU et 32 Gio en pointe), le même dimensionnement que les workers Ray puisqu'il exécute la même inférence. Le driver batch, qui ne fait qu'orchestrer pendant que le calcul se déroule sur le RayCluster, se contente de 1 CPU et 2 Gio garantis (2 CPU et 4 Gio en pointe), sans GPU.

L'API tourne sous le ServiceAccount `sam3-api`, lié par un `RoleBinding` à un `Role` au moindre privilège : `create/get/list/watch/delete` sur les `jobs`, `get` sur les `pods` et `pods/log`, et `get/patch` sur les `deployments/scale` pour le réveil du service de segmentation. Les subtilités du modèle RBAC rencontrées (sous-ressources distinctes) sont traitées au chapitre implémentation.

Le Job solo écrit son résultat (`results/<job>.json`) sur S3, et l'endpoint `get_result` relit cet objet. Le stockage S3 est durable et indépendant du TTL des Jobs : le résultat survit à la suppression automatique du pod après une heure.

Deux alternatives ont été écartées. Les logs du pod sont éphémères (effacés avec le pod) et, sur `kubernetes-client` 36.x, leur lecture souffre d'un bug d'encodage. Une base SQLite est inadaptée à un accès distribué et à un montage NFS partagé. S3 est déjà la source des données et le puits des prédictions, y conserver les résultats évite toute pièce supplémentaire.

== Segmentation interactive

SAM3 accepte deux familles de prompts :

1. Le *prompt visuel* (PVS) répond à la question OÙ : il produit un masque class-agnostic à l'endroit désigné, sans nommer l'objet.
2. Le *prompt concept* (PCS) répond à QUOI : il trouve toutes les instances du concept fourni dans l'image.

La pipeline batch et le job solo utilisent le PCS, on leur passe des labels texte (`sign`, `road_marking`) et SAM3 détecte chaque occurrence. L'endpoint interactif (segmentation à la volée), lui, utilise le PVS, l'annotateur clique un point, SAM3 retourne le contour de l'objet sous le curseur.

Le label n'oriente pas la détection ici car il est fourni en entrée et sert uniquement à étiqueter le masque retourné.

La *segmentation interactive* impose une latence faible. Lancer un Job par requête est exclu car chaque clic paierait le démarrage à froid. Le service de segmentation est donc un Deployment qui charge SAM3 une seule fois, au démarrage du pod avec FastAPI lifespan et garde le modèle chaud en VRAM pour toute la session. Son pod reçoit un GPU, 2 CPU et 8 Gio de mémoire garantis (jusqu'à 4 CPU et 16 Gio en pointe), un gabarit plus léger que celui des workers batch car il ne traite qu'une image à la fois.

Mais garder ce pod actif en permanence monopoliserait un GPU sur les neuf disponibles, même hors session d'annotation. Le Deployment reste donc à zéro réplica par défaut, et l'API le pilote : `POST /segment/up` le scale à 1 et `POST /segment/down` le scale à 0 et libère le GPU.

Le réveil aurait pu être automatisé avec KEDA et son extension HTTP, qui réveille un service dès qu'une requête arrive. Cette piste a été écartée pour trois raisons :

1. KEDA s'installe à l'échelle du cluster et requiert des droits d'administrateur, hors de portée du namespace actuel.
2. L'extension HTTP insère un _interceptor_ devant le service pour retenir la requête le temps que le pod démarre, ajoutant une pièce supplémentaire dans le chemin réseau.
3. KEDA n'élimine pas le démarrage à froid (le chargement du modèle en mémoire GPU, de l'ordre de 20 à 30 secondes) : il ne fait que le déclencher automatiquement.

Pour un usage ponctuel et séquentiel (un seul annotateur, une image à la fois), le pilotage manuel offre la même expérience réelle : un unique démarrage à froid en début de session, sans dépendance d'infrastructure ni composant réseau additionnel. Le mécanisme de scaling est détaillé au chapitre implémentation.

L'endpoint interactif s'appuie sur l'API *Ultralytics*, qui expose la prédiction par prompt visuel en un seul appel (`model.predict(points=, labels=)`). Le service n'utilise que le prompt par point, l'annotateur clique, SAM3 renvoie le masque de l'objet sous le curseur. Cette API évite la pipeline complète du mode batch (tuilage, collate, postprocessor), inutile pour une inférence ponctuelle ; l'image Docker en est donc plus légère. Le service n'a pas d'authentification propre : il est exposé via l'Ingress et protégé au niveau du cluster.


== Console web

L'API REST suffit aux intégrations machine (NearLabel, CLI), mais piloter la pipeline exige alors `curl` ou `kubectl`, ce qui peut être inadapté à une démonstration ou à un utilisateur occasionnel. Une console web couvre ce besoin : lancer un batch ou un job solo (par préfixe S3 ou par liste explicite d'URLs), suivre sa progression en direct, consulter l'état de l'API et du service de segmentation interactive, et déclencher l'import Label Studio. NearLabel n'a pas cet import à déclencher : il lit directement les Parquet sur S3 (cf. @nearlabel-integration).

La console est servie par l'API elle-même, sur l'endpoint `/ui`, plutôt que par un déploiement web dédié. Ce choix élimine trois problèmes d'un coup :
1. le navigateur appelle les endpoints en même origine, donc aucune configuration CORS à introduire ni à justifier en revue de sécurité.
2. la page est versionnée et livrée avec le contrat d'API qu'elle consomme, les deux ne peuvent pas diverger.
3. l'infrastructure ne gagne aucun artefact supplémentaire (pas d'image nginx, de `Deployment`, ni de règle d'ingress à maintenir pour un fichier statique). Un pod web séparé ne se justifierait que si l'interface acquérait son propre cycle de vie.

La console fonctionne en mode *pull* : elle interroge périodiquement les endpoints existants (`/jobs/`, `/jobs/{name}/status`, `/health`, `/segment/status`) au lieu d'exiger un canal temps réel (WebSocket, SSE). La progression d'un batch étant déjà matérialisée par le fichier de statut sur S3 (cf. plus haut), un sondage toutes les quelques secondes suffit et n'ajoute aucun état côté serveur.

Le suivi de l'état du service de segmentation a motivé le seul endpoint spécifique créé pour la console, `GET /segment/status`, qui expose l'état du pod de segmentation : endormi, en cours de démarrage ou prêt.


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

Quatre secrets alimentent la stack : les credentials MinIO (`minio-secret`), le token HuggingFace (`hf-secret`), les identifiants du registre privé (`ghcr-secret`) et le compte administrateur du dashboard d'observabilité (`grafana-secret`).

Aucun n'est inscrit dans une image ni dans un fichier en clair du dépôt. Ils existent comme Secrets Kubernetes dans le namespace `dani`, et les pods les consomment au runtime via `secretKeyRef` : ni l'API ni les workers ne manipulent jamais une valeur de secret, ils déclarent seulement quelle variable d'environnement doit être tirée de quelle clé, et le `kubelet` résout la référence au démarrage du pod.

Les manifestes de ces Secrets sont tout de même versionnés, mais *chiffrés* avec SOPS et une clé age (cf. @etat-de-lart pour le choix de cette solution), dont la clé privée vit hors du dépôt.

Un déchiffrement automatique en GitOps (Flux ou ArgoCD avec ksops) exigerait d'installer des composants à l'échelle du cluster, hors de portée du namespace. Le déchiffrement reste donc une étape manuelle du déploiement. L'outillage complet (règles de chiffrement, édition, application) est décrit au chapitre implémentation.
