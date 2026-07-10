"""Endpoint behaviour with Kubernetes and S3 mocked.

Covers the happy path (a job is created with the right driver arguments) and,
above all, the failure paths a user will actually hit: a job that does not
exist, a status/result not ready, the segmentation service down, the cluster
refusing to create a job.
"""

import json
import types
from datetime import datetime, timezone

import pyarrow as pa
import pyarrow.parquet as pq
import pytest

BATCH = {
    "s3Uri": "data/in/",
    "s3OutputUri": "data/out/",
    "s3Bucket": "nearai",
    "labels": ["sign", "road_mark"],
    "numWorkers": 3,
    "batchSize": 4,
    "tileSize": 1008,
    "tileStride": 768,
    "downsample": 0.75,
}

SOLO = {
    "imageUri": "data/in/img.jpg",
    "s3Bucket": "nearai",
    "labels": ["sign", "manhole"],
}


def _fake_job(name, *, succeeded=None, failed=None, active=None, created=None):
    status = types.SimpleNamespace(succeeded=succeeded, failed=failed, active=active)
    meta = types.SimpleNamespace(
        name=name,
        creation_timestamp=created or datetime(2026, 7, 1, tzinfo=timezone.utc),
    )
    return types.SimpleNamespace(metadata=meta, status=status)


class TestUi:
    def test_ui_serves_the_control_panel(self, client):
        r = client.get("/ui")
        assert r.status_code == 200
        assert "text/html" in r.headers["content-type"]
        assert "NearAI" in r.text and "Console" in r.text


class TestSubmitBatch:
    def test_returns_job_name_and_submitted(self, client, fake_k8s):
        r = client.post("/jobs/batch", json=BATCH)
        assert r.status_code == 200
        body = r.json()
        assert body["job_name"].startswith("sam3-batch-")
        assert body["status"] == "submitted"

    def test_driver_args_carry_every_parameter(self, client, fake_k8s):
        client.post("/jobs/batch", json=BATCH)
        job = next(iter(fake_k8s.batch.jobs.values()))
        args = job.spec.template.spec.containers[0].args
        # s3 URIs are normalised to s3://bucket/prefix
        assert "s3://nearai/data/in/" in args
        # the output URI gets a per-run subfolder (the job name) so runs never
        # overwrite each other
        out_uri = args[args.index("--s3_output_uri") + 1]
        assert out_uri.startswith("s3://nearai/data/out/sam3-batch-")
        assert out_uri.endswith("/")
        assert "sign,road_mark" in args          # labels joined by comma
        assert args[args.index("--num_workers") + 1] == "3"
        assert args[args.index("--tile_size") + 1] == "1008"
        assert args[args.index("--tile_stride") + 1] == "768"
        assert args[args.index("--downsample") + 1] == "0.75"

    def test_output_uri_defaults_from_input_when_omitted(self, client, fake_k8s):
        # No s3OutputUri -> derived from s3Uri: acquisition root + 09_Pipeline_result/<job>/
        body = {k: v for k, v in BATCH.items() if k != "s3OutputUri"}
        body["s3Uri"] = "data/acquisitions/Vevey/01_images/"
        client.post("/jobs/batch", json=body)
        job = next(iter(fake_k8s.batch.jobs.values()))
        args = job.spec.template.spec.containers[0].args
        out_uri = args[args.index("--s3_output_uri") + 1]
        assert out_uri.startswith("s3://nearai/data/acquisitions/Vevey/09_Pipeline_result/sam3-batch-")
        assert out_uri.endswith("/")

    def test_batch_driver_has_no_gpu(self, client, fake_k8s):
        client.post("/jobs/batch", json=BATCH)
        job = next(iter(fake_k8s.batch.jobs.values()))
        # the batch driver only orchestrates: no nvidia runtime class, no affinity
        assert job.spec.template.spec.runtime_class_name is None
        assert job.spec.template.spec.affinity is None

    def test_cluster_refusal_propagates_status(self, client, fake_k8s):
        # e.g. quota exceeded / forbidden -> the API surfaces the k8s status code
        fake_k8s.batch.create_error = fake_k8s.ApiException(status=403, reason="Forbidden")
        r = client.post("/jobs/batch", json=BATCH)
        assert r.status_code == 403


class TestSubmitSolo:
    def test_solo_job_is_gpu_and_writes_result_key(self, client, fake_k8s):
        r = client.post("/jobs/solo", json=SOLO)
        assert r.status_code == 200
        name = r.json()["job_name"]
        assert name.startswith("sam3-solo-")
        job = fake_k8s.batch.jobs[name]
        spec = job.spec.template.spec
        assert spec.runtime_class_name == "nvidia"          # solo carries its own GPU
        assert spec.affinity is not None                    # pinned to suchet/node4
        args = spec.containers[0].args
        assert args[args.index("--result_key") + 1] == f"results/{name}.json"
        # labels are passed as separate argv items after --labels
        assert "sign" in args and "manhole" in args


class TestListJobs:
    def _seed(self, fake_k8s):
        fake_k8s.batch.jobs.update(
            {
                "sam3-batch-aaaa": _fake_job("sam3-batch-aaaa", succeeded=1,
                                             created=datetime(2026, 7, 1, tzinfo=timezone.utc)),
                "sam3-solo-bbbb": _fake_job("sam3-solo-bbbb", active=1,
                                            created=datetime(2026, 7, 2, tzinfo=timezone.utc)),
                "unrelated-pod": _fake_job("unrelated-pod", succeeded=1),
            }
        )

    def test_lists_only_sam3_jobs_newest_first(self, client, fake_k8s):
        self._seed(fake_k8s)
        jobs = client.get("/jobs/").json()["jobs"]
        names = [j["job_name"] for j in jobs]
        assert "unrelated-pod" not in names          # non-sam3 jobs filtered out
        assert names == ["sam3-solo-bbbb", "sam3-batch-aaaa"]  # sorted desc by date

    def test_kind_filter(self, client, fake_k8s):
        self._seed(fake_k8s)
        jobs = client.get("/jobs/", params={"kind": "batch"}).json()["jobs"]
        assert [j["job_name"] for j in jobs] == ["sam3-batch-aaaa"]

    def test_status_mapping(self, client, fake_k8s):
        self._seed(fake_k8s)
        by_name = {j["job_name"]: j["status"] for j in client.get("/jobs/").json()["jobs"]}
        assert by_name["sam3-batch-aaaa"] == "Succeeded"
        assert by_name["sam3-solo-bbbb"] == "Active"

    def test_list_failure_propagates(self, client, fake_k8s):
        fake_k8s.batch.list_error = fake_k8s.ApiException(status=500, reason="boom")
        assert client.get("/jobs/").status_code == 500


class TestGetJob:
    def test_existing_job(self, client, fake_k8s):
        fake_k8s.batch.jobs["sam3-solo-xyz"] = _fake_job("sam3-solo-xyz", failed=1)
        r = client.get("/jobs/sam3-solo-xyz")
        assert r.status_code == 200
        assert r.json()["status"] == "Failed"

    def test_unknown_job_is_404(self, client, fake_k8s):
        assert client.get("/jobs/sam3-solo-does-not-exist").status_code == 404


class TestJobStatus:
    def test_status_not_ready_is_404(self, client, fake_s3):
        assert client.get("/jobs/sam3-batch-xxxx/status").status_code == 404

    def test_status_running_gets_elapsed(self, client, fake_s3):
        fake_s3.put_object(
            Bucket="nearai",
            Key="results/sam3-batch-run.status.json",
            Body=json.dumps(
                {"total": 100, "processed": 42, "percent": 42,
                 "started_at": 1_000_000_000, "done": False}
            ).encode(),
        )
        r = client.get("/jobs/sam3-batch-run/status")
        assert r.status_code == 200
        data = r.json()
        assert data["percent"] == 42
        # elapsed_seconds is recomputed live while the run is not done
        assert "elapsed_seconds" in data and data["elapsed_seconds"] > 0

    def test_status_done_is_frozen(self, client, fake_s3):
        fake_s3.put_object(
            Bucket="nearai",
            Key="results/sam3-batch-fin.status.json",
            Body=json.dumps(
                {"total": 10, "processed": 10, "percent": 100,
                 "started_at": 1_000_000_000, "done": True, "elapsed_seconds": 55.5}
            ).encode(),
        )
        data = client.get("/jobs/sam3-batch-fin/status").json()
        assert data["done"] is True
        assert data["elapsed_seconds"] == 55.5   # not overwritten once done


class TestGetResult:
    def test_missing_result_is_404(self, client, fake_s3):
        assert client.get("/jobs/sam3-solo-none/result").status_code == 404

    def test_result_is_returned(self, client, fake_s3):
        payload = [{"data": {"image": "s3://nearai/x.jpg"}, "predictions": []}]
        fake_s3.put_object(
            Bucket="nearai", Key="results/sam3-solo-ok.json",
            Body=json.dumps(payload).encode(),
        )
        assert client.get("/jobs/sam3-solo-ok/result").json() == payload


class TestSegment:
    def test_segment_service_unreachable_is_502(self, client, api_module, monkeypatch):
        def boom(*a, **k):
            raise api_module.requests.exceptions.ConnectionError("refused")

        monkeypatch.setattr(api_module.requests, "post", boom)
        r = client.post("/segment", json={"url": "img.jpg", "items": []})
        assert r.status_code == 502

    def test_segment_upstream_error_is_propagated(self, client, api_module, monkeypatch):
        resp = types.SimpleNamespace(status_code=500, text="model crashed", json=lambda: {})
        monkeypatch.setattr(api_module.requests, "post", lambda *a, **k: resp)
        r = client.post(
            "/segment",
            json={"url": "img.jpg", "items": [{"point": [1, 2], "label": "sign"}]},
        )
        assert r.status_code == 500

    def test_segment_ok_passes_through(self, client, api_module, monkeypatch):
        resp = types.SimpleNamespace(
            status_code=200, text="", json=lambda: {"results": [{"found": True}]}
        )
        monkeypatch.setattr(api_module.requests, "post", lambda *a, **k: resp)
        r = client.post(
            "/segment",
            json={"url": "img.jpg", "items": [{"point": [1, 2], "label": "sign"}]},
        )
        assert r.status_code == 200
        assert r.json()["results"][0]["found"] is True


class TestSegmentScaling:
    def test_up_scales_to_one(self, client, fake_k8s):
        assert client.post("/segment/up").json()["replicas"] == 1
        assert fake_k8s.apps.scaled_to == 1

    def test_down_scales_to_zero(self, client, fake_k8s):
        assert client.post("/segment/down").json()["replicas"] == 0
        assert fake_k8s.apps.scaled_to == 0

    def test_scale_failure_propagates(self, client, fake_k8s):
        fake_k8s.apps.error = fake_k8s.ApiException(status=409, reason="conflict")
        assert client.post("/segment/up").status_code == 409


class TestSegmentStatus:
    def test_asleep(self, client, fake_k8s):
        body = client.get("/segment/status").json()
        assert body["replicas"] == 0 and body["ready"] == 0

    def test_starting(self, client, fake_k8s):
        fake_k8s.apps.replicas = 1
        body = client.get("/segment/status").json()
        assert body["replicas"] == 1 and body["ready"] == 0

    def test_ready(self, client, fake_k8s):
        fake_k8s.apps.replicas = 1
        fake_k8s.apps.ready_replicas = 1
        body = client.get("/segment/status").json()
        assert body["ready"] == 1

    def test_read_failure_propagates(self, client, fake_k8s):
        fake_k8s.apps.error = fake_k8s.ApiException(status=404, reason="not found")
        assert client.get("/segment/status").status_code == 404


class TestImport:
    def test_no_parquet_is_404(self, client, fake_s3):
        assert client.post("/import/Vevey").status_code == 404

    def _seed_parquet(self, fake_s3, acq="Vevey"):
        table = pa.table(
            {
                "image_key": ["data/acquisitions/%s/01_images/a.jpg" % acq],
                "acquisition_id": [acq],
                "label": ["sign"],
                "score": [0.9],
                "points": ['[[10.0, 20.0], [30.0, 20.0], [30.0, 40.0]]'],
                "original_width": [8000],
                "original_height": [4000],
                "latitude": [46.5],
                "longitude": [6.9],
            }
        )
        import io

        buf = io.BytesIO()
        pq.write_table(table, buf)
        fake_s3.put_object(
            Bucket="nearai",
            Key="data/acquisitions/%s/09_Pipeline_result/sam3-batch-test/a.parquet" % acq,
            Body=buf.getvalue(),
        )

    def test_import_streams_label_studio_tasks(self, client, fake_s3):
        self._seed_parquet(fake_s3)
        r = client.post("/import/Vevey")
        assert r.status_code == 200
        tasks = json.loads(r.content)
        assert len(tasks) == 1
        result = tasks[0]["predictions"][0]["result"][0]
        assert result["from_name"] == "label"
        assert result["value"]["polygonlabels"] == ["sign"]

    def test_import_scoped_to_a_run(self, client, fake_s3):
        # ?run=<job> reads only that run's subfolder
        self._seed_parquet(fake_s3)
        r = client.post("/import/Vevey", params={"run": "sam3-batch-test"})
        assert r.status_code == 200
        assert len(json.loads(r.content)) == 1

    def test_import_unknown_run_is_404(self, client, fake_s3):
        self._seed_parquet(fake_s3)
        r = client.post("/import/Vevey", params={"run": "sam3-batch-nope"})
        assert r.status_code == 404

    def test_import_write_true_persists_to_s3(self, client, fake_s3):
        self._seed_parquet(fake_s3)
        r = client.post("/import/Vevey", params={"write": "true"})
        assert r.status_code == 200
        body = r.json()
        assert body["files"] == 1
        assert body["uri"].endswith("label_studio_import.json")
        # the JSON really landed in the bucket
        stored = fake_s3.store[("nearai", "data/results/Vevey/label_studio_import.json")]
        assert json.loads(stored)[0]["data"]["image"].startswith("s3://nearai/")
