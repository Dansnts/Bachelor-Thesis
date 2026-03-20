# Week 1

## K8s
- 4x GPUs available for compute
- Ray runs on HEIG's K8s cluster

## Storage
- Data stored on HEIG's S3 local buckets
- Label Studio data stored as JSON files, pictures stored on MinIO in the NearAI folder

## AI
- SAM3 (Meta) — segmentation model

## Data
- Downsampling: reduce image size, use polygons instead of hand-drawn labels
- Label Studio handles annotation, MinIO handles image storage

---

# Week 2

## Completed
- S3 alternatives to MinIO
- Spark vs Ray vs ZARR
- Read 3 redaction documents
- PostGIS
- HEIG cluster overview

## S3

S3 is a protocol, not a single product.

### CEPH
Mature open-source storage (LGPL). Supports block, file, and object (S3). Complex to set up. Relevant if a CEPH cluster already exists.

### RustFS
Similar to MinIO, Apache 2.0 license. S3-only focus. Streamlined migration from MinIO or CEPH. Project is young (<1 year) but already 22k stars on GitHub.

## Image Processing

### Ray
Parallelizes Python workloads across CPUs and GPUs. Better suited than Spark for AI inference: Spark targets structured data (Hadoop heritage), Ray targets GPU-heavy ML tasks with PyTorch.

### ZARR
N-dimensional array format. Reads data by chunks (tiles) instead of loading the full image. Efficient with Ray: workers read only needed tiles.

```
[PNG/TIFF sources]
       ↓
  ZARR conversion (one-time pre-processing)
       ↓
  Storage on S3
       ↓
  Ray workers → read chunks → run SAM3 → write labels
```

### MPS (Multi-Process Service)
NVIDIA feature allowing multiple CUDA processes to share one GPU. The HEIG-VD cluster uses MPS on node4 (2x A40, each split into 2 logical GPUs).

### PostGIS
PostgreSQL extension for geospatial data:

```sql
CREATE TABLE annotations (
    geom GEOMETRY(POLYGON, 4326)  -- SRID 4326 = WGS84
);
CREATE INDEX ON annotations USING GIST(geom);
```

Supports `POINT`, `POLYGON`, `MULTIPOLYGON`. GIST index enables fast spatial queries.

**Decision: dropped in favour of Parquet on S3.**

---

# Week 3

## Meeting notes
- MinIO runs on a Synology NAS → evaluate migration to RustFS
- Add observability and logging to the pipeline
- Plan a user entry point (interface or API)
- Focus on data: batch approach first

## Scenarios

### Scenario A — Batch
- User provides ~2000 images
- SAM3 runs in batch via Ray
- Results stored as Parquet on S3
- No database required
- Reference: https://docs.ray.io/en/latest/data/data.html

### Scenario B — On-demand
- User submits one image → near-real-time response
- Pipeline triggered on the fly
- Results stored on S3

## Open questions
- Is a database necessary, or does Parquet on S3 cover both scenarios?
- Final output format for annotations?

---

# Week 4

## K8s commands

```bash
# Merge kubeconfig files
KUBECONFIG=conf.yaml:iict-rad.yaml kubectl config view --flatten > config-finale.yaml

# Start k9s on a specific context
k9s --context=iict-rad

# List pods in namespace dani
kubectl get pods -n dani --context=iict-rad
```

## Synology NAS

- Capacity: 45/80 TB used
- Network: 1 Gb/s
- Hardware: Synology SA3200D (2 controllers, HA)
- CPU/RAM usage: low

**Decision: keep MinIO.** Migration adds risk and delay. The pipeline builds on S3 — swapping storage later means changing only the endpoint config.

MinIO on Synology is installed via Container Manager. Base image: `minio/minio`. To confirm with Mehdi.

## Tasks
- Build base structure, add bonus tasks after
- Both scenarios A and B, plus an observability/metrics layer
- Use Ray libraries to write results as Parquet
- Reference: [Google MapReduce paper](https://static.googleusercontent.com/media/research.google.com/en//archive/mapreduce-osdi04.pdf)

## Ray & Anyscale

Ray is an open-source Python framework for distributing AI/ML workloads across CPUs and GPUs.
Anyscale is the commercial platform built by the Ray founders — managed, production-ready Ray.

### Ray primitives

```python
# @ray.remote : declares the function as executable on a worker
# .remote()   : submits the task (non-blocking)
# ray.get()   : waits for and retrieves results

@ray.remote
def apply_reduce(*buckets):
    counts = {}
    for bucket in buckets:
        for word, count in bucket:
            counts[word] = counts.get(word, 0) + count
    return counts

reduce_results = [
    apply_reduce.remote(*[map_results[m][p] for m in range(NUM_PARTITIONS)])
    for p in range(NUM_PARTITIONS)
]
```

### Ray Actor

Use an Actor when a model must be loaded once and reused across many tasks. Loading a model per task causes OOM.

```python
@ray.remote(num_gpus=1)
class Classifier:
    def __init__(self):
        self.model = load_model()  # loaded once

    def classify(self, image):
        return self.model(image)   # called N times
```

### RayCluster on K8s

KubeRay (`rayclusters.ray.io`) is the proper operator. Access requires a `RoleBinding` on API group `ray.io`. Request sent to IICT admin.

**Temporary workaround:** 1 head pod + 3 worker pods (Deployment).

### Ray connection

| Method | Result |
|---|---|
| `ray.init(address="host:6379")` | Pod becomes worker → crashes (no local raylet) |
| `ray.init("ray://host:10001")` | Correct: Ray Client protocol |

`--ray-client-server-port=10001` must be set in the head `ray start` command.

### Exposing ports — Ingress

Per IICT documentation, services are exposed via Ingress (wildcard `*.iict-rad.iict-heig-vd.in`):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ray-dashboard-ingress
  namespace: dani
spec:
  rules:
    - host: ray-dashboard.iict-rad.iict-heig-vd.in
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ray-head-svc
                port:
                  number: 8265
```

## Results

### Wordcount
Tasks distributed across all 3 workers and completed correctly.

![Wordcount workers](images/wordcountWorkers.png)

### Dog classifier — 5000 images (EfficientNet B0 on Stanford Dogs)

```
[4600/5000] traités
[4700/5000] traités
[4800/5000] traités
[4900/5000] traités
[5000/5000] traités

Top 10 premières images :
  Image 01 : Doberman                      (87.21%)
  Image 02 : African hunting dog           (83.32%)
  Image 03 : pug                           (55.45%)
  Image 04 : Weimaraner                    (82.86%)
  Image 05 : Mexican hairless              (75.63%)
  Image 06 : flat-coated retriever         (92.52%)
  Image 07 : dhole                         (97.87%)
  Image 08 : Shetland sheepdog             (80.94%)
  Image 09 : briard                        (71.99%)
  Image 10 : West Highland white terrier   (91.55%)

[SUCCES] 5000 images classifiées.
```

![Dog classifier workers](images/dogClassifierWorkers.png)
