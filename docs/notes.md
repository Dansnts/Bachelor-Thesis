# Week 1

## K8s
- 4x GPUs may be available to compute

## Ray
- Running on HEIG's k8s cluster

## DataBase
- PostgresSQL as main DB
- Some data has geodata stored, need PostGIS plugin to manage it

## Storage
- Data stored on HEIG's S3 Local Bucket(s?)

## AI
- SAM3

## Data
- Downsampling --> reducing size, and using polygons instead of handrawing to label data (few polygons vs a LOT of them) 
- Data on *Label Studio* is stored in json files, pictures are stored on MinIO inside the NearAI foder.

---

# Week 2 

- [X] Check S3, solution in entreprise alternative to MinIO
- [X] Spark [Historical], Ray [Modern], ZARR [More popular to do rasterization]
- [X] Read the 3 Redaction documents
- [X] Check PostGIS
- [X] Check HEIG's cluster

## S3 
> Protocol, not a unique solution by definition

Alternative to MinIO :

### CEPH

CEPH is a mature and reliable open-source (license LGPL) tool. He's not focused on S3 but can provide block and file system storage. Yet he's MORE complex to set-up and manage even for experienced administrators. If we already have a single node or a CEPH cluster it could be interesting to exploit the s3 compatibilites on it. The migration is not that hard but it neither as simple as the one RustFs can give us.

[Repo Gitub](https://github.com/ceph/ceph)


### RustFS

Very similar to MinIO in concept, but with an Apache 2.0 license. It focuses exclusively on S3, which matches our use case. It offers streamlined migrations from MinIO or CEPH, along with additional features for observability and K8s management.
Rust could potentially be beneficial regarding performance, allowing us to potentially reduce the risk of bottlenecks on S3 storage.

On the other hand, the project is 'extremely mature' (<1 year), though it already has 22k stars on GitHub.

[Repo Gitub](https://github.com/rustfs/rustfs?tab=readme-ov-file)

## Image processing

### Ray 
Ray is based to exploit and parellelize flows. For example Spark is the based of Hadoop (Map reducer), using Spark is more logic to compute structured data where Ray is purely axe on dealing with PyTorch flows and excels in using GPUs which is vital in the computation for AI models. By using Ray in Pods we can achieve an optimised and fully exploit our Hardware to multitask our data.

### ZARR
Is basicaly a data structure format focused in working with N-dimmensional data which we can simply put as Pictures and Data cubes. It works by decomposing the data by "chunks" to process it faster (reads the picture by tile instead of the whole image). Which in our case can be a VERY efficient combo with Ray. (May be redondant to SAM3 but can be usefull to load the tiles once instead of taking them for multiple instances)

```sh
[Data sources PNG/TIFF]
        V
  Conversion with Zarr (one-time pre traitement)
        V
  Storage on S3
        V
  Ray workers > only read needed chunks
              > run SAM3 by tile
              > write the labels
```

### MPS (Multi-Process Service)

> The Multi-Process Service (MPS) is an alternative, binary-compatible implementation of the CUDA Application Programming Interface (API). The MPS runtime architecture is designed to transparently enable co-operative multi-process CUDA applications, typically MPI jobs, to utilize Hyper-Q capabilities on the latest NVIDIA (Kepler-based) Tesla and Quadro GPUs.

Source : [Nvidia](https://docs.nvidia.com/deploy/mps/index.html)

### PostGIS
It's an extension to PostgresSQL, basicaly it will add a collum to the table like this :
```SQL
CREATE TABLE superTable(
    ...
    geom GEOMETRY(POLYGON, 4326) is the SRID -- 4326 >  WGS84 (Classical GPS)
);
```

It can have 3 values : `POINT`,`POLYGON`,`MULTIPOLGYON`

It uses also spacial indexes like : 
```SQL
CREATE INDEX ON superTable USING GIST(geom);
```
It allows to do fast requests with the GIST index. Usefull to filter all the data after it was added by SAM3 into the DB, it also allows us to just look for the value in the DB instead of re-calculate it.


---

# Semaine 3

## Meeting

- MinIO tourne sur un Synology → évaluer migration vers RustFS
- Ajouter observabilité et logs au pipeline
- Prévoir une entrée utilisateur (interface ou API)
- Focus sur la donnée : approche batch

## Scénarios

### Scénario A — Batch (traitement de masse)
- L'utilisateur fournit un lot de ~2000 images
- SAM3 tourne en batch via Ray
- Les métadonnées et résultats sont stockés sur S3 en format **Parquet**
- Pas forcément de base de données → Parquet sur S3 suffit pour ce cas
- Référence Ray Data : https://docs.ray.io/en/latest/data/data.html

### Scénario B — Inférence à la demande
- L'utilisateur soumet une image → réponse en temps quasi-réel
- Pipeline déclenché à la volée (pas de batch)
- Résultats stockés en DB (PostGIS) pour interrogation spatiale

## Questions ouvertes
- Base de données vraiment nécessaire, ou Parquet sur S3 suffit pour le scénario A ?
- Quel format de sortie final pour les annotations ?


---