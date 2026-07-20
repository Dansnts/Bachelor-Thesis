# Week 1

## K8s
- 4x GPUs available for compute
- Ray runs on HEIG's K8s cluster

## Storage
- Data stored on HEIG's S3 local buckets
- Label Studio data stored as JSON files, pictures stored on MinIO in the NearAI folder

## AI
- SAM3 (Meta) : segmentation model

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

### Scenario A Batch
- User provides ~2000 images
- SAM3 runs in batch via Ray
- Results stored as Parquet on S3
- No database required
- Reference: https://docs.ray.io/en/latest/data/data.htmlT folder (copy of templat

### Scenario B On-demand
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

**Decision: keep MinIO.** Migration adds risk and delay. The pipeline builds on S3 swapping storage later means changing only the endpoint config.

MinIO on Synology is installed via Container Manager. Base image: `minio/minio`. To confirm with Mehdi.

## Tasks
- Build base structure, add bonus tasks after
- Both scenarios A and B, plus an observability/metrics layer
- Use Ray libraries to write results as Parquet
- Reference: [Google MapReduce paper](https://static.googleusercontent.com/media/research.google.com/en//archive/mapreduce-osdi04.pdf)

## Ray & Anyscale

Ray is an open-source Python framework for distributing AI/ML workloads across CPUs and GPUs.
Anyscale is the commercial platform built by the Ray founders managed, production-ready Ray.

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

### Exposing ports Ingress

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

### Dog classifier 5000 images (EfficientNet B0 on Stanford Dogs)

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

## Week 5




### Parquet

Parquet is a binary columnar file format designed for analytical workloads on large datasets. Unlike a relational database, there is no loading phase, files are queried directly from the data lake (MinIO in our case).

**Internal structure:**

```
Parquet file
└── Row Group 1          < horizontal split of rows
│   ├── Column Chunk A   < all values for column A in this group
│   │   ├── Page 1
│   │   └── Page 2
│   └── Column Chunk B
└── Row Group 2
    └── ...
```

Each column chunk is stored and compressed independently. This means reading only the columns you need. For exemple filtering polygons by confidence score without loading GPS coordinates.

Workers write results in parallel. each Ray worker produces one or more row groups. Queries on the output (filter by GPS zone, score threshold) only scan relevant columns. No database to maintain all our files sit on MinIO, PyArrow reads them directly.

Parquet stores min/max statistics per column chunk. A query engine can skip entire row groups without reading them if the predicate falls outside the range. This is called **predicate pushdown** and is supported natively by PyArrow and DuckDB.

Reference: Alice Rey, *Bridging the Gap between Data Lakes and RDBMSs*, EDBT/ICDT Workshop 2024.

### Promtail

Promtail is the log shipping agent for Loki. It runs as a DaemonSet (one instance per K8s node) and collects logs from all pods running on that node.

Promtail discovers pods via the K8s API (service discovery) then it reads log files from `/var/log/pods/` on the node si it cab attaches labels extracted from pod metadata: `namespace`, `pod`, `container`. Finnaly it ships log streams to Loki's Distributor via POST.

```
K8s Node
|-- ray-worker-0  |
|-- ray-worker-1  |──> Promtail ──> Loki Distributor ──> Ingester ──<> MinIO
|-- ray-worker-2  |
```

Each log line reaches Loki with labels like:

```
{namespace="dani", pod="ray-worker-abc", container="ray-worker"}
```

In our pipeline, Promtail captures stdout/stderr from Ray workers automatically. No code change required and the workers just print to stdout and Promtail picks it up.

### DCGM Exporter

It's simply a tool to export GPUs metrics. Which is very important in our case to monitor our pipeline. Protheus will scrap them via his HTTP endpoint then Grafana will simply read them.

```
K8s Node
|-- GPU A1  |
|-- GPU A2  |──> Prometheus ──> Grafana
|-- GPU A3  |
```

---

# Week 6

## SAM3 Pipeline : Benchmark

All runs on a single image (4096×8192 px, 2.8 MB JPEG), 3 Ray workers on L40S and A40.

### Run A : 512×512 tiles

| Metric | Value |
|--------|-------|
| Tiles | 128 |
| Workers | 3 (2× L40S on suchet, 1× A40 on node4) |
| Worker init (cold) | ~71s |
| Worker init (cached) | ~19s |
| Inference time/tile : L40S | ~2.0s |
| Inference time/tile : A40 | ~2.5s |
| Inference time/tile : avg | 2.00s |
| Total inference | 111.4s |
| Polygons extracted | 146 |
| **Total wall time** | **~1m50s** |

### Run B : 1024×1024 tiles

| Metric | Value |
|--------|-------|
| Tiles | 32 |
| Workers | 3 (2× L40S on suchet, 1× A40 on node4) |
| Inference time/tile : L40S | ~6.4s |
| Inference time/tile : A40 | ~9.3s |
| Inference time/tile : avg | 7.41s |
| Total inference | 103.3s |
| Polygons extracted | 49 |
| **Total wall time** | **~1m43s** |

### Analysis

Larger tiles yield no meaningful time reduction (~8s gain) but cut polygon count by 3x. The total inference time is dominated by SAM3 itself, not by tile count. 512×512 tiles are retained for better segmentation quality.

The L40S/A40 gap is visible: L40S processes a 1024-tile in 6.4s vs 9.3s on A40, a 1.45× ratio consistent with their FP16 tensor performance difference.

At 3 workers and ~111s per image, processing 2000 images would take ~62 hours and 1000 of them will do more than a day.

### GPU scheduling constraints

The HEIG-VD cluster exposes 9 GPUs across three nodes:

| Node | GPUs | Model | VRAM |
|------|------|-------|------|
| iict-suchet | 3 | NVIDIA L40S | 46 GB |
| iict-k8s-node4-rad | 2 | NVIDIA A40 | 46 GB |
| iict-chasseron | 4 | NVIDIA L4 | 23 GB |

During testing, only 3 workers could be scheduled (2 on suchet, 1 on node4). The remaining GPUs were occupied by other namespaces... The scheduler reported `Insufficient nvidia.com/gpu` on suchet and node4 for additional workers.

Chasseron was excluded for two reasons.
- First, its L4 GPUs offer lower compute than L40S and A40.
- Second, the node carried a `node.kubernetes.io/disk-pressure` taint during testing, which prevents pod scheduling and would have caused SIGTERM evictions at runtime.

The disk-pressure taint is applied automatically by K8s when a node's disk usage crosses a threshold. Any workload scheduled on such a node risks eviction without warning. The pipeline must treat this taint as a hard exclusion.

The `nodeAffinity` on worker pods targets L40S and A40 exclusively. The job driver pod doesn't requires GPU and runs without affinity constraints, relying on K8s to place it on a healthy node.


### Conclusion

Two paths exist to bring the batch duration under 24 hours.

The first is downsampling: reducing image resolution before tiling cuts tile count and inference time proportionally, at the cost of segmentation detail. This is acceptable if the target annotations do not require sub-pixel precision.

The second is accepting 1024x1024 tiles. With 32 tiles per image and ~7.4s per tile across 3 workers, inference per image drops to ~80s. At 2000 images that gives 44 hours : still over a day, but the polygon count drops from 146 to 49 per image, which reduces storage and Label Studio import volume.

The preferred approach is downsampling combined with 512×512 tiles. It preserves segmentation quality and keeps the pipeline architecture unchanged.

---

# Week 7

## Downsampling

Downsampling reduces image resolution before tiling. A scale factor of 0.5 halves both width and height, reducing tile count by 4× and inference time proportionally. The trade-off is segmentation detail: smaller input means SAM3 sees less edge information per tile.

Three scale factors were tested locally (Proxmox, GTX 970) at fixed tile size 512×512:

| Scale | Tiles (4096×8192 image) | Relative inference time |
|-------|------------------------|-------------------------|
| 1.0 (baseline) | 128 | 1.0× |
| 0.75 | 72 | ~0.56× |
| 0.5 | 32 | ~0.25× |
| 0.25 | 8 | ~0.06× |

Scale 0.5 is retained as the default. It cuts inference time by ~4× while preserving enough detail for the target annotation quality. Scale 0.25 is too aggressive: SAM3 loses fine contours on objects smaller than ~50px in the downsampled image.

---

# Week 8

### Loki

Loki is a log aggregation system that only indexes metadata labels, not the full log content. This makes it lightweight compared to Elasticsearch which is useful in our case because we don't need full-text search, we need to find logs from a specific Ray worker pod at a specific time.

It stores data in S3 format. Loki has 2 main storage types: index and chunks.

- **Index**: table of contents, maps label sets to chunk locations.
- **Chunks**: compressed blocks of raw log lines for a given label set and time range.

![Loki index/chunks](./images/lokiChunksIndex.png)

Logs are queried with **LogQL**, a label-based query language:

```logql
{namespace="dani", pod=~"ray-worker.*"} |= "ERROR"
```

In our pipeline, Promtail runs as a DaemonSet and ships all pod logs to Loki. Loki stores them on MinIO woth no extra storage infrastructure needed. Grafana queries Loki alongside Prometheus, which allows correlating a GPU spike on a graph with the corresponding worker logs.

---

# Week 9

## Architecture Diagram

![Kubernetes Architecture](diagrams/Schema-Kubernetes.png)

## K8s vs RayCluster

Kubernetes and RayCluster use overlapping but distinct terminology. A K8s Service exposes pods via a stable DNS name and load-balances across them. A RayCluster head node is exposed as a K8s Service, but Ray has its own internal GCS (Global Control Store) address that workers connect to not the K8s service port directly.

| Term | K8s meaning | Ray meaning |
|------|-------------|-------------|
| Head | N/A | Single node running GCS, scheduler, dashboard |
| Worker | Pod in a Deployment | Ray node registered with GCS, executes tasks |
| Service | Stable ClusterIP for pod selection | Exposes GCS (6379), dashboard (8265), client (10001) |
| Namespace | Logical cluster isolation | Shared across all Ray nodes in a cluster |

Ray workers do not connect to a K8s Service they connect to the GCS address published by the head node on startup. The Ray Client (external driver) connects via `ray://host:10001`.

## GPU Operator

The NVIDIA GPU Operator automates the installation of GPU drivers, the device plugin, and DCGM Exporter on each node. Without it, pods requesting `nvidia.com/gpu` resources will not be scheduled.

Confirmed via IICT wiki : the GPU Operator is installed on the iict-rad cluster (K8s 1.32.5). GPUs are shared across namespaces using MPS (Multi-Process Service). No action needed `nvidia.com/gpu` resource requests work out of the box.

Reference: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/overview.html

## SAM3 Performance Reference

Rémy reported that Shancli's optimised SAM3 backend processed the Neuchâtel dataset (~11 000 images) in 7–8 hours.

| Pipeline | Time/image | Total (11k images) |
|----------|-----------|---------------------|
| Shancli (optimised) | ~2.5s | ~7.5h |
| Ours (3 workers, 512×512 tiles) | ~111s | ~340h |

The 44× gap suggests Shancli's image likely has the model pre-loaded and optimised (TensorRT, quantization, or a custom inference backend). Pending his response on which base image to use adopting it could bring our pipeline close to his throughput.

## Cost Analysis : Rented GPUs vs On-Premise

At ~111s per image with 3 workers, processing 2000 images takes ~62 hours on the HEIG-VD cluster. The cluster is shared and GPU availability is not guaranteed.

Rented GPU services (Replicate, RunPod, Lambda Labs) offer H100 instances at 2–4\$/hour per GPU. A 3-GPU run of 62 hours would cost 370-750$ acceptable for a one-off batch but not for repeated runs.

**Decision: stay on-premise.** The HEIG-VD cluster is free for the project and sufficient for the target batch size. Downsampling at 0.5 reduces the 62h estimate to ~15h. Rented GPUs remain an option if cluster access becomes a bottleneck during full-scale testing.

## Tests on Hold

Since almost all the GPUs are being already used by others pods, I'm just gonna delay the Parquet files for now.

# Week 10

## Pipeline SAM3 → Parquet → Label Studio : end-to-end run

This week the full pipeline ran on the cluster for the first time and produced its first real output visible in Label Studio.

### Output format change : JSON → Parquet

The pipeline previously wrote one LabelStudio JSON file per image. Per the cahier des charges (section 6.4), the output was switched to Parquet stored on MinIO. Each row in the Parquet file represents one detected polygon:

| Column | Type | Description |
|--------|------|-------------|
| `image_key` | string | S3 object path |
| `acquisition_id` | string | Parent folder name |
| `label` | string | `sign` or `road_marking` |
| `score` | float32 | SAM3 confidence score |
| `points` | string | JSON-encoded polygon points (% of image dimensions) |
| `original_width` | int32 | Source image width |
| `original_height` | int32 | Source image height |
| `latitude` | float64 | GPS decimal degrees from EXIF |
| `longitude` | float64 | GPS decimal degrees from EXIF |

GPS coordinates are extracted from image EXIF using the `exif` library. DMS (degrees/minutes/seconds) are converted to decimal degrees. Images without GPS data store `null`.

Files are named `<acquisition_id>/<image_stem>.parquet` and written to the output S3 prefix with Snappy compression.

### Docker image

`Dockerfile.sam3` updated: added `pyarrow` to the pip install layer and fixed the `COPY` directive to copy `sam3_minio_pipeline.py`. Image pushed to `ghcr.io/nearai-interreg/ray-sam3:latest`.

### HuggingFace model cache (PVC)

SAM3 weights are 3.3 GB. Without a persistent cache every pod restart re-downloaded the model (~5 min overhead). A Longhorn PVC (`hf-cache`, 10 Gi, `ReadWriteOnce`) mounts at `/root/.cache/huggingface` on the worker pod. After the first run the weights are cached and subsequent runs skip the download.

### CUDA visibility bug (local mode)

In local Ray mode (`--local`), the Actor was created with `.options(num_gpus=0)` to skip GPU allocation. This had a side effect: Ray hid all CUDA devices from the process (`CUDA_VISIBLE_DEVICES=""`), causing `RuntimeError: No CUDA GPUs are available` even though the pod had a GPU.

Fix: removed the `.options()` override. The `@ray.remote(num_gpus=1)` decorator handles allocation in both modes.

### Ray worker environment variables

Ray workers run in separate pods. They do not inherit environment variables from the driver job. MinIO credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT_URL`) were missing from the worker spec, causing `NoCredentialsError` on every S3 call made inside an Actor.

Fix: credentials added to `workerGroupSpecs[].template.spec.containers[].env` in `rayCluster.yaml`.

### Cluster run results

40 images processed across 2 Ray workers (3rd GPU occupied by another namespace). The autoscaler reported "max number of worker nodes reached" and stayed at 2.

```
Done: 40 images, 2230 detections avg ~111s/image
```

Parquet files written to `s3://nearai/dani/test/predictions/`.

### Label Studio integration

Label Studio was connected to MinIO as an S3 cloud storage source:

- **Endpoint**: `https://storage-kubernetes.iict-heig-vd.in:9000`
- **Bucket**: `nearai`
- **Region**: `ch` (MinIO rejects `us-east-1`)
- Pre-signed URLs enabled so images are served directly from MinIO to the browser.

The Parquet output was converted to Label Studio import format for one sample image and imported manually. The labeling interface XML:

```xml
<View>
  <Image name="image" value="$image"/>
  <PolygonLabels name="label" toName="image">
    <Label value="sign" background="#FF0000"/>
    <Label value="road_marking" background="#FFFF00"/>
  </PolygonLabels>
</View>
```

The `from_name` field in result items must match the `name` attribute of `<PolygonLabels>` in the XML (`label`). The original JSON used `tag` which caused polygons to render grey without labels.

### Equirectangular projection distortion

The pipeline tiles the equirectangular panorama directly without any projection correction. Those images have increasing geometric distortion toward the top (zenith) and bottom (nadir) poles.

**Decision: no correction implemented.** The target we are using now in the tests are classes like `sign` (road signs, mostly at horizon level) and `road_marking` (ground markings, visible in the lower-middle band). Both appear in the central vertical band (roughly 25–80% of image height), which corresponds to more or less than 30° elevation precisely where equirectangular distortion is weakest. The top of the image is sky and rooftops. The very bottom is occluded by the vehicle body.

A projection correction like : equirectangular → rectilinear perspective patches via `py360convert` or `equilib`, then reproject polygon coordinates back, would add implementation complexity for marginal gain on these two classes. Noted as a known limitation and potential future improvement in the report. But we have now a few ideas to test during our benchmarks sessions.

### First output in Label Studio

![First SAM3 output in Label Studio](images/firstOutputLabelStudio.png)

Red polygons: `sign`. Yellow polygons: `road_marking`. 78 detections on a single panoramic image (4096×8192 px).

## Ray worker inheritance

Workers don't inherit env vars from the driver. Any secret needed inside an Actor (S3 credentials, HF token) must be set explicitly in the worker pod spec via `secretKeyRef` in `rayCluster.yaml`.

## GPU affinity

Worker pods use `nodeAffinity` to prefer L40S (weight 100) over A40 (weight 50). The `runtimeClassName: nvidia` is required on the worker pod spec for the GPU device plugin to expose `nvidia.com/gpu`. The driver job has no GPU and runs without affinity constraints.

## API

REST API (HTTP/JSON), framework-agnostic. Likely implemented with FastAPI + Ray Serve. Valentin can consume these endpoints from any client (web app, Label Studio plugin, CLI).

Three endpoints cover the two usage scenarios from the cahier des charges (Scenario A: batch, Scenario B: on-demand).

### `POST /batch`

Asynchronous. The client submits a set of images and gets back a `job_id` immediately. Processing happens in the background on the Ray cluster.

**Request body:**
```json
{
  "s3_input_uri": "s3://nearai/data/acquisitions/Samples/01_images/",
  "s3_output_uri": "s3://nearai/dani/predictions/",
  "labels": ["sign", "road_marking"],
  "batch_size": 4
}
```

**Response `202 Accepted`:**
```json
{
  "job_id": "a3f2c1d9",
  "status": "queued",
  "submitted_at": "2026-04-24T10:32:00Z"
}
```

The `job_id` is used to poll progress via `/status`.

---

### `GET /status/{job_id}`

Synchronous. Returns the current state of a batch job. Valentin can poll this endpoint to update a progress bar or notify the user when processing is complete.

**Response `200 OK`:**
```json
{
  "job_id": "a3f2c1d9",
  "status": "running",
  "images_total": 40,
  "images_done": 17,
  "detections_so_far": 923,
  "started_at": "2026-04-24T10:32:05Z",
  "estimated_remaining_s": 1340
}
```

Possible values for `status`: `queued`, `running`, `done`, `failed`.

When `status` is `done`, the Parquet files are available at `s3_output_uri`.

---

### `POST /predict`

Synchronous. Single-image on-demand prediction. Blocks until SAM3 returns results (typically 30–120 s depending on GPU availability). Intended for interactive use from Label Studio or a lightweight UI.

**Request body:**
```json
{
  "s3_image_uri": "s3://nearai/data/acquisitions/Samples/01_images/20251210-NeoCapture-bis_S001_Trimblemx50_000001.jpg",
  "labels": ["sign", "road_marking"]
}
```

**Response `200 OK`:**
```json
{
  "image_key": "data/acquisitions/Samples/01_images/20251210-NeoCapture-bis_S001_Trimblemx50_000001.jpg",
  "original_width": 8192,
  "original_height": 4096,
  "latitude": 46.9213,
  "longitude": 6.9021,
  "detections": [
    {
      "label": "sign",
      "score": 0.91,
      "points": [[42.05, 40.72], [42.08, 44.97], ["..."]]
    }
  ]
}
```

Points are in percent of image dimensions, matching the Label Studio polygon format directly.

# Week 11

## Observability stack

This week the full observability stack was deployed on the cluster. Two independent metric flows converge in Grafana.

```
Ray workers (stdout) → Promtail → Loki → Grafana
Ray head :8080       → Prometheus → Grafana
DCGM Exporter        → Prometheus → Grafana  (pending network policy from IICT)
```

### GPU tools : MPS, GPU Operator, DCGM Exporter

Three tools handle GPU monitoring and sharing on the cluster. None are deprecated as of 2026.

**GPU Operator** : installed by IICT on iict-rad. Automates driver installation, the device plugin, and DCGM Exporter on each node. Pods requesting `nvidia.com/gpu` work out of the box.

**DCGM Exporter** : Nvidia Data Center GPU Manager. Runs as a DaemonSet (1 pod per GPU node). Reads GPU metrics directly from the NVIDIA driver via its own library. Exposes them on `:9400/metrics` for Prometheus to scrape. Two interfaces:
- `dcgmi` : CLI for per-GPU health and performance monitoring
- DCGM Exporter : cluster-level Prometheus endpoint

**MPS (Multi-Process Service)** : used by IICT to share GPUs between pods. Not deprecated, marked experimental in k8s-device-plugin v0.15. Cannot be used with MIG-enabled devices.

### Metrics flow

![](diagrams/Schema-Observability.png)

Grafana centralises everything. The key value is correlation : a GPU spike visible in Prometheus at a given timestamp can be matched with the corresponding Ray worker logs in Loki at the exact same moment.

### Promtail deployment issues

Promtail was deployed as a DaemonSet (1 pod per node). Two issues appeared on `iict-suchet` (main GPU node, 3× L40S).

**Issue 1 : RBAC** : the manifest used `ClusterRole` + `ClusterRoleBinding`, which requires cluster-admin. Fixed by switching to `Role` + `RoleBinding` (namespace-scoped). Sufficient since we filter to namespace `dani`.

**Issue 2 : too many open files** : Promtail uses inotify to watch log files. iict-suchet runs many workloads and the default inotify limits were exhausted. Fixed with a privileged `initContainer` that runs before Promtail starts:

```yaml
initContainers:
  - name: increase-inotify-limits
    image: busybox
    command: ['sh', '-c', 'sysctl -w fs.inotify.max_user_watches=524288 && sysctl -w fs.inotify.max_user_instances=512']
    securityContext:
      privileged: true
```

Both `max_user_watches` (number of files watched) and `max_user_instances` (number of inotify instances) must be increased. Setting only one is not sufficient.

### Loki storage on MinIO

Loki stores logs in two parts on MinIO under `nearai/dani/loki/`:
- **index** : maps label sets to chunk locations
- **chunks** : compressed blocks of raw log lines


### DCGM network policy

Prometheus cannot scrape DCGM Exporter because a network policy blocks cross-namespace traffic. A mail was sent to Mehdi (IICT admin) with the following NetworkPolicy to apply:


### Ray metrics in Prometheus

Ray head exposes metrics on port 8080. The scrape works : confirmed via `ray_running_jobs` and `ray_gcs_actors_count` visible in Prometheus. Port 8080 does not need to be declared in the RayCluster containerPorts (declaring it caused KubeRay to fail creating pods due to internal port conflict).

## Pipeline run on 20250521-HSN dataset

2000 images processed on 2 GPU workers (3rd occupied).

**Timing bug identified and fixed** : `total_time` in the pipeline was the sum of all worker times, not wall clock time. With 2 workers each processing ~1000 images at 8s, the sum was 16 000s, reported as 8s/image average. The actual wall clock time was ~4s/image (16 000s / 2 workers / 2000 images). Fix: track wall time separately and report both metrics.

**Worker eviction on iict-chasseron** : a worker scheduled on chasseron (L4, disk-pressure taint) was evicted mid-run via SIGTERM. Fixed by adding a hard `NotIn` nodeAffinity to exclude chasseron from worker scheduling:

```yaml
- key: kubernetes.io/hostname
  operator: NotIn
  values:
    - iict-chasseron
```

## Dynamic work queue (test4)

The original pipeline used round-robin assignment (`i % num_workers`) : slow images block a worker slot. A new version in `tests/RAY/test4/sam3_pipeline_dynamic.py` uses `ray.wait()` for dynamic load balancing: each worker pulls the next image as soon as it finishes, no idle waiting. Version created by AI.

```python
done, _ = ray.wait(list(future_to_worker.keys()), num_returns=1)
# assign next image to the now-free worker immediately
```

The dynamic version also logs per-image breakdown: `download / inference / upload` to identify the real bottleneck.

## API : label classes

Bertil suggested using classes instead of flat string arrays for labels, to give a black-box effect to the user and allow richer descriptions:

```python
[
  {"name": "stopSign",  "description": "A circular red panel with the mention 'Stop' inside"},
  {"name": "roadSign",  "description": "A white or yellow mark, usually rectangular or triangular, marked on roads"}
]
```

# Week 12

## DCGM Exporter network access

Mehdi created a NetworkPolicy allowing the `dani` namespace to reach DCGM Exporter in the `gpu-operator` namespace. Initial endpoint: `nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400`.

Problem: a ClusterIP returns a single pod in round-robin, so Prometheus could only scrape one GPU node. Mehdi created a **headless service** `nvidia-dcgm-exporter-headless.gpu-operator.svc.cluster.local` that exposes all DCGM pod IPs as DNS A records. Prometheus uses `dns_sd_configs` to scrape each node individually.

```yaml
- job_name: dcgm-exporter
  dns_sd_configs:
    - names:
        - "nvidia-dcgm-exporter-headless.gpu-operator.svc.cluster.local"
      type: A
      port: 9400
```

## GPU monitoring script

`tests/gpu.py` queries the Prometheus API and prints GPU metrics in real time:

```
=== DCGM_FI_DEV_GPU_UTIL ===
  iict-suchet   gpu0  NVIDIA L40S    87.0 %
  iict-chasseron gpu2  NVIDIA L4     45.0 %
```

Metrics tracked: `DCGM_FI_DEV_GPU_UTIL` (%), `DCGM_FI_DEV_FB_USED` (MB), `DCGM_FI_DEV_POWER_USAGE` (W), `DCGM_FI_DEV_GPU_TEMP` (°C).

Reading: 0% utilisation with VRAM > 0 MB and power > 17 W means the model is loaded in memory and the Ray worker is active but not currently running inference.

## Prometheus and Grafana PVC storage on Longhorn

Added Longhorn PVCs for Prometheus (`50Gi`) and Grafana (`2Gi`) to persist data across pod restarts.

**Issue**: Longhorn scheduled pods on `iict-k8s-node4-rad` by default, but that node has ghost block devices that block ext4 formatting (`mke2fs: device apparently in use`). Fix: `nodeSelector: kubernetes.io/hostname: iict-suchet` on both deployments.

**Grafana permissions**: Grafana runs as user 472; the PVC is mounted without the correct ownership by default. Fix: `securityContext: fsGroup: 472, runAsUser: 472`.

## Alloy replaces Promtail

Promtail is EOL (maintenance-only since 2024). Alloy is its official successor from Grafana.

Migration deployed in `deploy/observability/alloy/`. Advantages:

- `loki.source.kubernetes` reads logs through the K8s API directly, no node filesystem mount needed
- A single `Deployment` pod instead of a `DaemonSet`
- No inotify limit issues
- Configuration in River language (HCL-inspired), components wired together explicitly

```alloy
discovery.kubernetes "pods" { role = "pod" }
loki.source.kubernetes "pods" {
  targets    = discovery.kubernetes.pods.targets
  forward_to = [loki.write.loki.receiver]
}
loki.write "loki" {
  endpoint { url = "http://loki-svc.dani.svc.cluster.local:3100/loki/api/v1/push" }
}
```

## Grafana dashboard

Dashboard `deploy/observability/grafana/dashboard-tb.json` with 7 panels:

![Grafana dashboard](images/dashboard.png)

- **Gauge**: instantaneous GPU utilisation per node (green/orange/red)
- **Timeseries**: GPU util (%), VRAM (MB), power (W), temperature (°C)
- **Stat**: running Ray jobs, active Ray actors
- **Variable** `hostname_filter`: textbox at the top, filters all panels by regex on hostname. Empty = show all. Clicking a gauge auto-fills the filter for that node.

# Week 14

## kubeconfig merge

Rancher token expires periodically. To renew without losing other contexts:

```bash
# New file FIRST — flatten keeps first occurrence of duplicate entries
KUBECONFIG=~/Downloads/iict-rad.yaml:~/.kube/config kubectl config view --flatten > /tmp/merged.yaml && mv /tmp/merged.yaml ~/.kube/config
```

If homelab config is a separate file (`~/.kube/homelab`), include it explicitly:

```bash
KUBECONFIG=~/Downloads/iict-rad.yaml:~/.kube/homelab kubectl config view --flatten > ~/.kube/config
```

## kubectl apply on subdirectories

`kubectl apply -f dir/` does not recurse. Use `-R`:

```bash
kubectl --context iict-rad apply -Rf deploy/observability/ --validate=false
```

Note: `-fR` is invalid (`-f` takes an argument). `-Rf` works.

## Loki : logs confirmed working

All pods in namespace `dani` indexed by Alloy via `loki.source.kubernetes`. Labels available: `pod`, `container`, `namespace`, `app`.

Query all pods:
```logql
{namespace="dani"}
```

SAM3 Actor stdout is forwarded to the driver pod stdout (Ray behavior). Driver pods (`sam3-driver-*`) contain both autoscaler messages and SAM3Worker inference lines.

Filter noise:
```logql
{pod=~"sam3-driver-.+"} != "urllib3" != "InsecureRequest" != "warnings.warn"
```

## LogQL metric extraction

Extract numeric values from log lines with `regexp` + `unwrap`:

```logql
# Total images processed in 30 days
sum(sum_over_time(
  {pod=~"sam3-driver-.+"} |= "Done"
  | regexp `Done: (?P<images>\d+) images`
  | unwrap images [30d]
))

# Mean s/image across all runs
avg_over_time(
  {pod=~"sam3-driver-.+"} |= "Wall time"
  | regexp `Wall time\s*:\s*\d+s \((?P<secs_per_image>[\d.]+)s/image\)`
  | unwrap secs_per_image [30d]
)
```

Key rules:
- `=` : exact match on label, `=~` : regex match
- `|=` : line contains substring, `!=` : line does not contain
- `unwrap` : convert extracted string field to float for metric queries
- `sum_over_time` : sum all occurrences in window → use for totals
- `last_over_time` : last value in window → use for latest run value
- Stat panel Calculation = `Last *` to show single value, not sum of all steps

## Run — 2026-05-22

3 workers GPU (2× L40S iict-suchet + 1× A40 iict-k8s-node4-rad), 40 images, 2224 détections, **8.9s/image** wall clock, GPU peak 300W, VRAM 8GB, température max 75°C.

Screenshot: `docs/images/dashboard.png`

# Week 15

## Longhorn RWX cache (model weights)

SAM3 weights (3.3 GB) are pulled from HuggingFace Hub on the first model load. Without a shared cache every pod re-downloads them. The cache PVC mounts at `/root/.cache/huggingface`; HuggingFace checks that directory before any network call.

### RWO vs RWX

The first cache PVC was `ReadWriteOnce`: mountable by one node at a time. As soon as workers were scheduled on two nodes (`iict-suchet` + `iict-k8s-node4-rad`), the worker on the second node stayed `Pending` with a multi-attach error. `ReadWriteMany` (RWX) allows simultaneous mounts from multiple nodes — required for a cache shared across workers (and later the solo/segment pods).

### Longhorn RWX = NFS share-manager

Longhorn implements RWX through a **share-manager** pod that re-exports the volume over **NFS**. So an RWX PVC is, under the hood, an NFS share. Mehdi created a `longhorn-rwx` StorageClass for it.

`migratable: "false"` in the StorageClass is **correct** for RWX/share-manager volumes. `migratable: "true"` only concerns VM live-migration (KubeVirt block volumes), not filesystem RWX.

### Node prerequisite : nfs-common

Mounting RWX/NFS requires the NFS client (`mount.nfs`, package `nfs-common`) **on each node**. `iict-chasseron` lacks it → any pod mounting the RWX PVC there fails:

```
mount: ... bad option; for several filesystems (e.g. nfs, cifs) you might need a /sbin/mount.<type> helper program.
```

`iict-k8s-node4-rad` has it (workers mounted fine). Lesson: **an RWX StorageClass is not enough** — it imposes node homogeneity (NFS client everywhere). A pod without node affinity can land on an incompatible node and fail to mount. Reported to Mehdi to install `nfs-common` cluster-wide.

---

# Week 16

Python libraries used to glue the pipeline together — connection/import patterns.

## SAM3 (facebookresearch)

The model is *built*, not just loaded:

```python
from sam3 import build_sam3_image_model
model = build_sam3_image_model(device="cuda", eval_mode=True, load_from_HF=True,
                               enable_segmentation=True, enable_inst_interactivity=True)
```

`load_from_HF=True` pulls the gated weights from HF (needs `HF_TOKEN` + approved access; `huggingface_hub.login(token=...)` before building).

Two companion objects, both *constructed* (no weights):
- `transform = ComposeAPI([ToTensorAPI(), NormalizeAPI(mean=[.5]*3, std=[.5]*3)])` — PIL → normalized tensor. SAM3 operates on a `Datapoint` (image + text queries), not a raw PIL image.
- `postprocessor = PostProcessImage(iou_type="segm", detection_threshold=0.5, max_dets_per_img=-1, ...)` — decodes raw logits into masks + scores. `iou_type="segm"` is mandatory to get masks; `max_dets_per_img` has no default (must pass `-1`).

Lesson: **the installed source is the source of truth, not the README.** The README does not list `build_sam3_image_model`'s kwargs; the code does (`sam3/model_builder.py`). Signatures were verified directly instead of trusting docs/memory.

`_make_datapoint` wraps a patch + text labels into `FindQueryLoaded` objects. The same struct also carries `input_bbox`/`input_points` → SAM3 supports **visual prompts** (points/boxes) on top of text.

## boto3 (MinIO / S3)

```python
boto3.session.Session().client(
    "s3", endpoint_url=os.getenv("S3_ENDPOINT_URL"),
    aws_access_key_id=os.getenv("AWS_ACCESS_KEY"),
    aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
    config=Config(connect_timeout=5, read_timeout=10, retries={"max_attempts": 1}),
    verify=False)
```

- `verify=False` — MinIO uses a self-signed cert internally → TLS verification off (warns `InsecureRequestWarning`, expected).
- Custom env name `AWS_ACCESS_KEY` (not the standard `AWS_ACCESS_KEY_ID`) — works since it is read explicitly, but it diverges from the Ray pipeline (`AWS_ACCESS_KEY_ID`). To reconcile before the batch job.
- `get_object(Bucket, Key)["Body"].read()` → bytes ; `put_object(Bucket, Key, Body=..., ContentType=...)` to write.
- A missing key raises `client.exceptions.NoSuchKey`.

## kubernetes (python client)

```python
try: config.load_incluster_config()      # in-cluster: pod ServiceAccount token
except config.ConfigException: config.load_kube_config()   # local: ~/.kube/config
batch_v1 = client.BatchV1Api()
core_v1  = client.CoreV1Api()
```

- V1-prefixed classes map 1:1 to YAML: `V1Job > V1JobSpec > V1PodTemplateSpec > V1PodSpec > V1Container`. Env via `V1EnvVar` + `V1EnvVarSource(secret_key_ref=V1SecretKeySelector(...))`.
- The Job is built dynamically (params change per request) — impossible with a static YAML.
- `client.ApiException` carries `.status` and `.reason` → relayed as HTTP errors.

Two real frictions:
- `read_namespaced_job_status` hits the **`jobs/status` subresource** — a distinct RBAC resource from `jobs`. The Role granted only `jobs` → `403 Forbidden`. Fix: `read_namespaced_job` (resource `jobs`, returns the full object incl. `.status`).
- `read_namespaced_pod_log` on kubernetes-client 36.x returns `repr(bytes)` (a single line `b'...\n...'` with literal `\n`) instead of decoded text → `splitlines()` sees one line. Fix: `read_namespaced_pod_log(..., _preload_content=False).data.decode("utf-8")`.

---

# Week 17

REST API design and the choices behind it.

## API as a Job orchestrator

FastAPI `Deployment` (no GPU). It does **not** run the model — it creates Kubernetes `Job`s via `buildJob` (dynamic `V1Job`), staying decoupled from the RayCluster state.

- `POST /jobs/solo` → one image, self-contained job (`ray.init()` local, single GPU), writes result to S3.
- `POST /jobs/batch` → planned: connects to the RayCluster (still a stub).
- `GET /jobs/{name}` → status (Succeeded / Failed / Active / Pending).
- `GET /jobs/{name}/result` → reads the result from S3.
- `POST /segment` → proxy to the interactive service (see below).

The Job container needs `resources.limits["nvidia.com/gpu"]=1` + `runtimeClassName: nvidia`, otherwise the `@ray.remote(num_gpus=1)` actor never schedules (no GPU visible) and the job hangs.

## RBAC (least privilege)

A pod uses the `default` SA (no rights) unless told otherwise. Created `ServiceAccount sam3-api` + `Role` (jobs create/get/list/watch/delete ; pods + pods/log get) + `RoleBinding`. Creating a Job from the API needs these rights; without them → 403.

## Result persistence : S3 (not SQLite, not logs)

- **logs** (stdout → `kubectl logs`): ephemeral, gone after the Job TTL (1 h), fragile parsing (the client bytes bug).
- **SQLite**: bad fit — the job runs in a separate pod; sharing a SQLite file needs an RWX/NFS volume (the Week-15 NFS problem) and SQLite over NFS corrupts (POSIX locking) + single-writer contention.
- **S3** (chosen): the solo job uploads `results/<job>.json`; `get_result` reads it back. Durable, survives the TTL, distributed-friendly, consistent with the batch (Parquet on S3). The API gained boto3 + `minio-secret`.

## Interactive segmentation (visual prompt)

New requirement: give a point + a label, get the object's polygon back.

- **PVS vs PCS** — SAM3 has two prompt families. **PCS** (text/exemplar) = *what* → finds all instances of a concept (the batch/solo path). **PVS** (point/box) = *where* → outlines the object at that spot, **class-agnostic** (no type). Verified in source (`predict()` returns masks + IoU, no label) and online (PCS = concept specified by the prompt). A point alone cannot "guess" a type; the label is provided by the caller and only tags the output.
- **Warm service, not a Job** — interactive use needs a hot model (sub-second). A Job per request = cold start (pull image + load model = minutes), unusable. Built `sam3-segment`: a GPU `Deployment` (1 replica) loading the model once (FastAPI `lifespan`), holding 1 GPU permanently, with a tolerant `startupProbe`.
- **Ultralytics** instead of the facebookresearch pipeline: `model.predict(points=, labels=)` in 2 lines vs the full `_make_datapoint`/collate/postprocessor. But SAM3 weights are **gated**: `SAM("sam3.pt")` does not auto-download. Fix: `hf_hub_download(repo_id="facebook/sam3", filename="sam3.pt", token=HF_TOKEN)` at startup (point prompts don't need the BPE vocab — that's text-only).

## API gateway

Instead of exposing `sam3-segment` publicly, the main API **proxies** `/segment` to the internal service (`http://sam3-segment:8000`). One entry point, the GPU service stays internal (ClusterIP, no Ingress), one place for future auth.

## Container choices

- **Multi-stage build** (builder CUDA-devel → runtime): copy only `/opt/venv` into the final image. Gotcha: the venv symlinks the system python → reinstall `python3.12` in the runtime stage. Trade-off devel↔runtime (Triton JIT may need `ptxas` at runtime).
- **Non-root** (`USER appuser`, `runAsNonRoot`) for the API. The pip root warning is build-time only; the goal is the running process. The `.env` must **not** be baked into the image (secrets would leak into the registry) — config comes from K8s env.

## Open / security

No authentication yet on the API or the segment service. Exposed via Ingress = anyone on the network can consume GPU. Token / API key is a future improvement.


# Week 18

- [X] Ajouter une section d'avancement dans le rapport : comparer l'avancement réel avec ce qui était prévu à l'origine.
- [X] Créer une image expliquant le fonctionnement du découpage en tuiles.
- [X] API : fonctionnelle → y repasser pour un refactor.
- [X] Logs : vérifier qu'ils sont bien enregistrés, puis contrôler la ConfigMap.
- [X] Documenter la section API.

# Week 20

- [ ] Détailler davantage l'implémentation (exemple avec PIL + un schéma).
- [ ] Supprimer les informations en double dans le chapitre Architecture.
- [ ] Revoir si la terminologie Ray ↔ Docker/K8s doit être harmonisée pour faciliter la compréhension des explications.
- [ ] Résultats : écrire la justification du surcoût labels (3→6 = +9 % à 1008 / +17 % à 504 ; cause = encodeur ViT partagé, une passe par tuile, chaque label = une `FindQuery` légère sur les features) **sous la table des labels**, + la nuance solo↔production (vs `@tab-run-vevey` +85 % : sur 21 819 images le coût/label s'accumule alors qu'en solo le coût fixe le masque).
- [ ] Corriger l'État de l'art (`etat-de-lart.typ` l.31) : 1024→1008, 512→504/1008, comptes de tuiles (55 ou 231, pas 128).

## Benchmarks — runs solo (30.06.2026)

Image de référence : `pano_0002_004731.jpg` (8000×4000, 32 MP, Vevey). Labels grossier (3) = `sign, manhole, road_mark` ; précis (6) = `circular_sign, rectangular_sign, circular_manhole_cover, rectangular_drain_grate, road_marking, arrow_marking`. **Temps** = de `Image -> tiles` à `Result written` (wall-clock par image, post-traitement inclus, **hors** chargement modèle ~54 s). Score = confiance SAM3 (0–1).

JSON complet de chaque run : `s3://nearai/results/<job>.json` (colonne *Fichier json*), aussi lisible via `GET /jobs/<job>/result`.

| #  | tuile | ds   | lbl | Début UTC | Tuiles | Temps  | Poly | Détail (par label)           | Score moy [min–max] | Nœud   | Fichier json                |
|----|-------|------|-----|-----------|--------|--------|------|------------------------------|---------------------|--------|-----------------------------|
| 1  | 1008  | 1,0  | 3   | 11:19:18  | 55     | 11,1 s | 29   | sign 15 · manhole 8 · road 6 | 0,691 [0,504–0,911] | suchet | sam3-solo-18119958.json     |
| 2  | 1008  | 0,75 | 3   | 11:21:24  | 32     | 7,8 s  | 29   | sign 14 · manhole 8 · road 7 | 0,689 [0,537–0,887] | suchet | sam3-solo-db5af880.json     |
| 3  | 1008  | 0,5  | 3   | 11:27:02  | 15     | 5,1 s  | 27   | sign 14 · manhole 8 · road 5 | 0,661 [0,508–0,863] | suchet | sam3-solo-933db040.json     |
| 4  | 1008  | 0,25 | 3   | 11:29:07  | 3      | 3,2 s  | 15   | sign 8 · manhole 4 · road 3  | 0,720 [0,513–0,867] | suchet | sam3-solo-67584125.json     |
| 5  | 504   | 1,0  | 3   | 11:30:48  | 231    | 32,7 s | 36   | sign 19 · manhole 10 · road 7 | 0,716 [0,508–0,939] | suchet | sam3-solo-37de905d.json     |
| 6  | 504   | 0,75 | 3   | 11:32:51  | 128    | 18,1 s | 32   | sign 15 · manhole 9 · road 8 | 0,709 [0,516–0,928] | suchet | sam3-solo-820aa651.json     |
| 7  | 504   | 0,5  | 3   | 11:34:42  | 55     | 9,0 s  | 23   | sign 13 · manhole 6 · road 4 | 0,709 [0,520–0,903] | suchet | sam3-solo-67b305cb.json     |
| 8  | 504   | 0,25 | 3   | 11:36:23  | 15     | 4,3 s  | 15   | sign 7 · manhole 4 · road 4  | 0,704 [0,527–0,832] | suchet | sam3-solo-1ba1f931.json     |
| 9  | 1008  | 1,0  | 6   | 11:40:14  | 55     | 12,2 s | 26   | r.sign 6·c.sign 1·road 13·c.mh 4·r.drain 2 (arrow 0) | 0,699 [0,531–0,915] | suchet | sam3-solo-48b9dc7d.json     |
| 10 | 504   | 1,0  | 6   | 11:42:03  | 231    | 39,7 s | 31   | r.sign 10·c.sign 1·road 13·arrow 1·c.mh 5·r.drain 1 | 0,724 [0,504–0,933] | suchet | sam3-solo-83c4f681.json     |

**Solo : 10 runs faits** (grille tuile×downsampling + labels), reportés dans `resultats.typ`.

### Comparaison GPU : A40 vs L40S (solo 504 grossier, 09.07.2026)

Même image de référence, même code, seul le GPU change (OFAT). Les runs L40S sont ceux du tableau ci-dessus (#5–8, sur `suchet`). Les runs A40 tournent tous sur `iict-k8s-node4-rad` (vérifié `-o wide`). Sweep downsampling à tuile 504, 3 labels grossier. **Temps A40 lus dans les logs des pods** (`in X.Xs`).

**Détections identiques L40S↔A40** (mêmes polygones, mêmes scores : 1,0 → 36/0,716 ; 0,5 → 23/0,709 ; 0,25 → 15/0,704) → confirme que le GPU ne change que le temps, pas le résultat (déterminisme).

| tuile | ds   | Tuiles | Temps L40S (réf) | Temps A40 | A40/L40S | Pod / json A40 |
|-------|------|--------|------------------|-----------|----------|----------------|
| 504   | 1,0  | 231    | 32,7 s           | 48,8 s    | 1,49×    | `sam3-solo-752f57a4-7wtdg` (`sam3-solo-752f57a4.json`) |
| 504   | 0,75 | 128    | 18,1 s           | ~28,4 s ⁽¹⁾ | ~1,57× | `sam3-solo-764a9727-p2gkg` (`sam3-solo-764a9727.json`) |
| 504   | 0,5  | 55     | 9,0 s            | 12,1 s    | 1,34×    | `sam3-solo-46b461bc-mn6j6` (`sam3-solo-46b461bc.json`) |
| 504   | 0,25 | 15     | 4,3 s            | 4,4 s     | 1,02×    | `sam3-solo-a3e0f574-bw77c` (`sam3-solo-a3e0f574.json`) |

⁽¹⁾ Le run 0,75 n'a pas émis la ligne de synthèse `in X.Xs` dans son log ; temps reconstruit par timestamps (`Image → 128 tiles` 07:27:18,246 → `Result written` 07:27:46,670 = 28,4 s), donc légèrement surestimé (inclut l'écriture S3).

**Lecture** : le L40S est plus rapide, et son avance **croît avec la charge GPU** — à 231 tuiles il est ~1,5× plus rapide, à 15 tuiles les deux cartes s'égalisent (les coûts fixes dominent, le GPU n'est plus le maillon). Le L40S (Ada, 2022) domine l'A40 (Ampere, 2021) d'autant plus que le travail par image est lourd.

## Benchmarks : runs batch scalabilité (01.07.2026)


| #  | tuile | ds  | workers | Début UTC | Détections | Wall time | s/image | Worker avg | Job                  |
|----|-------|-----|---------|-----------|------------|-----------|---------|------------|----------------------|
| 1  | 1008  | 0,5 | 1       | 08:41:07  | 843        | 185 s     | 4,6 s   | 3,3 s      | sam3-batch-69dc01c1  |
| 2  | 1008  | 0,5 | 3       | 08:54:37  | 843        | 75 s      | 1,9 s   | 3,6 s      | sam3-batch-1df5b8f0  |
| 3  | 504   | 0,5 | 1       | 09:04:22  | 921        | 323 s     | 8,1 s   | 7,6 s      | sam3-batch-f3e11aea  |
| 4  | 504   | 0,5 | 3       | 08:58:20  | 921        | 128 s     | 3,2 s   | 7,9 s      | sam3-batch-b109049b  |

Remplit `@tab-batch-scaling-1024` (runs 1–2) et `@tab-batch-scaling-512` (runs 3–4) dans `resultats.typ`.

**Variance / warmup (important pour l'interprétation)** : les 3 runs 1008/3-workers ont donné 133 s (mixte suchet+chasseron), 110 s (3×suchet à froid), **75 s** (3×suchet à chaud). Sur seulement 40 images, le wall time est dominé par le warmup (téléchargement S3, cache disque, JIT) → un run à chaud vs un baseline à froid **surestime** le speedup. Pour un chiffre honnête, relancer le baseline 1-worker **à chaud** dans les mêmes conditions avant de figer le tableau. Résultat en soi : le batch de bench (40 img) est trop petit pour un throughput stable ; le run de production (21'819 img) amortit tout. La règle « throughput linéaire » ne tient que quand chaque tuile va sur un GPU distinct et que le dataset est assez gros pour saturer les workers.
Placement : les 3 workers Ray sont maintenant hard-pinnés suchet/node4 (chasseron exclu, `rayCluster.yaml`).

### Run de production Vevey (01.07.2026)

Config retenue = **tuile 1008 / downsample 0,75 / 3 workers** (sweet-spot : même qualité que full-res 1,0 pour ~30 % de temps en moins). Dataset complet `data/acquisitions/Vevey/01_images/` (14'207 images, pas 21'819 — à corriger dans le rapport). Sortie parquet par config de labels.

| Labels | Début UTC | Images | Détections | Wall time | s/image | Job |
|--------|-----------|--------|------------|-----------|---------|-----|
| 3 (générique : sign, road_mark, manhole) | 09:40:12 | 14'207 | 397'741 | 29'057 s (≈ 8 h 04) | 2,0 (agrégé 3w) | sam3-batch-22b3c196 |
| 6 (précis) | 07:23 (02.07) | 14'207 | 423'819 | 37'388 s (≈ 10 h 23) | 2,6 (agrégé 3w) | sam3-batch-452ca76a |

Note : ~28 détections/image (3 labels), ~29,8 (6 labels). Les deux runs sont directement comparables (même dataset 14'207 img, même config 1008 / 0,75 / 3× L40S). Passer de 3 à 6 labels (×2) = temps ×1,29 (8h04 → 10h23) : coût fixe ~5h45 (I/O, tuilage, indépendant des labels) + ~46 min/label (une `FindQuery` par label par tuile). `@tab-run-vevey` mis à jour dans le rapport (2 lignes réelles, l'ancienne ligne 2-labels sur 21'819 img / L4 retirée car non comparable). Run 6-labels config confirmée via Loki : labels précis (circular_sign, rectangular_sign, circular_manhole_cover, rectangular_drain_grate, road_marking, arrow_marking), ds 0,75 (8000×4000 → 6000×3000), 32 tuiles/img.

**TTL / pod mort après 1 h** : le job 6-labels a bien été jusqu'au bout (`Done: 14207 images, 423819 detections`), mais son pod a été supprimé **1 h après la fin** par le TTL controller (`ttl=3600s`). Le bump à 48 h (`main.py`) était dans le code mais **l'image API n'a pas été rebuildée/redéployée** → l'API tournante crée encore des jobs avec l'ancien TTL. Résultats récupérés **uniquement depuis Loki** (`{app="sam3-batch"}` / `{pod=~"sam3-batch-452ca76a.*"}`), le pod n'existant plus dans kubectl. → À FAIRE : rebuild + rollout de l'image API pour que le TTL 48 h prenne effet. Illustre à nouveau l'argument observabilité (Loki survit à la suppression du pod).

**Répartition par worker (via Loki, run complet)** : 10.42.17.137 → 4735 img, 10.42.17.153 → 4736 img, 10.42.17.154 → 4736 img (= 14'207, les 3 GPUs de suchet, round-robin quasi parfait à 1/3 chacun). Somme des détections recalculée par Loki = 397'741 (identique au `Done:` → couverture complète).

NB : `kubectl logs` ne gardait que la queue (~2000 img, rotation conteneur), les logs complets sont dans Loki (`loki-svc:3100`, `{pod="sam3-batch-22b3c196-ld8fs"}`) / bucket S3 `nearai-logs` en chunks Snappy pas lisibles au `cat`, seulement via l'API Loki. Bon exemple pour l'argument observabilité de Bertil. 

Note : les images `cc013c` et `d688f2` contiennent **toutes deux** le resize -> 1008 (vérifié empiriquement : un worker `cc013c` traite du 504 sans AssertionError) ; leur seule différence est l'exposition du score côté log/solo, sans impact sur le parquet batch (le score y est écrit depuis le tuple polygon dans les deux). Le run 504/3-workers a fait une 1re tentative en erreur (`ConnectionAbortedError: Starting Ray client server failed`, transitoire côté client Ray) puis a réussi au retry sans rapport avec l'image.

### Scalabilité production : baseline 1 worker (04.07.2026)

Baseline **1 worker** du run 6-labels sur le dataset complet Vevey (mêmes params : tuile 1008 / stride 768 / downsample 0,75 / 6 labels précis, sortie `09_parquet_6labels/`). Sert de référence pour chiffrer le speed-up 1 → 3 workers **sur la prod** (les 40 images du micro-bench étaient trop bruitées par le warmup, cf. plus haut).

| Workers | Début UTC | Images | Détections | Wall time | s/image | Débit | Job |
|---------|-----------|--------|------------|-----------|---------|-------|-----|
| 1 | 21:26 (02.07) | 14'207 | 423'819 | 111'919 s (≈ 31 h 05) | 7,9 | ≈ 457 img/h | sam3-batch-c14b83ac |
| 3 | 07:23 (02.07) | 14'207 | 423'819 | 37'388 s (≈ 10 h 23) | 2,6 | ≈ 1368 img/h | sam3-batch-452ca76a |

**Détections identiques** (423'819) quel que soit le nombre de workers → confirme que le round-robin ne change que le temps, pas le résultat. **Speed-up 1 → 3 = 111'919 / 37'388 = 2,99×** : scaling quasi parfait, bien meilleur que le 2,52× du micro-bench 40 images. Sur un dataset assez gros, le coût fixe (warmup, JIT, cache) est amorti et chaque worker sature son GPU → l'inférence par tuiles est bien *embarrassingly parallel*. Confirme empiriquement la règle « throughput linéaire tant que chaque tuile va sur un GPU distinct et que le dataset sature les workers ».

Remplit `@tab-run-vevey-scaling` dans `resultats.typ`. NB : job `c14b83ac` récupéré vivant dans kubectl (`Complete`, TTL 48 h désormais effectif) — logs et timings lus directement, pas besoin de Loki cette fois.

#### Distribution par label et scores (run 6 labels, agrégé sur les 14'207 parquets)

Agrégat des 423'819 détections directement depuis les parquets de sortie (`09_parquet_6labels/`, lu avec pyarrow). **14'083 images sur 14'207 ont au moins une détection** (124 images vides), soit ≈ 30,1 détections/image (parmi les images non vides).

| Label | Détections | % | Score moy | méd | min | max |
|-------|-----------:|----:|:---------:|:---:|:---:|:---:|
| road_marking            | 249'064 | 58,8 | 0,671 | 0,663 | 0,504 | 0,957 |
| rectangular_sign        |  57'669 | 13,6 | 0,642 | 0,617 | 0,504 | 0,947 |
| circular_manhole_cover  |  46'981 | 11,1 | 0,721 | 0,723 | 0,504 | 0,955 |
| circular_sign           |  38'329 |  9,0 | 0,705 | 0,703 | 0,504 | 0,969 |
| rectangular_drain_grate |  17'157 |  4,0 | 0,715 | 0,711 | 0,504 | 0,961 |
| arrow_marking           |  14'619 |  3,4 | 0,622 | 0,598 | 0,504 | 0,930 |
| **Total** | **423'819** | 100 | **0,676** | 0,664 | 0,504 | 0,969 |

Histogramme des scores (bins de 0,05, seuil de détection SAM3 = 0,5) :

```
0,50–0,55 :  63'102  14,9%  ######################################################
0,55–0,60 :  69'676  16,4%  ############################################################
0,60–0,65 :  62'462  14,7%  #####################################################
0,65–0,70 :  56'998  13,4%  #################################################
0,70–0,75 :  52'873  12,5%  #############################################
0,75–0,80 :  46'458  11,0%  ########################################
0,80–0,85 :  39'164   9,2%  #################################
0,85–0,90 :  25'045   5,9%  #####################
0,90–0,95 :   7'984   1,9%  ######
0,95–1,00 :      57   0,0%
```

Lecture :
- **`road_marking` écrase tout (58,8 %)** — cohérent avec l'analyse solo : le marquage au sol est omniprésent dans le contexte routier, chaque bande/ligne compte comme un polygone.
- **Les formes circulaires sont les mieux notées** : `circular_manhole_cover` (0,721) et `circular_sign` (0,705) — géométrie nette, peu ambiguë. `rectangular_drain_grate` suit (0,715).
- **`arrow_marking` (0,622) et `rectangular_sign` (0,642) sont les plus faibles** : flèches rares (3,4 %) et panneaux rectangulaires plus facilement confondus (façades, panneaux publicitaires).
- **Distribution centrée bas** : ~82 % des scores entre 0,50 et 0,80, médiane 0,664, très peu de détections à haute confiance (>0,90 = 1,9 %). Le pic à 0,504 (min = seuil) montre que beaucoup de détections sont juste au-dessus du seuil → un `detection_threshold` plus élevé couperait surtout du `road_marking`/`rectangular_sign` bas de gamme.

→ Remplit aussi le TODO `resultats.typ` « histogramme des scores SAM3 » (section Exploitation des résultats). Reste à décider si on met la figure dans le rapport (lilaq bar chart) ou juste la table.

### Test de soumissions concurrentes — plafond head Ray (06.07.2026)

En lançant volontairement ~5 batchs en même temps (nouveau layout `09_Pipeline_result/`, images testValentin), découverte d'un **3ᵉ goulot**, distinct du GPU et de MinIO : le **head Ray**.

- Chaque driver batch se connecte en **mode Ray Client** (`ray://ray-cluster-head-svc:10001`) → le head démarre **un sous-process serveur par connexion** (`ray_client_server_2300x`), qui charge tout le runtime (PyTorch inclus).
- Head limité à **2 CPU / 4 Gi** → au-delà d'**1–2 connexions concurrentes**, le serveur suivant échoue : `Starting Ray client server failed` → `ConnectionAbortedError`. Ports vus : 23000 → 23004 (5 tentatives).
- Le head n'a **pas crashé** (0 restart) : c'est le sous-process par-connexion qui meurt (OOM process, pas pod).
- Le **`backoffLimit` du Job k8s masque l'incident** : pods `Error` puis `Completed` pour un même job, le run repasse quand une connexion se libère. Chaque run terminé produit une **sortie correcte** (10 img / 177 dét).
- **Paralléliser ne sert à rien** : 3 GPU seulement → les runs concurrents se battent pour les mêmes 3 workers. Modèle prévu = **un driver qui distribue sur tous les workers, batchs en série**.
- Leviers si la soumission concurrente devient utile un jour : grossir le head, ou passer de Ray Client à **`RayJob`** (soumission intra-cluster, supprime le serveur par-connexion). → documenté dans `resultats.typ` (§ Goulots d'étranglement, `@tab-bottlenecks`).

Validé au passage (déploiement du nouveau layout) : sortie `09_Pipeline_result/<job>/` sans double-nesting, `params.json` par run, et **dérivation auto du chemin de sortie** quand `s3OutputUri` est omis (run 17448262 : input `.../testValentin`, output dérivé correctement). Le chemin explicite reste honoré (test `SuperTest/` → `SuperTest/<job>/`).

## Attentes de Bertil (fin de projet)

- [ ] Inférence distribuée : la démontrer.
- [x] Identifier les bottlenecks de l'architecture. → 3 identifiés et mesurés : GPU (maillon actif à 3 workers), MinIO (latent, ~2 Mo/s), head Ray (plafond soumissions concurrentes). Cf. `resultats.typ` § Goulots + `@tab-bottlenecks`.
- [ ] Expliquer Ray (cœur métier du projet -> priorité).
- [ ] Meilleur focus sur observabilité.
- [ ] Comparer les coûts GPU : cloud vs on-premise.
- [x] Faire une CLI pour la pipeline : montrer le gain de temps au déploiement (un utilisateur push ses images et lance un batch simplement). → v1 faite (`cli/nearai.py` : push, batch, solo, status, result, jobs, import, segment).

## Si on a plus de temps (bonus)

- [ ] Analyse des scores / labels depuis les Parquet (score moyen + médiane par label, distribution des labels, histogramme des scores).
  - Pour le rapport : script DuckDB one-shot sur le préfixe `09_parquet/` → figures Résultats (remplit le TODO « histogramme des scores SAM3 »). ~30 min, bon outil.
  - Grafana ne lit pas le Parquet nativement -> pas de dashboard direct (faudrait un exporter DuckDB = nouveau composant, disproportionné).
  - Voie cheap pour du live : la distribution des labels est déjà dans les logs (`{'sign': 10}`) ; pour le score moyen, ajouter 1 ligne de log dans le worker puis un panel LogQL.


- Lancer batch avec un array de liens url s3 complets.
- Calculer IoU avec Yolo et SAM3
- Forcer le s3:// au début, car si plus tard on veut mettre du https pour par exemple download directement le simages depuis les serveurs de la ville qui fournit les images au lieu de passer par une phase de download en local chez nous.


Reste pour la version relisible de ce soir :
1. Les calculs de coûts (jalons TODO dans resultats.typ ~678–699) + tes chiffres confidentiels pour le tableau récap.
2. La prose : conclusion (4 jalons posés), architecture.typ:486 "...", resultats.typ "Logs pods..." (:592) et les "..." (:523, :532, :717), section NearLabel.
3. Décision sur "10 images de Vevey" vs Nyon S001 (resultats.typ:467 et :498 se contredisent).
