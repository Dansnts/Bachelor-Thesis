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

# Week 17

*Friday June 12, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Complete SAM3Worker actor in solo/main.py : __init__ (model/transform/postprocessor), _make_datapoint, batched inference loop | Done | 1h30 |
| Verify SAM3 API signatures from source + clean up solo/main.py (logging, argparse in main, constants, dead code removal) | Done | 45min |
| Multi-stage Docker build for solo, fix typos, requirements cleanup (python-dotenv, drop exif/pyarrow, ray[default]) | Done | 45min |
| API Dockerfile : remove baked .env (secret leak), fix --no-cache-dir, add non-root user | Done | 20min |
| Build + push sam3-solo:staging and sam3-api:staging to ghcr | Done | 30min |
| API K8s manifests : ServiceAccount, Role, RoleBinding, Deployment, Service, Ingress | Done | 30min |
| Deploy + debug : RoleBinding apply order, python-dotenv crash, stale :latest job, GPU scheduling (scale Ray workers to 0 via JSON patch) | Done | 1h |
| buildJob GPU resources + runtimeClassName, validate solo job end-to-end (15 sign detections) | Done | 30min |
| get_job + get_result endpoints : read_namespaced_job (jobs/status RBAC fix), pod-log bytes bug (_preload_content) | Done | 45min |
| Result persistence on S3 : solo uploads results/<job>.json, get_result reads S3, boto3 + minio-secret in API | Done | 45min |
| SAM3 visual prompt research (PVS vs PCS), source + web verification | Done | 30min |
| Interactive segmentation service (deploy/segment) : FastAPI lifespan + Ultralytics, Dockerfile, manifests, gated weights hf_hub_download fix | Done | 1h30 |
| Multi-point support (list of items) + API gateway (/segment proxy, segment service internal) | Done | 30min |
| docs/API.md usage guide, report placeholders (architecture + implementation), notes week 15-17 | Done | 30min |
| Email to professor | Done | 10min |
| **Total** | | **10h30** |

# Week 18

*Monday June 15, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| submitBatch endpoint : CPU-only Ray driver, distribute S3 prefix over num_workers GPU actors | Done | 1h30 |
| buildJob refactor : parametrize command/gpu/accessKeyEnv (CPU batch driver vs GPU solo pod) | Done | 1h |
| Extract jobCore shared library : dedup solo/batch (s3, tiling, postprocess, worker), reconcile AWS env var names | Done | 2h30 |
| toS3Uri helper + fix batch NoSuchBucket (s3:// prefix parsing stripped "data/") | Done | 30min |
| Debug stuck Ray workers : FailedMount NFS on iict-chasseron (no nfs-common), remove hf-cache RWX mount | Done | 1h |
| Run full batch pipeline on cluster : 14207 Vevey images, ~18h wall, 4.6s/image, 2 L4 GPUs | Done | 15min |
| Debug Ray Client ConnectionAbortedError (SpecificServer fork), confirm transient | Done | 1h30min |
| Fix image references (rayCluster worker, BATCH_IMAGE, driver) -> ray-sam3:staging | Done | 15min |
| Report fix : SAM3 VRAM 2.4 --> 3.8 GB (measured on loaded worker) | Done | 30min |
| Analyse log filtering on Grafana stack : Alloy (Promtail successor) vs Logstash, stage.drop placement | Done | 1h |
| Meeting with Bertil | Done | 30min |
| **Subtotal** |    | 10h30 |

---

*Tuesday June 16, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Finish API : resubmit batch with full s3:// URIs, validate end-to-end on Samples | Done | 1h |
| jobCore : snake_case (PEP8) across all modules | Done | 1h |
| jobCore : rename patch --> tile (tiling + worker) | Done | 30min |
| jobCore : comment tiling/postprocess modules (module docstrings + rationale, the > 127 rebinarization) | Done | 1h |
| jobCore : rename package sam3core --> jobCore, consolidate duplicated dirs, update imports + Dockerfiles | Done | 1h |
| Diagnose Loki not persisting logs : flush 400 errors, root cause HTTP --> HTTPS to MinIO TLS endpoint | Done | 1h30 |
| Fix Loki S3 storage : dedicated bucket nearai-logs, 30-day retention + compactor, emptyDir --> PVC Longhorn + fsGroup | Done | 1h30 |
| Verify S3 round-trip (push/flush/read) + Grafana read path via Loki | Done | 30min |
| Identify /health log source (sam3-segment ingress healthcheck), node vs pod IP/ports clarification | Done | 30min |
| Journal week 18 | Done | 30min |
| **Subtotal** |    | 9h |

---

*Wednesday June 17, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Segment scale-to-zero : /segment/up + /segment/down endpoints, scaleSegment via patch_namespaced_deployment_scale | Done | 2h |
| RBAC deployments/scale (get+patch) + segment Deployment replicas: 0 by default | Done | 30min |
| Design decision : Job-per-request vs KEDA vs manual up/down, settle on manual scaling (cold start unavoidable, no cluster admin) | Done | 1h30 |
| .env consolidation to single root file + .env.example, fix BATCH_IMAGE/SOLO_IMAGE defaults (:staging) | Done | 1h |
| Build + smoke-test sam3-api:staging (kubeconfig COPY workaround, verify all routes register) | Done | 2h |
| Push sam3-api + sam3-segment images to ghcr | Done | 30min |
| Report : Build multi-stage + Conteneurs non-root sections | Done | 1h30 |
| Report : Solo/Batch correction, Sérialisation des inférences, Pourquoi pas KEDA, KEDA glossary entry | Done | 2h |
| extract.py cleanup (formatting, imports) | Done | 30min |
| **Subtotal** |    | 11h30 |

---

*Thursday June 18, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Report architecture : fill TODOs (NFS prereq, jobs orchestration, RBAC/ServiceAccount, result retrieval, PVS vs PCS, hot-model + scale-to-zero, Ultralytics) | Done | 2h |
| Report implementation : fill TODOs (buildJob, S3 result retrieval, Kubernetes client frictions) | Done | 1h |
| Report architecture : env vars section (+ table) and secrets sections (Gestion des secrets, SOPS, K8s python) | Done | 1h30 |
| SOPS setup : install sops/age, age key, .sops.yaml, encrypt minio/hf/ghcr secrets, README, gitignore, round-trip tests | Done | 5h |
| Report : state of the art on secret management (SOPS/age) + bibliography entries | Done | 1h30 |
| Deploy SOPS secrets to cluster + debug ghcr ImagePullBackOff 403 (placeholder creds) | Done | 1h |

| Tiling : explanation, review tiling image + fix legend, drop duplicate section in report | Done | 1h15 |
| Glossary entries (KEDA, PVC, NFS) | Done | 15min |
| Git : organize thematic commits (batch, SOPS, .env.example, report x5) + untrack .DS_Store | Done | 30min |
| Journal week 18 | Done | 15min |
| **Subtotal** |    | 14h15 |

---

*Friday June 19, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Configure 6 fine-grained labels in Label Studio (replacing the 2 generic classes) | Done | 1h |
| Launch + monitor HSN production run (~21k images) | Done | 2h |
| Report Résultats : write full chapter from benchmark data (tiling 512/1024, downsampling, scalability, L40S vs A40, observability), TODO placeholders for pending measurements | Done | 4h30 |
| Cross-chapter coverage audit (state of the art / architecture / implementation) + add missing symmetry titles (Ultralytics, Observabilité) | Done | 2h |
| Verify report compiles end to end | Done | 15min |
| Review remaining budget / weekly pace vs deadline | Done | 30min |
| Journal week 18 | Done | 25min |
| **Subtotal** |    | 10h40 |

---

*Saturday June 20, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Analyze + verify Vevey production run results (21 819 images, 6 labels, 34h17) | Done | 3h |
| Report Résultats : fill Vevey run section with final numbers | Done | 1h |
| **Subtotal** |    | 4h |
| **Total** |    | **59h55** |

---

# Week 19
*Monday June 22, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Batch progress counter : per-image counter + "Progress: X %" logs + S3 status file + /jobs/{name}/status endpoint | Done | 2h |
| Live elapsed time in /status : driver writes started_at, API recomputes elapsed on each read, Cache-Control no-store | Done | 1h |
| Structured API logging : logfmt format, per-request middleware (method/path/status/duration), per-endpoint domain logs | Done | 1h30 |
| Tests : unit tests on write_status + endpoints, end-to-end validation on cluster | Done | 1h |
| Docker : build + push 4 images, tag convention (staging + short sha) | Done | 1h30 |
| Diagnose + fix stale Ray cluster (sam3core -> jobCore module mismatch), restart cluster | Done | 1h |
| Refactor deploy/ to English + snake_case (functions, variables, comments, logs ; Pydantic API fields kept camelCase) | Done | 2h |
| Deploy + validate on cluster (rollout sam3-api, restart Ray pods, GPU contention) | Done | 30min |
| **Subtotal** |    | 10h30 |

---

*Tuesday June 23, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Downsampling feature : add `downsample` parameter across the pipeline (worker, solo, batch, API) | Done | 2h |
| Report Résultats : design OFAT benchmark plan + placeholder tables (tile size, downsampling, label granularity, batch scalability) | Done | 1h30 |
| Meeting with Bertil | Done | 30min |
| L40S vs A40 : read both NVIDIA datasheets, write spec comparison table + analysis (measured 1.45x vs theoretical BF16 2.42x), add bibliography entries | Done | 1h15 |
| Report Résultats : rework Vevey table into 2/3/6 label comparison + linear-with-labels analysis | Done | 30min |
| Benchmark dataset prep : sample 40 random Vevey images (seed 42) + copy to dedicated S3 prefix | Done | 45min |
| dataset_info.txt : aggregate EXIF metadata (camera, resolution, GPS coverage) into a summary at the results root | Done | 1h15 |
| Logs : silence InsecureRequestWarning + per-percent progress, document in report | Done | 45min |
| Fix Dockerfile COPY paths after deploy/ reorg (api, batch, solo) | Done | 30min |
| Kustomize : per-component + root kustomization + deploy.sh for one-shot deploy | Done | 1h30 |
| SOPS age key fix + GPU reservation email | Done | 20min |
| Git : clean + commit deploy YAML manifest reorg (kustomize, drop legacy paths) | Done | 1h |
| Journal week 19 | Done | 15min |
| **Subtotal** |    | 11h20 |

---

*Wednesday June 24, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| API endpoints : implement GET /health (k8s liveness probe) + GET /jobs/ (list batch/solo jobs, kind filter) | Done | 45min |
| Deduplicate segment <--> jobCore : import shared mask_to_polygon / make_s3_client, switch segment Docker build context to deploy/ | Done | 45min |
| Section headers + section ordering across all deploy/ Python files to match the API layout | Done | 45min |
| /import endpoint : convert Parquet predictions to Label Studio import payload (+ pyarrow in API image) | Done | 1h |
| Local smoke tests : 8 module imports + pure-logic helpers (tiling, EXIF, dataset_info, LS conversion) | Done | 30min |
| Docker : build + push 4 images, fix userdel UID 1000 conflict on Ubuntu 24 base image | Done | 1h |
| Redeploy + diagnose/fix node DiskPressure eviction storm  | Done | 1h |
| /import scalability rework after OOM/504 on 14k files : streaming response + parallel reads + multipart S3 write + bump API memory 256->512Mi | Done | 1h30 |
| Rebuild/redeploy API + validate /import on Vevey 14k (147 MB JSON written to MinIO, bounded memory) | Done | 45min |
| Full API test campaign + small batch run : validate downsampling, dataset_info, /status, segment scaling | Done | 1h |
| Fix RBAC Role (live missing deployments/scale -> /segment 403) | Done | 15min |
| Investigate Ray actor INFO logging gap + note | Done | 30min |
| Journal | Done | 15min |
| **Subtotal** |    | 10h |

---

*Thursday June 25, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Plan the day + audit report for gaps (read all chapters, list missing/placeholder sections) | Done | 1h |
| État de l'art : write Ultralytics section + bibliography entry | Done | 1h30 |
| Implementation : write Ultralytics section (segment service, SAM() loading, .pt weights, mask --> polygon) | Done | 1h |
| Architecture : fix Ultralytics paragraph (point-only prompt, not box) + reword .pt loading line | Done | 45min |
| Report journal : extend journal-de-travail.typ to weeks 12-19 from journal.md (split merged week 12/13, per-category hour breakdown), uncomment include | Done | 2h30 |
| Verify solo/batch/segment write behavior in code + fix report (solo conditional on --result_key, segment never writes, fix flag name) | Done | 1h |
| Outils utilisés : write full tool inventory chapter (8 grouped tables) + uncomment include | Done | 2h |
| Cross-chapter consistency pass (segmentation, Ultralytics, job outputs) | Done | 45min |
| Code walkthrough + clarifications (K8s client frictions, .pt format, model lifecycle, Ultralytics role) | Done | 1h15 |
| Git + deploy help (untrack Docker/, segment kubectl apply -k) | Done | 15min |
| **Subtotal** |    | 12h |

---

*Friday June 26, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Meeting with Bertil | Done | 20min |
| Ray actor logging fix : diagnose basicConfig no-op under Ray, configure jobCore logger (StreamHandler, propagate=False) | Done | 1h30 |
| Add missing worker logs : load config (tile/stride/downsample) + load time, tile count, inference time, polygons per label, GPU node | Done | (inclus) |
| Build + push ray-sam3 + sam3-solo images (log fix) | Done | 30min |
| Restart Ray workers one by one to pick up new image (+ scale segment to 0) | Done | 30min |
| App labels : add `app` to build_job pod template + rayCluster head/worker templates (Loki filtering) | Done | 30min |
| Build + push sam3-api + rollout deployment + apply rayCluster manifest | Done | 45min |
| Validate on real batch run : confirm all new jobCore logs + `app=sam3-batch` label on driver pod | Done | 1h |
| Report : section Logs via Python (structured API logs + Ray actor capture) | Done | 1h |
| Report : Observabilité (3 sub-sections : stack deploy, DCGM, Grafana dashboard) | Done | 1h30 |
| Report : Infrastructure Générale + CI/CD sections (architecture) | Done | 1h |
| Notes week 18/20 cleanup | Done | 30min |
| Review report edits + explanations (K8s frictions, Ultralytics, CLI scope) | Done | 1h30 |
| Journal | Done | 15min |
| **Subtotal** |    | 10h50 |
| **Total** |    | **54h40** |

# Week 20

*Monday June 29, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Try to validate segment end-to-end (blocked : no GPU schedulable, segment Pending) | Done | 30min |
| CLI v1 : write `cli/nearai.py` (push, batch, solo, status, result, jobs, import, segment up/down) | Done | 2h30 |
| CLI : end-to-end test against live API (push to S3, batch, status, jobs, import, segment) + clean error handling | Done | 1h30 |
| Grafana : add panels exploiting the new logs (inference time, tiles/image, model load, API requests/errors) | Done | 1h |
| Grafana : refactor into 3 dashboards by concern (general, batch, gpuMetrics) | Done | 1h30 |
| Grafana : fix broken queries (sam3-driver -> app=sam3-batch selector, range -> instant queryType) | Done | 1h |
| Grafana : GitOps provisioning (configMapGenerator, dashboards provider, deployment mounts) + debug RWO PVC / configmap hash / kustomize security | Done | 2h |
| Grafana : polish (textMode value, dashlist search, remove logo, kustomization filename sync) | Done | 30min |
| Notes : park the Parquet score/label analysis idea (bonus) | Done | 15min |
| Journal | Done | 15min |
| **Subtotal** |    | 11h |
| **Total** |    | **11h** |

*Tuesday June 30, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| SAM3 tile-size investigation : 512/644/672/1024 crash (RoPE `freqs_cis` fixed for the 1008 grid), only 1008 works — confirmed empirically + web research | Done | 1h |
| Fix `worker.py` : resize every tile to 1008 before inference (keep `original_size` for mask remap) → tile size is a free parameter again | Done | 1h |
| Pin GPU jobs (solo + segment) to suchet/node4 via `nodeAffinity` (avoid chasseron) | Done | 30min |
| GitHub Actions workflow to build/push images to ghcr (dynamic matrix, registry cache) + debug | Done | 1h30 |
| Expose SAM3 confidence score in solo output + worker log | Done | 30min |
| Bruno : generate the 10 benchmark request files + clean up the off-plan ones | Done | 30min |
| Run the 10 solo benchmarks (tile × downsample grid + labels), collect tiles/time/polygons/score, track in `notes.md` | Done | 2h |
| Report : restructure `resultats.typ` (grid + labels tables filled), document the SAM3 1008 constraint in implementation, fix compile | Done | 1h30 |
| Notes / journal / todo | Done | 30min |
| **Subtotal** |    | 9h |
| **Total** |    | **9h** |

*Wednesday July 1, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Bruno : generate the 4 batch scalability request files (1008/504 × 1/3 workers, downsample 0,5) | Done | 30min |
| Run the 4 batch scalability benchmarks, verify per-worker distribution + 3-GPU usage, fill the table in `notes.md` | Done | 2h |
| Debug GPU placement (a worker landed on chasseron) → hard-pin the Ray workers to suchet/node4 in `rayCluster.yaml`, recreate workers | Done | 1h30 |
| Report : fill `@tab-batch-scaling` (1008 & 504), fix captions, place the DCGM GPU-usage figure | Done | 1h |
| Bruno : production Vevey request files (3 labels + 6-label precise on 1 GPU), choose the downsample 0,75 sweet-spot | Done | 1h |
| Launch the production run + monitoring | Done | 30min |
| Bump job TTL to 48h (live patch + API `build_job`) so finished pods keep their logs | Done | 30min |
| Bottleneck investigation : MinIO/Synology metrics (`mc admin`), live trace → pipeline is GPU-bound, storage idle at this scale | Done | 1h30 |
| Report : write the `== Goulots d'étranglement` section (GPU-bound measured, MinIO latent, per-stage synthesis table) | Done | 2h |
| Notes / journal / memory | Done | 30min |
| **Subtotal** |    | 11h |
| **Total** |    | **11h** |

*Thursday July 2, 2026*

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Report Résultats : calculated justification of the 768 stride (overlap trade-off + `@tab-stride` cost table, 32/55/105 tiles) | Done | 1h30 |
| Report Résultats : label-granularity analysis (3 vs 6, detection redistribution, `road_marking` vs `road_mark`, `arrow_marking` absent) | Done | 1h30 |
| Report Résultats : segmentation quality — manhole misses on dark concrete (discussion with Valentin), `sam3BadView` figure | Done | 1h |
| Report Résultats : tile × downsampling comparison figure (lilaq, 504 vs 1008 polygon count) | Done | 45min |
| Label Studio : import Parquet pre-annotations, manually correct polygons, capture screenshots (`outputManualyFixed`) | Done | 3h |
| Report Résultats : "Exemples visuels dans Label Studio" section (import + manual-fix figures) | Done | 30min |
| Report Architecture : rework PVS/PCS, scale-to-zero and Ultralytics sections | Done | 1h30 |
| Throughput/latency analysis for the report (aggregate vs per-worker, per-tile solo vs batch) | Done | 1h |
| Planning : define API edge-case test campaign + `09_Pipeline_result` output reorg | Done | 45min |
| Notes / journal | Done | 30min |
| **Subtotal** |    | 12h |
| **Total** |    | **12h** |
