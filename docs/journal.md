# Week 1
*Vendredi 20 février 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Meeting with Rémy        |   Done   | 45min |
| Analysing Ray, testing python and learning       |   Done  | 3h |
| Creating Git    |  Done   | 20min |
| Analysing docs and older Thesis | Done   | 30min |
| Look at MiniIO and Label Studio | Done   | 1h |
| **Total** |    | 5h35 |

---

# Week 2
*Vendredi 27 février 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Meeting with Bertil       |   Done   | 30min |
| Analysing MinIO and alternatives      |  Done   | 2h |
| Analysing Ray, Spark and ZARR      |  Done   | 2h |
| Analysing PostGIS      |  Done   | 30min |
| Reading redaction documents      |  To continue next week   | 1h |
| Create base of the specifiaction document     |  Done   | 1h15 |
| Create all the prelimenary tasks for the whole project   |  Done   | 1h45 |
| **Total** |    | 8h |

---

# Week 3
*Vendredi 6 mars 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Meeting with Bertil       |   Done   | 45min |
| Updated week 3 notes (batch and on-demand scenarios) | Done | 20min |
| Reworked specifications : removed ZARR, added observability, Parquet on S3, Rancher, fixed MinIO | Done | 1h30 |
| Applied Elements of Style principles to specifications.md | Done | 30min |
| Exported specifications to .tex files | Done | 45min |
| Updated planification (weeks 4-22) | Done | 30min |
| Created project folder structure | Done | 10min |
| Created HuggingFace account + requested SAM3 model access | Done | 15min |
| Setup GitHub Container Registry (ghcr.io) | Done | 20min |
| Dockerfile SAM3 (CUDA 12.6 + venv + PyTorch) | Done | 45min |
| test_sam3.py script | Done | 20min |
| Migrated Docker/containerd storage to /home | Done | 45min |
| Built and pushed SAM3 Docker image to ghcr.io | Done | 30min |
| Deployed SAM3 pod on K8s cluster (namespace dani) | Done | 45min |
| Fixed GPU access : added runtimeClassName: nvidia to pod YAML | Done | 15min |
| Explored SAM3 Python API (Sam3Processor, add_geometric_prompt) | Done | 30min |
| Successfully ran SAM3 inference on GPU (CUDA 12.6) | Done | 20 |
| Documented deployment process in docs/SAM3/Readme.md | Done | 20min |
| **Total** |    | 9h30 |

---

# Week 4
*Vendredi 13 mars 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Back to the project, reading and re-understanding the project | Done | 1h45 |
| Meeting with Bertil | Done | 45min |
| Ray extras selection (data, train, serve) | Done | 15min |
| Dockerfile Ray (CUDA 12.6 + ray[data,train,serve,default]) | Done | 30min |
| wordcount.py : MapReduce with Ray | Done | 1h |
| K8s manifests Ray : head, workers, services, ingress | Done | 1h30 |
| Debug connexion Ray client (ray:// vs GCS, runtimeClassName, ray-client-server-port) | Done | 2h |
| RayCluster on K8s (1 head + 3 workers GPU) need acces to continue | Not Done | - |
| Dashboard Ray accessible via ingress | Done | 30min |
| Documented Ray deployment in docs/RAY/Readme.md | Done | 20min |
| Dog classifier : EfficientNet B0 distributed on Ray workers | Done | 2h |
| Debug OOM : switched from @ray.remote function to Actor (model loaded once per worker) | Done | 45min |
| Batch processing 5000 images (batches of 100) on Ray cluster | Done | - |
| Cleaned up notes.md | Done | 15min |
| **Total** |    | 11h30 |

---

# Week 5
*Vendredi 20 mars 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
|Trouble connection to the newtork | Done | 30 min|
| Meeting with Bertil | Done | 15min |
| Reorganised Ray K8s manifests : moved from rayTemp (manual Pod+Deployment) to proper KubeRay RayCluster CRD in deploy/ray/  + fix of the RayCluster files manifest| Done | 45min |
| Created Typst folder (copy of template from Silvain Pasinis's repo) | Done | 30min |
| Converted specifications.md to Typst (chapitres/cahier-des-charges.typ) | Done | 1h |
| Created main entry point cahier-des-charges.typ with title page, TOC, disclaimer | Done | 30min |
| Populated bibliography.yaml with papers (MapReduce, Ray, Prometheus) and web references | Done | 30min |
| Fixed supervisor gender label in Typst template | Done | 5min |
| Completed Week 5 notes : Loki, Parquet (from PhDW-3 paper), Promtail | Done | 45min |
| Created sam3_pipeline.py : Ray Actor + SAM3 + EXIF GPS extraction + tiling (need to be tested) | Done | 1h |
| Created Dockerfile.sam3 : Ray 2.54.0 + SAM3 + exif + Pillow on CUDA 12.6 | Done | 30min |
| Created job-sam3-pipeline.yaml K8s manifest | Done | 15min |
| Built and pushed ray-sam3 image to ghcr.io | Done | 30min |
| Debug Ray () | Done | - |
| **Total** |    | 11h |

---

# Week 6
*Vendredi 27 mars 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Debug and fix SAM3 pipeline on cluster (OOM, libGL, numpy conflict, Ray address) | Done | 2h |
| Optimise pipeline : batch processing, polygon extraction in worker, timing instrumentation | Done | 1h |
| Configure nodeAffinity on workers and job pod (L40S, A40, disk-pressure exclusion) | Done | 30min |
| Benchmark 512x512 vs 1024x1024 tiles on cluster, analyse GPU scheduling constraints | Done | 1h |
| **Total** |    | 4h30 |

---

# Week 7
*Vendredi 3 avril 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Research downsampling strategies : analyse trade-offs between resolution reduction and segmentation quality | Done | 1h |
| Meeting with Bertil | Done | 25min |
| Implement downsampling preprocessing in sam3_pipeline.py : resize image before tiling, parametrise scale factor | Done | 1h30 |
| Build test Docker images for local downsampling experiments | Done | 45min |
| Run SAM3 pipeline locally : validate downsampling at multiple scale factors | Done | 2h |
| Analyse results : compare polygon count and inference time vs full-resolution baseline | Done | 45min |
| Reorganise project structure : consolidate all docs under docs/ (Specification, report), remove legacy folders (TB_CahierDesCharges_Typst, specifications, report, tools) | Done | 1h |
| **Total** |    | 7h |

---

# Week 8
*Vendredi 10 avril 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Analyse Loki and observalibity stack | Done | 4h |
| **Total** |    | 4h |

---

# Week 9
*Vendredi 17 avril 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Workstation data loss, recovery and environment rebuild | Done | 45min |
| Re-read project state : pipeline architecture, benchmarks, open decisions | Done | 1h45 |
| Study K8s vs RayCluster network abstraction : GCS address, service ports, client protocol | Done | 1h |
| Verify GPU Operator installation on iict-rad cluster (confirmed via IICT wiki) | Done | 30min |
| Analyse cost : rented GPUs (H100, Replicate) vs on-premise cluster | Done | 1h |
| Meeting with Bertil       |   Done   | 25min |
| Design pipeline architecture diagram (K8s cluster, Ray workers, MinIO, job-solo/batch flows) | Done | 1h30 |
| Debug RayCluster : head not ready, 3rd worker pending (insufficient GPU) | Done | 45min |
| Contact Shancli (SAM3 optimised image) and Olivier Lemer (Workshop pictures/slides) | Done | 45min |
| Read Parquet documentation | Done | 1h45min |
| **Total** |    | 10h10 |

---

# Week 10
*Vendredi 24 avril 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Migration from our generic pipeline to a new one with Shancli's base and added s3 bucket conncetion (read images, and write JSON + Parquet) | Done | 1h30 |
| Switch pipeline output format from LabelStudio JSON to Parquet (schema: image_key, acquisition_id, label, score, points, lat, lon) | Done | 1h40 |
| Add GPS extraction from EXIF in pipeline (DMS --> decimal degrees via `exif` library) | Done | 30min |
| Add `pyarrow` to Dockerfile.sam3, fix COPY directive, rebuild and push image | Done | 30min |
| Create Longhorn PVC for HuggingFace model cache (10 Gi) eliminates 3.3 GB re-download on each pod restart | Done | 20min |
| Debug CUDA visibility bug in local Ray mode (`.options(num_gpus=0)` was hiding all GPU devices) | Done | 45min |
| Create K8s Job manifest for local mode testing (`job-sam3-ray-test.yaml` : 1 GPU, PVC mount, `--local`) | Done | 20min |
| Fix missing MinIO credentials on Ray workers (env vars not inherited from driver added to `rayCluster.yaml` worker spec) | Done | 30min |
| Run full pipeline on cluster : 40 images, 2 workers (3rd GPU occupied), 2230 detections, ~111s/image | Done | 1h |
| Read Parquet output with DuckDB to verify schema and GPS data | Done | 15min |
| Configure MinIO as S3 cloud storage in Label Studio (endpoint, bucket `nearai`, region `ch`) | Done | 30min |
| Convert pipeline Parquet output to Label Studio import format (wrap result array in `data.image` + `predictions`) | Done | 30min |
| Debug Label Studio import : fix `from_name` mismatch (`tag` --> `label`) to match labeling interface XML | Done | 20min |
| Import first SAM3 results into Label Studio and verify polygons render correctly | Done | 20min |
| Design API : 3 REST endpoints (`POST /batch`, `GET /status/{job_id}`, `POST /predict`) with full request/response schemas | Done | 45min |
| Update notes.md : Week 10 full write-up (Parquet schema, CUDA bug, Ray worker env vars, Label Studio, projection decision) | Done | 20min |
| Write first draft of TB report : 6 chapters (introduction, état de l'art, architecture, implémentation, résultats, conclusion) + bibliography | Done | 2h15 |
| **Total** |    | 12h40 |

---

# Week 11
*Vendredi 1 mai 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Research deprecation status of MPS, GPU Operator and DCGM Exporter | Done | 30min |
| Create observability stack K8s manifests (Prometheus, Loki, Promtail, Grafana) in `deploy/observability/` | Done | 3h |
| Deploy full observability stack on cluster (all pods running) | Done | 30min |
| Fix Promtail RBAC : ClusterRole --> Role (namespace-scoped, no cluster admin required) | Done | 15min |
| Fix Loki S3 config : filesystem --> MinIO S3 (`nearai/dani/loki`), env vars from `minio-secret` via `-config.expand-env=true` | Done | 30min |
| Fix Promtail "too many open files" on iict-suchet : namespace filter + privileged initContainer (sysctl inotify) | Done | 45min |
| Verify Prometheus scrapes Ray metrics (`ray_running_jobs`, `ray_gcs_actors_count`) | Done | 15min |
| Investigate DCGM Exporter access : blocked by network policy, drafted mail to Mehdi with NetworkPolicy YAML | Done | 30min |
| Run SAM3 pipeline on new dataset `20250521-HSN/01_images/S001/` (2000 images, 2 workers, ~4s/image wall clock) | Done | 1h |
| Fix RayCluster not starting, port 8080 declaration conflict with Ray internal port | Done | 30min |
| Fix worker eviction on iict-chasseron : add hard `NotIn` nodeAffinity to exclude disk-pressure node | Done | 40min |
| Identify timing bug in pipeline : `total_time` was sum across workers, not wall clock — fix + add split timing (download/inference/upload) | Done | 30min |
| Create `tests/RAY/test4/` : dynamic work queue pipeline with `ray.wait()` for better load balancing | Done | 1h |
| Update TB report : TOC after title page, blank page, cahier des charges content from spec, glossary in annexes | Done | 3h |
| Update notes.md : Week 11 full write-up (observability stack, pipeline run, timing bug, dynamic queue) | Done | 20min |
| Design API label classes : class objects with name+description instead of flat string arrays | Done | 20min |
| **Total** |    | 13h35 |


---

# Week 12

*Mercredi 6 mai 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Fix DCGM Exporter multi-node scraping : migrate Prometheus config from `static_configs` (ClusterIP round-robin) to `dns_sd_configs` (headless service, resolves all pod IPs) | Done | 33min |
| Create `tests/gpu.py` : query Prometheus for 4 DCGM metrics (util %, VRAM MB, power W, temp °C) with aligned formatted output | Done | 1h |

*Vendredi 8 mai 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Debug Grafana PVC mount failure on Longhorn : ghost block device on node4 -> force `nodeSelector: iict-suchet`, add `securityContext fsGroup: 472 runAsUser: 472` | Done | 1h20 |
| Fix Prometheus PVC mount : add `securityContext fsGroup: 65534 runAsUser: 65534` and `nodeSelector: iict-suchet` | Done | 30min |
| Migrate Promtail (EOL) -> Grafana Alloy : write River config (`loki.source.kubernetes`), Deployment, RBAC (ServiceAccount, Role, RoleBinding), debug CLI positional arg | Done | 2h |
| Accept L4 GPUs in RayCluster : remove `NotIn iict-chasseron` from `requiredDuringScheduling` nodeAffinity, delete worker pods to force recreation | Done | 30min |
| Build Grafana GPU monitoring dashboard : `hostname_filter` textbox variable, regex filter `{Hostname=~".*${hostname_filter}.*"}`, data links on gauge panel | Done | 1h55 |
| Research project uniqueness : confirm no public project combines SAM3 + Ray/KubeRay + equirectangular panoramic images + Label Studio + Parquet/GPS at this scale | Done | 30min |
| Report Alloy section : River config example, advantages vs Promtail (single Deployment, no inotify) | Done | 30min |
| Read articles about Spark and Alloy | Done | 1h40 |
| Report Spark vs Ray : 3 structural Spark limitations (CPU heritage, homogeneous clusters, ML performance), Amazon 2024 migration ($120M/year, 82% efficiency gain) | Done | 45min |
| Report data parallelism vs model parallelism : justify SAM3 Actor strategy (2.4 GB VRAM fits on 1 GPU, throughput goal over 300k images) | Done | 20min |
| Create architecture diagrams with fletcher (pipeline overview, RayCluster, observability stack) : debug fletcher 0.5.3 -> 0.5.7 upgrade for Typst 0.14.2 compatibility, add colors | Done | 1h30 |
| Add bibliography entries : `anyscale-spark`, `daft-benchmark`, `amazon-ray` | Done | 13min |
| Update glossary : 22 new terms (Alloy, River, ViT, SA-1B, VRAM, OOM, data/model parallelism, tuile, équirectangulaire, RayCluster, Head Node, DaemonSet, Deployment, Headless Service, NodeAffinity, TSDB, PromQL, LogQL, Snappy, inotify, Spark, ETL) | Done | 36min |
| Update notes.md : Week 12 write-up | Done | 38min |
| **Total** |    | 14h30 |

# Week 13

*Jeudi 14 mai 2026 & Vendredi 15 mai 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Read Kubernetes Up and Running (O'Reilly) : architecture K8s, Pods, Services, Volumes, Deployments, RBAC | Done | 3h30 |
| Read Docker Up and Running (O'Reilly) : images, layers, multi-stage builds, registry, best practices | Done | 2h30 |
| Read articles : Alloy vs Promtail migration, Loki label-based indexing, Parquet columnar format internals | Done | 2h |
| **Subtotal** |    | 8h |

---

*Dimanche 17 mai 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Create `docs/report/bibliography.bib` for Zotero : convert all 16 sources from bibliography.yaml to BibTeX | Done | 45min |
| Complete DCGM section in état de l'art : DaemonSet per GPU node, 4 metrics table (util%, VRAM MB, power W, temp °C), headless service scraping | Done | 2h |
| Complete "cycle de vie d'un log" in état de l'art : 4-step pipeline (stdout → Alloy → Loki → MinIO) + Fletcher diagram | Done | 1h30 |
| Add Elasticsearch exclusion paragraph in état de l'art : inverted index overhead, 3-node minimum HA, mismatch with log use case | Done | 30min |
| Add Parquet columnar format explanation text after parquetFormat.png figure | Done | 20min |
| Add footnotes in état de l'art at first occurrence  | Done | 2h |
| Fix 10 typos in état de l'art (stockées, permettant, visualisations, nœuds, statut, horaire, filtrant, DaemonSet, etc.) | Done | 20min |
| Complete Infrastructure Kubernetes section in architecture : control plane + 3 worker nodes, two scheduling exceptions (Ray nodeAffinity + Prometheus/Grafana nodeSelector) | Done | 1h |
| Complete RayCluster section in architecture : Batch/Solo drivers, Control Plane (GCS + Raylet), Plasma Object Store, nodeAffinity YAML, credentials injection YAML | Done | 2h |
| Add footnotes in architecture : nodeAffinity, SIGTERM, Snappy, Plasma Object Store, sérialisation, désérialisation | Done | 55min |
| Add more footnotes in implementation  | Done | 1h |
| Fix Promtail --> Alloy in implementation | Done | 25min |
| Add skeleton to résultats chapter : 5 sections + subsections (throughput, segmentation quality, resource utilization, Label Studio, API) | Done | 30min |
| Fix footnote entry spacing and bottom page margin in tb_rapport.typ | Done | 30min |
| Style rapport intermédiaire notice as amber warning block in config.typ | Done | 20min |
| Update journal de travail table | Done | 10min |
| Git commit | Done | 15min |
| **Subtotal** |    | 14h30 |
| **Total** |    | **22h30** |

# Week 14

*Friday May 22, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Fix iict-rad kubeconfig, renew Rancher token, merge homelab + iict-rad (multiple attempts) | Done | 45min |
| RayCluster fix, apply manifests, debug workers, confirm 3 GPUs running and active | Done | 45min |
| Debug Grafana logs, port-forward Loki, verify labels, raw pod queries, confirmed Loki receives all pods | Done | 1h |
| LogQL exploration, trial and error with sum_over_time, last_over_time, unwrap, regexp, Stat panel configuration | Done | 2h |
| Run pipeline 3 GPU workers (L40S × 2, A40 × 1), 40 images, 2224 detections, 8.9s/image wall clock | Done | 20min |
| NearAI Grafana home dashboard, HEIG-VD logo, Loki/Prometheus stats, last runs panel, no default Grafana content | Done | 1h |
| Review intermediate report with Remy | Done | 30min |
| Read Kubernetes Up and Running (O'Reilly), continued | Done | 2h10 |
| Architecture chapter, Observability section | Done | 1h30 |
| Journal, notes week 14, dashboard screenshot | Done | 30min |
| Git commits | Done | 15min |
| **Total** | | **9h45** |

# Week 15

*Friday May 29, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Architecture chapter, Cache SAM3 section, RWX PVC design, Longhorn NFS rationale | Done | 1h30 |
| HuggingFace PVC setup, pvc-hf-cache.yaml, storageclass-rwx.yaml, volumeMount in rayCluster.yaml | Done | 1h15 |
| Debug Multi-Attach PVC error on multi-node workers, Longhorn RWX research, storageclass-rwx.yaml drafted for Mehdi | Done | 1h |
| Make tile size configurable, --tile_size, --tile_stride CLI args in pipeline, SAM3Worker params | Done | 30min |
| API REST design, FastAPI, kubernetes-client pattern, K8s Job submission rationale | Done | 1h45 |
| Architecture chapter, API REST section, 5-endpoint table, column proportions fix | Done | 1h |
| Architecture chapter, Stratégie de tuilage section, SAM3 internal 1024x1024 resize, downsampling implications | Done | 1h |
| Table styling, blue header with white text, alternating gray/white rows on all 3 tables in architecture | Done | 45min |
| Footnotes cleanup architecture.typ, remove 5 pure definitions, rewrite disk-pressure/SIGTERM as constraint | Done | 45min |
| Footnotes cleanup implementation.typ, remove 7 pure definitions, rewrite 4 as constraints (CUDA_VISIBLE_DEVICES, ttlSecondsAfterFinished, emptyDir/Memory, hostIPC) | Done | 1h |
| Footnotes cleanup etat-de-lart.typ, remove 20 pure definitions, rewrite inotify and headless service as constraints | Done | 1h45 |
| Add Polling to glossary in tb_rapport.typ | Done | 15min |
| Journal, notes week 15, git commits | Done | 30min |
| **Total** | | **13h** |

# Week 16

*Friday June 6, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Apply HuggingFace PVC (longhorn-rwx), verify Bound RWX, confirm multi-node mount works | Done | 30min |
| Update ghcr-secret on cluster (kubectl create --dry-run apply) | Done | 15min |
| Debug RayCluster connection error, confirm head Running, driver job connecting | Done | 45min |
| Debug pending worker (Insufficient GPU), identify other namespace squatting GPU on iict-suchet | Done | 30min |
| API structure design : api/main.py + jobs/solo/ + jobs/batch/ separation | Done | 30min |
| Learn FastAPI : First Steps, Request Body, Pydantic BaseModel, HTTPException | Done | 1h |
| api/main.py : FastAPI app, env vars, BatchRequest/SoloRequest models, kubernetes client setup | Done | 1h30 |
| buildJob function : V1EnvVar, V1Container, V1Job, V1JobSpec, V1PodSpec | Done | 1h30 |
| submitSolo endpoint : uuid name generation, argList construction, buildJob call | Done | 45min |
| deploy/jobs/solo/main.py : skeleton, s3Client, getImage, patchPosition, getPatches, mergeMasks, maskToPolygon, toLabelStudio | Done | 1h30 |
| deploy/jobs/solo/Dockerfile : nvidia/cuda base, PyTorch CUDA 12.6, SAM3 clone, requirements.txt | Done | 30min |
| Test API with Bruno : POST /jobs/solo, confirm Job created on cluster (ImagePullBackOff expected) | Done | 15min |
| Journal, notes week 16, git commits | Done | 30min |
| Updated Architecure part of the report | Done | 1h20 |
| **Total** | | **11h20** |
