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
