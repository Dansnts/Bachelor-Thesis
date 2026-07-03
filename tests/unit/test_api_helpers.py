"""Pure helpers of the API, tested in isolation (no HTTP, no cluster)."""

import json
import types

import pytest


# --- to_s3_uri -------------------------------------------------------------
class TestToS3Uri:
    def test_plain_path_gets_bucket_prefix(self, api_module):
        assert api_module.to_s3_uri("nearai", "data/x.jpg") == "s3://nearai/data/x.jpg"

    def test_leading_slash_is_stripped(self, api_module):
        assert api_module.to_s3_uri("nearai", "/data/x.jpg") == "s3://nearai/data/x.jpg"

    def test_already_a_uri_is_untouched(self, api_module):
        assert api_module.to_s3_uri("ignored", "s3://other/x.jpg") == "s3://other/x.jpg"


# --- job_status ------------------------------------------------------------
class TestJobStatus:
    @pytest.mark.parametrize(
        "flags,expected",
        [
            (dict(succeeded=1, failed=None, active=None), "Succeeded"),
            (dict(succeeded=None, failed=1, active=None), "Failed"),
            (dict(succeeded=None, failed=None, active=1), "Active"),
            (dict(succeeded=None, failed=None, active=None), "Pending"),
        ],
    )
    def test_mapping(self, api_module, flags, expected):
        job = types.SimpleNamespace(status=types.SimpleNamespace(**flags))
        assert api_module.job_status(job) == expected

    def test_succeeded_wins_over_active(self, api_module):
        # a job that had active pods but is now done reports Succeeded
        job = types.SimpleNamespace(status=types.SimpleNamespace(succeeded=1, failed=None, active=1))
        assert api_module.job_status(job) == "Succeeded"


# --- rows_to_label_studio --------------------------------------------------
class TestRowsToLabelStudio:
    def _row(self, image_key, label="sign", points="[[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]"):
        return {
            "image_key": image_key,
            "label": label,
            "points": points,
            "original_width": 8000,
            "original_height": 4000,
        }

    def test_groups_polygons_by_image(self, api_module):
        rows = [
            self._row("a.jpg", "sign"),
            self._row("a.jpg", "manhole"),
            self._row("b.jpg", "sign"),
        ]
        tasks = api_module.rows_to_label_studio("nearai", rows)
        assert len(tasks) == 2                       # two distinct images
        a = next(t for t in tasks if t["data"]["image"].endswith("a.jpg"))
        assert len(a["predictions"][0]["result"]) == 2   # both polygons on a.jpg

    def test_points_are_parsed_from_json_string(self, api_module):
        tasks = api_module.rows_to_label_studio("nearai", [self._row("a.jpg")])
        pts = tasks[0]["predictions"][0]["result"][0]["value"]["points"]
        assert pts == [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]   # list, not a string

    def test_label_studio_contract_fields(self, api_module):
        res = api_module.rows_to_label_studio("nearai", [self._row("a.jpg")])[0]
        r0 = res["predictions"][0]["result"][0]
        # from_name/to_name must match the Label Studio XML or polygons show grey
        assert r0["from_name"] == "label" and r0["to_name"] == "image"
        assert r0["type"] == "polygonlabels"
        assert res["data"]["image"] == "s3://nearai/a.jpg"

    def test_empty_rows_gives_no_tasks(self, api_module):
        assert api_module.rows_to_label_studio("nearai", []) == []


# --- iter_label_studio_json ------------------------------------------------
class TestIterLabelStudioJson:
    def test_frames_tasks_as_json_array(self, api_module):
        tasks = [{"a": 1}, {"b": 2}]
        out = b"".join(api_module.iter_label_studio_json(iter(tasks)))
        assert json.loads(out) == tasks              # valid JSON, order preserved

    def test_empty_iterator_is_empty_array(self, api_module):
        out = b"".join(api_module.iter_label_studio_json(iter([])))
        assert out == b"[]"
        assert json.loads(out) == []


# --- list_parquet_keys -----------------------------------------------------
class TestListParquetKeys:
    def test_only_parquet_under_prefix(self, api_module, fake_s3):
        for key in [
            "data/out/a.parquet",
            "data/out/b.parquet",
            "data/out/notes.txt",     # ignored: not parquet
            "data/other/c.parquet",   # ignored: different prefix
        ]:
            fake_s3.put_object(Bucket="nearai", Key=key, Body=b"x")
        keys = api_module.list_parquet_keys(fake_s3, "nearai", "data/out/")
        assert sorted(keys) == ["data/out/a.parquet", "data/out/b.parquet"]

    def test_no_match_returns_empty(self, api_module, fake_s3):
        assert api_module.list_parquet_keys(fake_s3, "nearai", "nothing/") == []


# --- stream_to_s3 ----------------------------------------------------------
class TestStreamToS3:
    def test_streams_and_returns_uri(self, api_module, fake_s3):
        chunks = [b"hello ", b"world"]
        uri = api_module.stream_to_s3(fake_s3, "nearai", "out/f.json", iter(chunks))
        assert uri == "s3://nearai/out/f.json"
        assert fake_s3.store[("nearai", "out/f.json")] == b"hello world"

    def test_empty_stream_still_creates_object(self, api_module, fake_s3):
        # the "buf or not parts" branch must upload one (empty) part
        uri = api_module.stream_to_s3(fake_s3, "nearai", "out/empty.json", iter([]))
        assert uri == "s3://nearai/out/empty.json"
        assert fake_s3.store[("nearai", "out/empty.json")] == b""

    def test_large_payload_is_multipart(self, api_module, fake_s3):
        # > 5 MiB forces at least two parts; the reassembled object must match
        big = b"a" * (6 * 1024 * 1024)
        api_module.stream_to_s3(fake_s3, "nearai", "out/big.json", iter([big]))
        assert fake_s3.store[("nearai", "out/big.json")] == big


# --- build_job -------------------------------------------------------------
class TestBuildJob:
    def test_gpu_job_has_nvidia_runtime_and_affinity(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job("sam3-solo-1", "img", ["python"], ["--x"], gpu=True)
        job = fake_k8s.batch.jobs["sam3-solo-1"]
        spec = job.spec.template.spec
        assert spec.runtime_class_name == "nvidia"
        assert spec.containers[0].resources.limits["nvidia.com/gpu"] == "1"
        assert spec.affinity is not None

    def test_cpu_job_has_no_gpu(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job("sam3-batch-1", "img", ["python"], ["--x"], gpu=False)
        spec = fake_k8s.batch.jobs["sam3-batch-1"].spec.template.spec
        assert spec.runtime_class_name is None
        assert "nvidia.com/gpu" not in (spec.containers[0].resources.limits or {})

    def test_ttl_and_app_label(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job("sam3-batch-abcd1234", "img", ["python"], [], gpu=False)
        job = fake_k8s.batch.jobs["sam3-batch-abcd1234"]
        assert job.spec.ttl_seconds_after_finished == 172800   # 48 h
        # app label = job name without its uuid suffix, so Alloy tags logs by app
        assert job.spec.template.metadata.labels["app"] == "sam3-batch"

    def test_secrets_injected_as_env(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        api_module.build_job(
            "sam3-batch-2", "img", ["python"], [], gpu=False,
            access_key_env="AWS_ACCESS_KEY_ID",
        )
        env = fake_k8s.batch.jobs["sam3-batch-2"].spec.template.spec.containers[0].env
        names = {e.name for e in env}
        assert {"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "HF_TOKEN"} <= names
        # credentials come from secretKeyRef, never inlined
        access = next(e for e in env if e.name == "AWS_ACCESS_KEY_ID")
        assert access.value is None
        assert access.value_from.secret_key_ref.name == "minio-secret"

    def test_create_failure_raises_http_exception(self, api_module, fake_k8s, monkeypatch):
        monkeypatch.setattr(api_module, "batch_v1", fake_k8s.batch)
        fake_k8s.batch.create_error = fake_k8s.ApiException(status=409, reason="exists")
        with pytest.raises(api_module.HTTPException) as exc:
            api_module.build_job("dup", "img", ["python"], [], gpu=False)
        assert exc.value.status_code == 409
