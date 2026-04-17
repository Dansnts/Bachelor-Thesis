# Week 1

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

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Debug and fix SAM3 pipeline on cluster (OOM, libGL, numpy conflict, Ray address) | Done | 2h |
| Optimise pipeline : batch processing, polygon extraction in worker, timing instrumentation | Done | 1h |
| Configure nodeAffinity on workers and job pod (L40S, A40, disk-pressure exclusion) | Done | 30min |
| Benchmark 512x512 vs 1024x1024 tiles on cluster, analyse GPU scheduling constraints | Done | 1h |
| **Total** |    | 4h30 |

---

# Week 7

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Research downsampling strategies : analyse trade-offs between resolution reduction and segmentation quality | Done | 1h |
| Implement downsampling preprocessing in sam3_pipeline.py : resize image before tiling, parametrise scale factor | Done | 1h30 |
| Build test Docker images for local downsampling experiments | Done | 45min |
| Run SAM3 pipeline locally : validate downsampling at multiple scale factors | Done | 2h |
| Analyse results : compare polygon count and inference time vs full-resolution baseline | Done | 45min |
| Reorganise project structure : consolidate all docs under docs/ (Specification, report), remove legacy folders (TB_CahierDesCharges_Typst, specifications, report, tools) | Done | 1h |
| **Total** |    | 7h |

---

# Week 8

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Analyse Loki and observalibity stack | Done | 4h |
| **Total** |    | 4h |

---

# Week 9

| Task              | Status | Time |
| :---------------- | :------: | ----: |
| Workstation data loss, recovery and environment rebuild | Done | 45min |
| Re-read project state : pipeline architecture, benchmarks, open decisions | Done | 1h45 |
| Study K8s vs RayCluster network abstraction : GCS address, service ports, client protocol | Done | 1h |
| Verify GPU Operator installation on iict-rad cluster (confirmed via IICT wiki) | Done | 30min |
| Analyse cost : rented GPUs (H100, Replicate) vs on-premise cluster | Done | 1h |
| Meeting with Bertil       |   Done   | 25min |
| Design pipeline architecture diagram (K8s cluster, Ray workers, MinIO, job-solo/batch flows) | Done | 1h30 |
| Debug RayCluster : head not ready, 3rd worker pending (insufficient GPU) | Done | 30min |
| Contact Shancli (SAM3 optimised image) and Olivier Lemer (GPU availability) | Done | 45min |
| **Total** |    | 7h45 |